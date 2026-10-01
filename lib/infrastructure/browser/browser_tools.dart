/// Implementação REAL das tools de browser (spec catálogo §BROWSER).
///
/// Nada é simulado: cada tool fala o Chrome DevTools Protocol (CDP) verdadeiro
/// por WebSocket cru (handshake HTTP + frames RFC 6455 implementados aqui, sem
/// dependências externas), exatamente como Puppeteer/Playwright fazem por
/// baixo:
/// - browser.launch        → spawn REAL de Chrome/Chromium/Edge com perfil
///                           dedicado (--user-data-dir) headless ou com janela;
/// - browser.navigate      → Page.navigate REAL após allowlist de domínio;
/// - browser.click         → querySelector + boxModel + Input.dispatchMouseEvent
///                           (mouse de verdade, não .click() injetado);
/// - browser.type          → foco real + Input.dispatchKeyEvent tecla a tecla;
/// - browser.select        → <option> real por value/label/index + eventos
///                           input/change nativos;
/// - browser.wait_for_selector → polling DOM real com timeout tipado honesto;
/// - browser.screenshot    → Page.captureScreenshot PNG/JPEG REAL em artefato;
/// - browser.evaluate_js   → Runtime.evaluate (awaitPromise) com aprovação
///                           EXPLÍCITA — código arbitrário roda no perfil ativo;
/// - browser.get_dom       → outerHTML / snapshot estruturado / texto REAIS da
///                           página viva, com truncamento declarado;
/// - browser.close         → Browser.close + espera de exit + SIGTERM/SIGKILL
///                           + limpeza opcional do perfil.
///
/// Erros do browser/alvo viram VtFailure tipado com a mensagem CRUA do CDP —
/// falha nunca vira sucesso inventado.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import '../process/process_utils.dart';

final Random _rnd = Random.secure();

// ===================================================== instância do browser

enum BrowserState { launching, ready, closed }

/// Uma instância REAL de Chromium gerenciada pela aplicação: processo vivo,
/// perfil (user-data-dir) e conexão CDP sob demanda.
class BrowserInstance {
  BrowserInstance({
    required this.id,
    required this.process,
    required this.wsUrl,
    required this.profileDir,
    required this.exe,
    required this.headless,
  });

  final String id;
  final Process process;
  final String wsUrl;
  final String profileDir;
  final String exe;
  final bool headless;

  /// Página alvo (tab) selecionada; '' até ensurePage criar uma real.
  String targetId = '';
  String currentUrl = '';
  BrowserState state = BrowserState.ready;

  /// Exit code observado quando o processo terminou (null enquanto vivo).
  int? observedExitCode;

  _CdpClient? _cdp;

  int get pid => process.pid;

  Future<_CdpClient> client() async {
    if (state == BrowserState.closed) {
      throw VtFailure.sidecarNotRunning('browser $id (fechado)');
    }
    final c = _cdp;
    if (c != null && !c.isClosed) return c;
    final fresh = await _CdpClient.connect(wsUrl);
    _cdp = fresh;
    return fresh;
  }

  /// Garante uma página ativa; cria uma aba REAL se necessário.
  Future<String> ensurePage() async {
    if (targetId.isNotEmpty) return targetId;
    final c = await client();
    final res = await c.send('Target.createTarget', {'url': 'about:blank'});
    targetId = res['targetId'] as String? ?? '';
    if (targetId.isEmpty) {
      throw VtFailure(
        code: VtErrorCode.sidecarNotRunning,
        message: 'Target.createTarget não retornou targetId real.',
      );
    }
    return targetId;
  }

  Future<void> disposeConnection() async {
    final c = _cdp;
    _cdp = null;
    if (c != null) await c.close();
  }
}

/// Registro vivo de instâncias (uma por browser.launch bem-sucedido).
class BrowserSessionManager {
  BrowserSessionManager();

  factory BrowserSessionManager.detached() => BrowserSessionManager();

  static final BrowserSessionManager shared = BrowserSessionManager();

  final Map<String, BrowserInstance> instances = {};

  BrowserInstance require(String browserId) {
    final b = instances[browserId];
    if (b == null) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Browser "$browserId" não existe (ou já foi fechado). '
            'Rode browser.launch primeiro.',
      );
    }
    return b;
  }

  List<Map<String, Object?>> list() => instances.values
      .map((b) => {
            'browserId': b.id,
            'state': b.state.name,
            'headless': b.headless,
            'pid': b.pid,
            'url': b.currentUrl,
            'profileDir': b.profileDir,
          })
      .toList();

  Future<void> disposeAll() async {
    for (final b in instances.values.toList()) {
      try {
        await b.disposeConnection();
      } catch (_) {}
      b.process.kill(ProcessSignal.sigterm);
      b.state = BrowserState.closed;
    }
    instances.clear();
  }
}

// ============================================================ tool base

abstract class BrowserToolBase extends VtTool<MapToolInput, TextOutput> {
  BrowserToolBase({BrowserSessionManager? manager})
      : manager = manager ?? BrowserSessionManager.shared;

  final BrowserSessionManager manager;

  @override
  List<String> get capabilities => const ['browser'];

  @override
  RiskLevel get risk => RiskLevel.execute;

  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;

  @override
  bool get isIdempotent => false;

  @override
  RetryPolicy get retryPolicy => const RetryPolicy();

  @override
  Duration get timeout => const Duration(seconds: 30);

  @override
  Map<String, Object?> get outputSchema => const {'type': 'object'};

  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async {
    final exe = await resolveChrome(ctx, '');
    return exe == null
        ? const HealthMissingBinary('chrome/chromium')
        : HealthOk(exe);
  }

  /// Valida URL contra esquema http(s) + allowlist do sandbox ANTES de tocar
  /// no browser. Retorna o Uri ou lança VtFailure tipado.
  Uri checkUrlAllowed(ToolContext ctx, String urlStr) {
    final uri = Uri.tryParse(urlStr);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'URL inválida ou esquema não-HTTP(S): "$urlStr".',
      );
    }
    if (!ctx.sandbox.isAllowedDomain(uri.host, ctx)) {
      throw VtFailure.domainNotAllowed(uri.host);
    }
    return uri;
  }

  Future<ToolResult<TextOutput>> guarded(
    Future<ToolResult<TextOutput>> Function() body,
  ) async {
    try {
      return await body();
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    } on TimeoutException {
      return ToolFailureResult(VtFailure(
        code: VtErrorCode.timeout,
        message: 'Operação no browser excedeu o timeout de '
            '${timeout.inSeconds}s.',
      ));
    } on SocketException catch (e) {
      return ToolFailureResult(VtFailure.networkUnavailable(e.message));
    } catch (e) {
      return ToolFailureResult(VtFailure(
        code: VtErrorCode.sidecarNotRunning,
        message: 'Falha REAL no browser: $e',
      ));
    }
  }

  /// Caminho do executável: argumento > settings browser.executablePath >
  /// busca REAL nos locais conhecidos de cada plataforma.
  Future<String?> resolveChrome(ToolContext ctx, String explicit) async {
    if (explicit.isNotEmpty) {
      return await File(explicit).exists() ? explicit : null;
    }
    final fromSettings = ctx.settings.get('browser.executablePath') as String?;
    if (fromSettings != null && fromSettings.isNotEmpty) {
      return await File(fromSettings).exists() ? fromSettings : null;
    }
    for (final name in const [
      'google-chrome',
      'google-chrome-stable',
      'chromium',
      'chromium-browser',
      'microsoft-edge',
    ]) {
      final p = await findBinaryInPath(name);
      if (p != null) return p;
    }
    if (Platform.isMacOS) {
      for (final p in const [
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
      ]) {
        if (await File(p).exists()) return p;
      }
    }
    if (Platform.isWindows) {
      final pf = Platform.environment['PROGRAMFILES'] ?? r'C:\Program Files';
      for (final tpl in [
        r'$PF\Google\Chrome\Application\chrome.exe',
        r'$PF\Microsoft\Edge\Application\msedge.exe',
      ]) {
        final f = File(tpl.replaceAll(r'$PF', pf));
        if (await f.exists()) return f.path;
      }
    }
    return null;
  }
}

String _newBrowserId() =>
    'brw-${DateTime.now().microsecondsSinceEpoch}-${_rnd.nextInt(1 << 30)}';

int _freePortSync() {
  final s = ServerSocket.bindSync(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  s.closeSync();
  return port;
}

const List<String> _defaultLaunchArgs = [
  '--disable-background-networking',
  '--disable-component-update',
  '--disable-sync',
  '--disable-translate',
  '--no-first-run',
  '--no-default-browser-check',
];

Future<Map<String, Object?>> _httpJson(Uri uri, Duration limit) async {
  final client = HttpClient()..connectionTimeout = limit;
  try {
    final req = await client.getUrl(uri).timeout(limit);
    final resp = await req.close().timeout(limit);
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw VtFailure(
        code: VtErrorCode.networkUnavailable,
        message: 'HTTP ${resp.statusCode} em $uri',
      );
    }
    return (jsonDecode(body) as Map).cast<String, Object?>();
  } finally {
    client.close(force: true);
  }
}

// ========================================================= browser.launch

class BrowserLaunchTool extends BrowserToolBase {
  @override
  String get id => 'browser.launch';
  @override
  String get title => 'Launch browser';
  @override
  String get description =>
      'Inicia uma instância REAL de Chrome/Chromium com perfil dedicado '
      '(--user-data-dir) em modo headless ou com janela visível. Retorna '
      'browserId usado pelas demais tools browser.*. Sem binário no '
      'PATH/settings: binary_missing — nunca simula browser.';
  @override
  ToolCategory get category => ToolCategory.browser;
  @override
  RiskLevel get risk => RiskLevel.execute;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'headless': {
            'type': 'boolean',
            'default': true,
            'description': 'true=headless, false=janela visível',
          },
          'executablePath': {
            'type': 'string',
            'description': 'binário custom (default: settings '
                'browser.executablePath ou busca real no sistema)',
          },
          'profileName': {
            'type': 'string',
            'description': 'nome do perfil persistente (default: gerado). '
                'Reusar o mesmo nome mantém cookies/login entre sessões.',
          },
          'args': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'flags extras de launch',
          },
          'startUrl': {
            'type': 'string',
            'description': 'URL inicial (opcional; validada na allowlist)',
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    return guarded(() async {
      final exe = await resolveChrome(ctx, input.str('executablePath'));
      if (exe == null) {
        throw VtFailure.binaryMissing('chrome/chromium',
            hint: ' Instale um Chromium ou defina browser.executablePath.');
      }
      final headless = input.boolOf('headless', true);
      final profileName = input.str('profileName').isEmpty
          ? 'vt-${DateTime.now().millisecondsSinceEpoch}'
          : input.str('profileName');
      final safeProfile =
          profileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final root = joinPath(Directory.systemTemp.path, 'techvt-browsers');
      final profileDir = joinPath(joinPath(root, safeProfile), 'user-data');
      await Directory(profileDir).create(recursive: true);

      final port = _freePortSync();
      final extra =
          (input.values['args'] as List?)?.cast<String>() ?? const [];
      final argv = [
        '--remote-debugging-port=$port',
        '--user-data-dir=$profileDir',
        if (headless) ...const ['--headless=new', '--disable-gpu'],
        ..._defaultLaunchArgs,
        ...extra,
      ];
      final Process proc;
      try {
        proc = await Process.start(exe, argv);
      } on ProcessException catch (e) {
        throw VtFailure(
          code: VtErrorCode.sidecarNotRunning,
          message: 'Falha REAL ao iniciar "$exe": ${e.message}',
        );
      }
      final errBuf = StringBuffer();
      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(errBuf.write);

      // espera REAL pelo endpoint CDP (/json/version) subir
      String? wsUrl;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        try {
          final version = await _httpJson(
              Uri.parse('http://127.0.0.1:$port/json/version'),
              const Duration(seconds: 2));
          final u = version['webSocketDebuggerUrl'] as String?;
          if (u != null && u.isNotEmpty) {
            wsUrl = u;
            break;
          }
        } catch (_) {
          // browser ainda subindo — tenta de novo até o deadline
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (wsUrl == null) {
        proc.kill(ProcessSignal.sigkill);
        throw VtFailure(
          code: VtErrorCode.sidecarNotRunning,
          message: 'Browser iniciou (pid=${proc.pid}) mas o endpoint CDP em '
              '127.0.0.1:$port nunca respondeu.\n--- stderr ---\n'
              '${errBuf.toString().trim()}',
        );
      }

      final instance = BrowserInstance(
        id: _newBrowserId(),
        process: proc,
        wsUrl: wsUrl,
        profileDir: profileDir,
        exe: exe,
        headless: headless,
      );
      manager.instances[instance.id] = instance;
      unawaited(proc.exit.then((code) {
        instance.state = BrowserState.closed;
        instance.observedExitCode = code;
        manager.instances.remove(instance.id);
      }));

      if (input.str('startUrl').isNotEmpty) {
        final url = checkUrlAllowed(ctx, input.str('startUrl')).toString();
        final c = await instance.client();
        final tid = await instance.ensurePage();
        final sid = await c.attach(tid);
        await c.send('Page.enable', const {}, sessionId: sid);
        await c.send('Page.navigate', {'url': url}, sessionId: sid);
        instance.currentUrl = url;
      }

      return ToolSuccess(
        data: TextOutput(
          'Browser REAL iniciado: ${basenameOf(exe)} (pid=${proc.pid}, '
          '${headless ? 'headless' : 'janela visível'}).\n'
          'CDP: $wsUrl\nPerfil: $profileDir\nbrowserId=${instance.id}',
          metadata: {
            'browserId': instance.id,
            'pid': proc.pid,
            'headless': headless,
            'wsUrl': wsUrl,
            'profileDir': profileDir,
          },
        ),
        artifacts: [ArtifactRef(kindOf: 'log', pathOrUri: profileDir)],
      );
    });
  }
}

// ======================================================== browser.navigate

class BrowserNavigateTool extends BrowserToolBase {
  @override
  String get id => 'browser.navigate';
  @override
  String get title => 'Navigate browser';
  @override
  String get description =>
      'Navega a página ativa para URL REAL (Page.navigate do CDP) somente '
      'após a allowlist de domínios do sandbox aprovar o host. Aguarda o '
      'evento Page.loadEventFired verdadeiro e reporta título + tempo de '
      'load medido.';
  @override
  ToolCategory get category => ToolCategory.browser;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['browserId', 'url'],
        'properties': {
          'browserId': {'type': 'string'},
          'url': {'type': 'string'},
          'waitUntilLoad': {
            'type': 'boolean',
            'default': true,
            'description': 'aguarda Page.loadEventFired REAL',
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    return guarded(() async {
      final b = manager.require(input.str('browserId'));
      final url = checkUrlAllowed(ctx, input.str('url')).toString();
      final c = await b.client();
      final tid = await b.ensurePage();
      final sid = await c.attach(tid);
      await c.send('Page.enable', const {}, sessionId: sid);
      final loaded = c.waitForEvent(sid, 'Page.loadEventFired');
      final nav = await c.send('Page.navigate', {'url': url}, sessionId: sid);
      final err = nav['errorText'] as String?;
      if (err != null && err.isNotEmpty) {
        throw VtFailure(
          code: VtErrorCode.networkUnavailable,
          message: 'Page.navigate falhou de verdade: $err',
        );
      }
      var loadMs = 0;
      if (input.boolOf('waitUntilLoad', true)) {
        final sw = Stopwatch()..start();
        await loaded.future;
        sw.stop();
        loadMs = sw.elapsedMilliseconds;
      }
      b.currentUrl = url;
      String title = '';
      try {
        final eval = await c.send('Runtime.evaluate',
            {'expression': 'document.title', 'returnByValue': true},
            sessionId: sid);
        title = ((eval['result'] as Map?)?['value'] ?? '').toString();
      } catch (_) {/* título é cosmético; navegação já é fato */}
      return ToolSuccess(
        data: TextOutput(
          'Navegado para $url${title.isEmpty ? '' : ' — "$title"'}'
          '${loadMs > 0 ? ' (load em ${loadMs}ms)' : ''}',
          metadata: {'url': url, 'title': title, 'loadMs': loadMs},
        ),
        citations: [
          Citation(sourceType: 'url', sourceRef: url, label: 'Página atual'),
        ],
      );
    });
  }
}

// ------------------------------------------------------------- helpers DOM

/// Escapa string para literal JS single-quoted seguro.
String jsStr(String s) =>
    "'${s.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('\n', '\\n')}'";

class DomResolve {
  const DomResolve(this.objectId, this.found);
  final String objectId;
  final bool found;
}

Future<DomResolve> querySelectorOnce(
    _CdpClient c, String sid, String selector) async {
  final res = await c.send(
      'Runtime.evaluate',
      {
        'expression': 'document.querySelector(${jsStr(selector)})',
        'objectGroup': 'vt',
      },
      sessionId: sid);
  final ex = res['exceptionDetails'];
  if (ex != null) {
    throw VtFailure(
      code: VtErrorCode.validationFailed,
      message: 'Seletor inválido (${ex['text'] ?? 'erro'}): $selector',
    );
  }
  final obj = res['result'] as Map?;
  if (obj?['type'] == 'object' && obj?['subtype'] == 'null') {
    return const DomResolve('', false);
  }
  final oid = obj?['objectId'] as String?;
  if (oid == null) return const DomResolve('', false);
  return DomResolve(oid, true);
}

Future<({double x, double y, double w, double h})> centerOf(
    _CdpClient c, String sid, String objectId) async {
  final box =
      await c.send('DOM.getBoxModel', {'objectId': objectId}, sessionId: sid);
  final content =
      (((box['model'] as Map?)?['content'] as List?) ?? const []).cast<num>();
  if (content.length < 8) {
    throw VtFailure(
      code: VtErrorCode.validationFailed,
      message: 'Elemento sem caixa renderizada (invisível ou display:none).',
    );
  }
  final xs = [content[0], content[2], content[4], content[6]];
  final ys = [content[1], content[3], content[5], content[7]];
  return (
    x: (xs.fold<num>(0, (a, b) => a + b) / 4).toDouble(),
    y: (ys.fold<num>(0, (a, b) => a + b) / 4).toDouble(),
    w: (xs.reduce(max) - xs.reduce(min)).toDouble(),
    h: (ys.reduce(max) - ys.reduce(min)).toDouble(),
  );
}

// ============================================================ browser.click

class BrowserClickTool extends BrowserToolBase {
  @override
  String get id => 'browser.click';
  @override
  String get title => 'Click element';
  @override
  String get description =>
      'Clique MOUSE REAL (Input.dispatchMouseEvent press+release nas '
      'coordenadas centrais do boxModel) no primeiro elemento que casa com o '
      'seletor. Elemento ausente/invisível → erro tipado; nada é clicado no '
      'escuro.';
  @override
  ToolCategory get category => ToolCategory.browser;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['browserId', 'selector'],
        'properties': {
          'browserId': {'type': 'string'},
          'selector': {'type': 'string'},
          'button': {
            'type': 'string',
            'enum': ['left', 'right', 'middle'],
            'default': 'left'
          },
          'clickCount': {'type': 'integer', 'default': 1, 'minimum': 1},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    return guarded(() async {
      final b = manager.require(input.str('browserId'));
      if (b.targetId.isEmpty) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Sem página ativa no browser ${b.id}. Navegue primeiro '
              '(browser.navigate cria uma aba real).',
        );
      }
      final c = await b.client();
      final sid = await c.attach(b.targetId);
      final sel = input.str('selector');
      final r = await querySelectorOnce(c, sid, sel);
      if (!r.found) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Nenhum elemento casa com o seletor: $sel',
        );
      }
      final center = await centerOf(c, sid, r.objectId);
      final button =
          input.str('button').isEmpty ? 'left' : input.str('button');
      final count = input.intOrNull('clickCount') ?? 1;
      await c.send(
          'Input.dispatchMouseEvent',
          {
            'type': 'mouseMoved',
            'x': center.x,
            'y': center.y,
            'button': 'none'
          },
          sessionId: sid);
      for (var i = 1; i <= count; i++) {
        for (final type in const ['mousePressed', 'mouseReleased']) {
          await c.send(
              'Input.dispatchMouseEvent',
              {
                'type': type,
                'x': center.x,
                'y': center.y,
                'button': button,
                'clickCount': i,
              },
              sessionId: sid);
        }
      }
      await c.send('Runtime.releaseObjectGroup', {'objectGroup': 'vt'},
          sessionId: sid);
      return ToolSuccess(
        data: TextOutput(
          'Clique $button REAL em "$sel" (${center.x.round()}, '
          '${center.y.round()}) — ${count}x.',
          metadata: {'x': center.x, 'y': center.y, 'clickCount': count},
        ),
      );
    });
  }
}

// ============================================================== browser.type

class BrowserTypeTool extends BrowserToolBase {
  @override
  String get id => 'browser.type';
  @override
  String get title => 'Type into field';
  @override
  String get description =>
      'Digita texto REAL tecla a tecla (Input.dispatchKeyEvent keyDown+char+'
      'keyUp) no campo focado por clique de mouse verdadeiro. O valor efetivo '
      'é relido do DOM e reportado — prova real, não presumida.';
  @override
  ToolCategory get category => ToolCategory.browser;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['browserId', 'selector', 'text'],
        'properties': {
          'browserId': {'type': 'string'},
          'selector': {'type': 'string'},
          'text': {'type': 'string'},
          'clearFirst': {
            'type': 'boolean',
            'default': false,
            'description': 'Ctrl+A + Delete antes de digitar',
          },
          'pressEnter': {'type': 'boolean', 'default': false},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    return guarded(() async {
      final b = manager.require(input.str('browserId'));
      if (b.targetId.isEmpty) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Sem página ativa no browser ${b.id}. '
              'Use browser.navigate primeiro.',
        );
      }
      final c = await b.client();
      final sid = await c.attach(b.targetId);
      final sel = input.str('selector');
      final r = await querySelectorOnce(c, sid, sel);
      if (!r.found) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Nenhum campo casa com o seletor: $sel',
        );
      }
      final center = await centerOf(c, sid, r.objectId);
      // foco REAL = clique de verdade no centro do campo
      for (final t in const ['mousePressed', 'mouseReleased']) {
        await c.send(
            'Input.dispatchMouseEvent',
            {
              'type': t,
              'x': center.x,
              'y': center.y,
              'button': 'left',
              'clickCount': 1,
            },
            sessionId: sid);
      }
      if (input.boolOf('clearFirst')) {
        await c.send(
            'Input.dispatchKeyEvent',
            {
              'type': 'rawKeyDown',
              'key': 'a',
              'code': 'KeyA',
              'modifiers': 2, // Ctrl
              'windowsVirtualKeyCode': 65,
            },
            sessionId: sid);
        await c.send(
            'Input.dispatchKeyEvent',
            {
              'type': 'keyUp',
              'key': 'a',
              'modifiers': 2,
              'windowsVirtualKeyCode': 65,
            },
            sessionId: sid);
        await c.send(
            'Input.dispatchKeyEvent',
            {
              'type': 'rawKeyDown',
              'key': 'Delete',
              'code': 'Delete',
              'windowsVirtualKeyCode': 46,
            },
            sessionId: sid);
        await c.send(
            'Input.dispatchKeyEvent',
            {
              'type': 'keyUp',
              'key': 'Delete',
              'windowsVirtualKeyCode': 46,
            },
            sessionId: sid);
      }
      final text = input.str('text');
      for (final rune in text.runes) {
        final ch = String.fromCharCode(rune);
        if (ch == '\n') {
          await _enterKey(c, sid);
        } else {
          await _charKeys(c, sid, ch);
        }
      }
      if (input.boolOf('pressEnter')) await _enterKey(c, sid);
      final val = await c.send(
          'Runtime.callFunctionOn',
          {
            'objectId': r.objectId,
            'functionDeclaration':
                'function(){return this.value!==undefined?this.value:'
                '(this.textContent||"")}',
            'returnByValue': true,
          },
          sessionId: sid);
      final got = ((val['result'] as Map?)?['value'] ?? '').toString();
      await c.send('Runtime.releaseObjectGroup', {'objectGroup': 'vt'},
          sessionId: sid);
      final shown = text.length > 60 ? '${text.substring(0, 60)}…' : text;
      return ToolSuccess(
        data: TextOutput(
          'Digitado REAL em "$sel": "$shown"\n'
          'Valor no DOM agora: "$got"',
          metadata: {'domValue': got, 'typedChars': text.length},
        ),
      );
    });
  }

  static Future<void> _charKeys(_CdpClient c, String sid, String ch) async {
    await c.send(
        'Input.dispatchKeyEvent',
        {'type': 'keyDown', 'text': ch, 'key': ch, 'unmodifiedText': ch},
        sessionId: sid);
    await c.send('Input.dispatchKeyEvent', {'type': 'char', 'text': ch},
        sessionId: sid);
    await c.send('Input.dispatchKeyEvent', {'type': 'keyUp', 'key': ch},
        sessionId: sid);
  }

  static Future<void> _enterKey(_CdpClient c, String sid) async {
    await c.send(
        'Input.dispatchKeyEvent',
        {
          'type': 'rawKeyDown',
          'key': 'Enter',
          'code': 'Enter',
          'windowsVirtualKeyCode': 13,
        },
        sessionId: sid);
    await c.send(
        'Input.dispatchKeyEvent',
        {'type': 'char', 'text': '\r', 'key': 'Enter'},
        sessionId: sid);
    await c.send(
        'Input.dispatchKeyEvent',
        {'type': 'keyUp', 'key': 'Enter', 'windowsVirtualKeyCode': 13},
        sessionId: sid);
  }
}

// ============================================================ browser.select

class BrowserSelectTool extends BrowserToolBase {
  @override
  String get id => 'browser.select';
  @override
  String get title => 'Select option';
  @override
  String get description =>
      'Seleciona <option> REAL de um <select> por value, label ou índice, e '
      'dispara eventos input/change nativos. Option inexistente → erro com a '
      'lista verdadeira das opções disponíveis.';
  @override
  ToolCategory get category => ToolCategory.browser;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['browserId', 'selector'],
        'properties': {
          'browserId': {'type': 'string'},
          'selector': {'type': 'string'},
          'value': {'type': 'string'},
          'label': {'type': 'string', 'description': 'texto visível da option'},
          'index': {'type': 'integer', 'minimum': 0},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    return guarded(() async {
      final b = manager.require(input.str('browserId'));
      if (b.targetId.isEmpty) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Sem página ativa no browser ${b.id}. '
              'Use browser.navigate primeiro.',
        );
      }
      final c = await b.client();
      final sid = await c.attach(b.targetId);
      final sel = input.str('selector');
      final byValue = input.str('value');
      final byLabel = input.str('label');
      final idx = input.intOrNull('index');
      if (byValue.isEmpty && byLabel.isEmpty && idx == null) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Informe value, label ou index para selecionar.',
        );
      }
      final spec = jsonEncode({
        'selector': sel,
        'value': byValue.isEmpty ? null : byValue,
        'label': byLabel.isEmpty ? null : byLabel,
        'index': idx,
      });
      final expr = '(()=>{const s=${jsonEncode(spec)};'
          'const el=document.querySelector(s.selector);'
          'if(!el)return JSON.stringify({ok:false,'
          'err:"select não encontrado: "+s.selector});'
          'if(el.tagName!=="SELECT")return JSON.stringify({ok:false,'
          'err:"elemento não é <select>: "+el.tagName});'
          'const opts=[...el.options];let i=-1;'
          'if(typeof s.index==="number"){i=s.index;}'
          'else if(s.value!=null){i=opts.findIndex(o=>o.value===s.value);}'
          'else{i=opts.findIndex(o=>o.text.trim()===s.label.trim());}'
          'if(i<0||i>=opts.length)return JSON.stringify({ok:false,'
          'err:"option inexistente; disponíveis: "+'
          'opts.map(o=>o.value+" ("+o.text+")").join(", ").slice(0,500)});'
          'el.selectedIndex=i;'
          'el.dispatchEvent(new Event("input",{bubbles:true}));'
          'el.dispatchEvent(new Event("change",{bubbles:true}));'
          'return JSON.stringify({ok:true,value:opts[i].value,'
          'label:opts[i].text,index:i});})()';
      final res = await c.send(
          'Runtime.evaluate',
          {'expression': expr, 'returnByValue': true},
          sessionId: sid);
      final raw = ((res['result'] as Map?)?['value'] ?? '').toString();
      final out = (jsonDecode(raw) as Map).cast<String, Object?>();
      if (out['ok'] != true) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: '${out['err']}',
        );
      }
      return ToolSuccess(
        data: TextOutput(
          'Selecionado REAL em "$sel": índice ${out['index']} — '
          '"${out['label']}" (value="${out['value']}"); eventos input/change '
          'disparados.',
          metadata: out,
        ),
      );
    });
  }
}

// ================================================= browser.wait_for_selector

class BrowserWaitForSelectorTool extends BrowserToolBase {
  @override
  String get id => 'browser.wait_for_selector';
  @override
  String get title => 'Wait for selector';
  @override
  String get description =>
      'Espera condição DOM REAL: attached/visible/detached/gone, via polling '
      'de querySelector + getBoundingClientRect no contexto vivo. Timeout → '
      'erro tipado com a contagem atual honesta (nunca "assume que apareceu").';
  @override
  ToolCategory get category => ToolCategory.browser;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['browserId', 'selector'],
        'properties': {
          'browserId': {'type': 'string'},
          'selector': {'type': 'string'},
          'state': {
            'type': 'string',
            'enum': ['attached', 'visible', 'detached', 'gone'],
            'default': 'visible',
          },
          'timeoutMs': {
            'type': 'integer',
            'default': 10000,
            'maximum': 120000,
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    return guarded(() async {
      final b = manager.require(input.str('browserId'));
      if (b.targetId.isEmpty) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Sem página ativa no browser ${b.id}. '
              'Use browser.navigate primeiro.',
        );
      }
      final c = await b.client();
      final sid = await c.attach(b.targetId);
      final sel = input.str('selector');
      final state =
          input.str('state').isEmpty ? 'visible' : input.str('state');
      final limit = input.intOrNull('timeoutMs') ?? 10000;
      final wantPresent = state == 'attached' || state == 'visible';
      final needVisible = state == 'visible';
      final expr = needVisible
          ? '(()=>{const els=document.querySelectorAll(${jsStr(sel)});'
              'return [...els].some(e=>{const r=e.getBoundingClientRect();'
              'return r.width>0&&r.height>0;})?els.length:-1;})()'
          : 'document.querySelectorAll(${jsStr(sel)}).length';
      final sw = Stopwatch()..start();
      var last = -1;
      while (sw.elapsedMilliseconds < limit) {
        final res = await c.send(
            'Runtime.evaluate',
            {'expression': expr, 'returnByValue': true},
            sessionId: sid);
        last = ((res['result'] as Map?)?['value'] as num?)?.toInt() ?? -1;
        final present = last > 0;
        if (present == wantPresent) {
          return ToolSuccess(
            data: TextOutput(
              'Condição REAL satisfeita: "$sel" ($state) após '
              '${sw.elapsedMilliseconds}ms (ocorrências=$last).',
              metadata: {
                'matchedInMs': sw.elapsedMilliseconds,
                'count': last,
              },
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      throw VtFailure(
        code: VtErrorCode.timeout,
        message: '"$sel" não atingiu estado "$state" em ${limit}ms. '
            'Estado atual: ${last < 0 ? 'existe mas não-visível' : '$last ocorrência(s)'}.',
      );
    });
  }
}

// ======================================================= browser.screenshot

class BrowserScreenshotTool extends BrowserToolBase {
  @override
  String get id => 'browser.screenshot';
  @override
  String get title => 'Screenshot';
  @override
  String get description =>
      'Captura screenshot REAL (Page.captureScreenshot) da viewport, da '
      'página inteira (clip = scrollHeight) ou de um elemento (clip do '
      'boxModel), PNG ou JPEG, gravado em .techvt/ como artefato. Bytes '
      'reais, caminho real.';
  @override
  ToolCategory get category => ToolCategory.browser;
  @override
  RiskLevel get risk => RiskLevel.networkRead;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['browserId'],
        'properties': {
          'browserId': {'type': 'string'},
          'format': {
            'type': 'string',
            'enum': ['png', 'jpeg'],
            'default': 'png'
          },
          'fullPage': {'type': 'boolean', 'default': false},
          'selector': {
            'type': 'string',
            'description': 'captura só o elemento (clip real do boxModel)',
          },
          'quality': {
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
            'description': 'apenas para jpeg',
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    return guarded(() async {
      final b = manager.require(input.str('browserId'));
      if (b.targetId.isEmpty) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Sem página ativa no browser ${b.id}. '
              'Use browser.navigate primeiro.',
        );
      }
      final c = await b.client();
      final sid = await c.attach(b.targetId);
      await c.send('Page.enable', const {}, sessionId: sid);
      final format =
          input.str('format').isEmpty ? 'png' : input.str('format');
      final params = <String, Object?>{'format': format};
      final q = input.intOrNull('quality');
      if (format == 'jpeg' && q != null) params['quality'] = q;
      final sel = input.str('selector');
      if (sel.isNotEmpty) {
        final r = await querySelectorOnce(c, sid, sel);
        if (!r.found) {
          throw VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Nenhum elemento casa com o seletor: $sel',
          );
        }
        final box = await c.send('DOM.getBoxModel', {'objectId': r.objectId},
            sessionId: sid);
        final content =
            (((box['model'] as Map?)?['content'] as List?) ?? const [])
                .cast<num>();
        final xs = [content[0], content[2], content[4], content[6]];
        final ys = [content[1], content[3], content[5], content[7]];
        params['clip'] = {
          'x': xs.reduce(min).toDouble(),
          'y': ys.reduce(min).toDouble(),
          'width': (xs.reduce(max) - xs.reduce(min)).toDouble(),
          'height': (ys.reduce(max) - ys.reduce(min)).toDouble(),
          'scale': 1,
        };
      } else if (input.boolOf('fullPage')) {
        final m = await c.send(
            'Runtime.evaluate',
            {
              'expression':
                  'JSON.stringify({w:document.documentElement.scrollWidth,'
                  'h:document.documentElement.scrollHeight})',
              'returnByValue': true,
            },
            sessionId: sid);
        final dim = (jsonDecode(
                    ((m['result'] as Map?)?['value'] ?? '{}').toString())
                as Map)
            .cast<String, Object?>();
        params['clip'] = {
          'x': 0,
          'y': 0,
          'width': (dim['w'] as num).toDouble(),
          'height': (dim['h'] as num).toDouble(),
          'scale': 1,
        };
      }
      final shot = await c.send('Page.captureScreenshot', params,
          sessionId: sid, timeoutOverride: const Duration(seconds: 45));
      final bytes = base64.decode(shot['data'] as String? ?? '');
      if (bytes.isEmpty) {
        throw VtFailure(
          code: VtErrorCode.internalError,
          message: 'Page.captureScreenshot retornou payload vazio.',
        );
      }
      final dir = joinPath(
          ctx.workspaceRoots.isEmpty || ctx.workspaceRoots.first.isEmpty
              ? Directory.systemTemp.path
              : ctx.workspaceRoots.first,
          '.techvt');
      await Directory(dir).create(recursive: true);
      final file = File(joinPath(dir,
          'shot-${DateTime.now().millisecondsSinceEpoch}.$format'));
      await file.writeAsBytes(bytes, flush: true);
      return ToolSuccess(
        data: TextOutput(
          'Screenshot REAL capturado: ${file.path} (${bytes.length} bytes, '
          '$format${sel.isNotEmpty ? ', elemento "$sel"' : ''}).',
          metadata: {'path': file.path, 'bytes': bytes.length},
        ),
        artifacts: [
          ArtifactRef(kindOf: 'screenshot', pathOrUri: 'file://${file.path}'),
        ],
      );
    });
  }
}

// ======================================================= browser.evaluate_js

class BrowserEvaluateJsTool extends BrowserToolBase {
  @override
  String get id => 'browser.evaluate_js';
  @override
  String get title => 'Evaluate JavaScript';
  @override
  String get description =>
      'Avalia JavaScript REAL no contexto da página viva (Runtime.evaluate '
      'com awaitPromise=true). Risco privileged: aprovação EXPLÍCITA sempre '
      '— código arbitrário roda no perfil do browser. Exceção da página é '
      'retornada crua, nunca engolida.';
  @override
  ToolCategory get category => ToolCategory.browser;
  @override
  RiskLevel get risk => RiskLevel.privileged;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.explicitApproval;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['browserId', 'expression'],
        'properties': {
          'browserId': {'type': 'string'},
          'expression': {'type': 'string'},
          'awaitPromise': {'type': 'boolean', 'default': true},
          'returnByValue': {'type': 'boolean', 'default': true},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    return guarded(() async {
      final b = manager.require(input.str('browserId'));
      if (b.targetId.isEmpty) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Sem página ativa no browser ${b.id}. '
              'Use browser.navigate primeiro.',
        );
      }
      final c = await b.client();
      final sid = await c.attach(b.targetId);
      final res = await c.send(
          'Runtime.evaluate',
          {
            'expression': input.str('expression'),
            'awaitPromise': input.boolOf('awaitPromise', true),
            'returnByValue': input.boolOf('returnByValue', true),
          },
          sessionId: sid,
          timeoutOverride: timeout);
      final ex = res['exceptionDetails'];
      if (ex != null) {
        final desc = ex['exception'] is Map
            ? ((ex['exception'] as Map)['description'] ?? ex['text']).toString()
            : ex['text'].toString();
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Exceção REAL na página: $desc',
        );
      }
      final result = res['result'] as Map?;
      final value = result?['value'];
      final rendered = value == null
          ? (result?['type'] == 'null' ? 'null' : '<sem valor serializável>')
          : (value is String ? value : jsonEncode(value));
      return ToolSuccess(
        data: TextOutput(
          'Resultado (${result?['type'] ?? '?'}):\n$rendered',
          metadata: {'type': result?['type'], 'value': value},
        ),
      );
    });
  }
}

// =========================================================== browser.get_dom

class BrowserGetDomTool extends BrowserToolBase {
  @override
  String get id => 'browser.get_dom';
  @override
  String get title => 'Get DOM';
  @override
  String get description =>
      'Retorna conteúdo REAL da página viva: outerHTML completo (mode=html), '
      'snapshot estruturado com seletores CSS (mode=structured) ou innerText '
      '(mode=text). Truncamento por maxBytes é declarado na saída.';
  @override
  ToolCategory get category => ToolCategory.browser;
  @override
  RiskLevel get risk => RiskLevel.networkRead;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['browserId'],
        'properties': {
          'browserId': {'type': 'string'},
          'mode': {
            'type': 'string',
            'enum': ['html', 'structured', 'text'],
            'default': 'structured',
          },
          'selector': {
            'type': 'string',
            'description': 'escopo (default: document)',
          },
          'maxBytes': {'type': 'integer', 'default': 200000},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    return guarded(() async {
      final b = manager.require(input.str('browserId'));
      if (b.targetId.isEmpty) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Sem página ativa no browser ${b.id}. '
              'Use browser.navigate primeiro.',
        );
      }
      final c = await b.client();
      final sid = await c.attach(b.targetId);
      final mode =
          input.str('mode').isEmpty ? 'structured' : input.str('mode');
      final maxBytes = input.intOrNull('maxBytes') ?? 200000;
      final sel = input.str('selector');
      final scopeExpr = sel.isEmpty
          ? (mode == 'html' ? 'document.documentElement' : 'document.body')
          : 'document.querySelector(${jsStr(sel)})';
      String expr;
      switch (mode) {
        case 'html':
          expr = '(()=>{const e=$scopeExpr;return e?e.outerHTML:null;})()';
        case 'text':
          expr = '(()=>{const e=$scopeExpr;'
              'return e?(e.innerText||e.textContent||""):null;})()';
        default:
          expr = '(()=>{const root=$scopeExpr;'
              'if(!root)return null;'
              'const cssPath=(el)=>{const p=[];let n=el;'
              'while(n&&n.nodeType===1&&p.length<6){let s=n.tagName.toLowerCase();'
              'if(n.id){p.unshift(s+"#"+n.id);break;}'
              'if(n.className&&typeof n.className==="string"){'
              'const cl=n.className.trim().split(/\\s+/)[0];if(cl)s+="."+cl;}'
              'p.unshift(s);n=n.parentElement;}'
              'return p.join(" ");};'
              'const lines=["<"+root.tagName.toLowerCase()+">"];'
              'const walk=(el,d)=>{if(d>6||lines.length>400)return;'
              'for(const ch of el.children){const t=ch.tagName.toLowerCase();'
              'if(t==="script"||t==="style")continue;'
              'const txt=(ch.childElementCount===0)?'
              '(ch.textContent||"").trim().slice(0,80):"";'
              'lines.push(" ".repeat(d*2)+"<"+t+"> "+cssPath(ch)+'
              '(txt?" :: "+txt:""));walk(ch,d+1);}};'
              'walk(root,1);return lines.join("\\n");})()';
      }
      final res = await c.send(
          'Runtime.evaluate',
          {'expression': expr, 'returnByValue': true},
          sessionId: sid,
          timeoutOverride: const Duration(seconds: 20));
      final valueObj = (res['result'] as Map?)?['value'];
      if (valueObj == null) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Nenhum elemento casa com o seletor: $sel',
        );
      }
      var value = valueObj.toString();
      var truncated = false;
      final encoded = utf8.encode(value);
      if (encoded.length > maxBytes) {
        value = utf8.decode(encoded.sublist(0, maxBytes), allowMalformed: true);
        truncated = true;
      }
      return ToolSuccess(
        data: TextOutput(
          'DOM REAL ($mode'
          '${sel.isEmpty ? '' : ', escopo "$sel"'}'
          '${truncated ? ', TRUNCADO a $maxBytes bytes' : ''}):\n$value',
          metadata: {
            'mode': mode,
            'url': b.currentUrl,
            'chars': value.length,
            'truncated': truncated,
          },
        ),
      );
    });
  }
}

// ============================================================ browser.close

class BrowserCloseTool extends BrowserToolBase {
  @override
  String get id => 'browser.close';
  @override
  String get title => 'Close browser';
  @override
  String get description =>
      'Fecha a instância REAL: Browser.close no CDP, espera o exit do '
      'processo (SIGTERM→SIGKILL com grace) e apaga opcionalmente o '
      'diretório de perfil. Reporta evidência (exited=true/false, perfil '
      'apagado/preservado).';
  @override
  ToolCategory get category => ToolCategory.browser;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['browserId'],
        'properties': {
          'browserId': {'type': 'string'},
          'deleteProfile': {
            'type': 'boolean',
            'default': false,
            'description': 'apaga user-data-dir (cookies/login perdidos)',
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    return guarded(() async {
      final id = input.str('browserId');
      final b = manager.require(id);
      try {
        final c = await b.client();
        await c.fireAndForget('Browser.close', const {});
      } catch (_) {
        // alguns builds recusam Browser.close — fallback abaixo é o kill
      }
      await b.disposeConnection();
      var exited = false;
      try {
        await b.process.exit.timeout(const Duration(seconds: 5));
        exited = true;
      } on TimeoutException {
        b.process.kill(ProcessSignal.sigterm);
        try {
          await b.process.exit.timeout(const Duration(seconds: 2));
          exited = true;
        } on TimeoutException {
          exited = b.process.kill(ProcessSignal.sigkill);
        }
      }
      b.state = BrowserState.closed;
      manager.instances.remove(id);
      var profileDeleted = false;
      if (input.boolOf('deleteProfile')) {
        try {
          await Directory(b.profileDir).delete(recursive: true);
          profileDeleted = true;
        } catch (_) {/* reportado como preservado */}
      }
      return ToolSuccess(
        data: TextOutput(
          'Browser $id (pid=${b.pid}) '
          '${exited ? 'encerrado de verdade' : 'encerrou com dificuldade (sigkill enviado)'}. '
          'Perfil ${profileDeleted ? 'APAGADO' : 'preservado'}: ${b.profileDir}',
          metadata: {
            'exited': exited,
            'profileDeleted': profileDeleted,
            'profileDir': b.profileDir,
          },
        ),
      );
    });
  }
}

// ========================================== CDP: WebSocket cru + JSON-RPC

/// Cliente CDP mínimo e honesto: handshake HTTP Upgrade + frames RFC 6455
/// feitos à mão (a app não depende de pacotes externos). Requests têm id
/// monotônico; respostas `error` viram VtFailure com código/mensagem CRUS do
/// browser; eventos são roteados por sessionId para waiters registrados.
class _CdpClient {
  _CdpClient(this._socket);

  final Socket _socket;
  int _nextId = 1;
  bool _closed = false;
  StreamSubscription<List<int>>? _readSub;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  final List<_EventWaiter> _waiters = [];
  final Map<String, String> _sessionByTarget = {};
  BytesBuilder _frameAcc = BytesBuilder(copy: false);

  bool get isClosed => _closed;

  static Future<_CdpClient> connect(String wsUrl) async {
    final uri = Uri.parse(wsUrl);
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Endpoint CDP não é ws(s)://: $wsUrl',
      );
    }
    final socket = await Socket.connect(uri.host, uri.port,
        timeout: const Duration(seconds: 10));
    final client = _CdpClient(socket);
    await client._handshake(uri);
    return client;
  }

  Future<void> _handshake(Uri uri) async {
    final key =
        base64.encode(List<int>.generate(16, (_) => _rnd.nextInt(256)));
    final path = '${uri.path.isEmpty ? '/' : uri.path}'
        '${uri.query.isEmpty ? '' : '?${uri.query}'}';
    final req = 'GET $path HTTP/1.1\r\n'
        'Host: ${uri.host}:${uri.hasPort ? uri.port : 80}\r\n'
        'Upgrade: websocket\r\nConnection: Upgrade\r\n'
        'Sec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n';
    final completer = Completer<void>();
    final headerBuf = BytesBuilder(copy: true);
    late StreamSubscription<List<int>> preSub;
    preSub = _socket.listen((data) {
      if (completer.isCompleted) return;
      headerBuf.add(data);
      final bytes = headerBuf.toBytes();
      final text = latin1.decode(bytes, allowInvalid: true);
      final idx = text.indexOf('\r\n\r\n');
      if (idx < 0) return;
      final statusLine = text.split('\r\n').first;
      if (!statusLine.contains(' 101 ')) {
        completer.completeError(VtFailure(
          code: VtErrorCode.sidecarNotRunning,
          message: 'Handshake WebSocket recusada: $statusLine',
        ));
        return;
      }
      // deslocamento em BYTES do prefixo de header (latin1 é 1 byte/char)
      final consumed = idx + 4;
      preSub.pause();
      if (bytes.length > consumed) {
        _frameAcc.add(bytes.sublist(consumed));
      }
      completer.complete();
    }, onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    });
    _socket.add(utf8.encode(req));
    await _socket.flush();
    try {
      await completer.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      await preSub.cancel();
      throw VtFailure(
        code: VtErrorCode.timeout,
        message: 'Handshake CDP expirou (browser não respondeu).',
      );
    }
    await preSub.cancel();
    _readSub = _socket.listen(_onBytes,
        onError: (Object _) => _failAll('conexão CDP caiu'),
        onDone: () => _failAll('conexão fechada pelo browser'));
  }

  void _failAll(String reason) {
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(VtFailure(
          code: VtErrorCode.sidecarNotRunning,
          message: 'CDP desconectado: $reason',
        ));
      }
    }
    _pending.clear();
    for (final w in _waiters) {
      if (!w.completer.isCompleted) {
        w.completer.completeError(VtFailure(
          code: VtErrorCode.sidecarNotRunning,
          message: 'CDP desconectado: $reason',
        ));
      }
    }
    _waiters.clear();
  }

  // --------------------------------------------------------- frame reader
  void _onBytes(List<int> chunk) {
    _frameAcc.add(chunk);
    final bytes = _frameAcc.takeBytes();
    _frameAcc = BytesBuilder(copy: false);
    var off = 0;
    while (true) {
      final next = _tryParseFrame(bytes, off);
      if (next == null) break;
      off = next;
    }
    if (off < bytes.length) _frameAcc.add(bytes.sublist(off));
  }

  /// Decodifica um frame server→client (nunca mascarado) a partir de [start];
  /// retorna offset seguinte ou null se ainda incompleto.
  int? _tryParseFrame(List<int> data, int start) {
    if (data.length - start < 2) return null;
    final opcode = data[start] & 0x0f;
    var len = data[start + 1] & 0x7f;
    var pos = start + 2;
    if (len == 126) {
      if (data.length - pos < 2) return null;
      len = (data[pos] << 8) | data[pos + 1];
      pos += 2;
    } else if (len == 127) {
      if (data.length - pos < 8) return null;
      var l = 0;
      for (var i = 0; i < 8; i++) {
        l = (l << 8) | data[pos + i];
      }
      len = l;
      pos += 8;
    }
    if (data.length - pos < len) return null;
    final payload = data.sublist(pos, pos + len);
    final next = pos + len;
    switch (opcode) {
      case 0x1:
      case 0x2:
        _dispatch(utf8.decode(payload, allowMalformed: true));
      case 0x8:
        unawaited(close());
      case 0x9: // ping → pong com mesmo payload
        _sendRaw(_encodeFrame(0xA, Uint8List.fromList(payload)));
      case 0xA: // pong ignorado
        break;
      default:
        break;
    }
    return next;
  }

  void _dispatch(String text) {
    Map<String, Object?> msg;
    try {
      msg = (jsonDecode(text) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    final id = msg['id'];
    if (id is int) {
      final c = _pending.remove(id);
      if (c == null || c.isCompleted) return;
      final err = msg['error'];
      if (err != null) {
        final m = err is Map
            ? err.cast<String, Object?>()
            : <String, Object?>{'message': err.toString()};
        c.completeError(VtFailure(
          code: VtErrorCode.sidecarNotRunning,
          message: 'Erro REAL do browser no CDP '
              '"${m['code'] ?? '?'}": ${m['message'] ?? err}',
          details: m,
        ));
      } else {
        c.complete(
            ((msg['result'] as Map?) ?? const {}).cast<String, Object?>());
      }
      return;
    }
    final method = msg['method'];
    if (method is String) {
      final sid = msg['sessionId'] as String? ?? '';
      final params =
          ((msg['params'] as Map?) ?? const {}).cast<String, Object?>();
      for (final w in _waiters.toList()) {
        if (w.sessionId == sid && w.method == method) {
          _waiters.remove(w);
          if (!w.completer.isCompleted) w.completer.complete(params);
        }
      }
    }
  }

  // ---------------------------------------------------------- frame writer
  Uint8List _encodeFrame(int opcode, Uint8List payload) {
    final maskKey =
        Uint8List.fromList(List<int>.generate(4, (_) => _rnd.nextInt(256)));
    final masked = Uint8List(payload.length);
    for (var i = 0; i < payload.length; i++) {
      masked[i] = payload[i] ^ maskKey[i % 4];
    }
    final header = <int>[0x80 | opcode];
    final n = payload.length;
    if (n < 126) {
      header.add(0x80 | n);
    } else if (n < 65536) {
      header.add(0x80 | 126);
      header.add((n >> 8) & 0xff);
      header.add(n & 0xff);
    } else {
      header.add(0x80 | 127);
      for (var i = 7; i >= 0; i--) {
        header.add((n >> (8 * i)) & 0xff);
      }
    }
    header.addAll(maskKey);
    return Uint8List.fromList([...header, ...masked]);
  }

  void _sendRaw(Uint8List frame) {
    if (_closed) return;
    _socket.add(frame);
    unawaited(_socket.flush());
  }

  // -------------------------------------------------------------- requests
  Future<Map<String, Object?>> send(
    String method,
    Map<String, Object?> params, {
    String? sessionId,
    Duration? timeoutOverride,
  }) async {
    if (_closed) {
      throw VtFailure.sidecarNotRunning('browser (conexão CDP fechada)');
    }
    final id = _nextId++;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    _sendTextMessage({
      'id': id,
      'method': method,
      'params': params,
      if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
    });
    final limit = timeoutOverride ?? const Duration(seconds: 20);
    return c.future.timeout(limit, onTimeout: () {
      _pending.remove(id);
      throw VtFailure(
        code: VtErrorCode.timeout,
        message:
            'Timeout de ${limit.inSeconds}s esperando resposta CDP de "$method".',
      );
    });
  }

  /// Envia sem esperar resposta (Browser.close derruba o socket antes de
  /// responder — aguardar geraria erro falso).
  Future<void> fireAndForget(
      String method, Map<String, Object?> params) async {
    if (_closed) return;
    _sendTextMessage({'id': _nextId++, 'method': method, 'params': params});
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  void _sendTextMessage(Map<String, Object?> msg) {
    _sendRaw(
        _encodeFrame(0x1, Uint8List.fromList(utf8.encode(jsonEncode(msg)))));
  }

  /// Registra espera por um evento CDP (ex.: Page.loadEventFired).
  ({Completer<Map<String, Object?>> future, _EventWaiter handle})
      waitForEvent(String sessionId, String method) {
    final w = _EventWaiter(
        sessionId: sessionId, method: method, completer: Completer());
    _waiters.add(w);
    return (future: w.completer, handle: w);
  }

  Future<String> attach(String targetId) async {
    final existing = _sessionByTarget[targetId];
    if (existing != null) return existing;
    final res = await send(
        'Target.attachToTarget', {'targetId': targetId, 'flatten': true});
    final sid = res['sessionId'] as String? ?? '';
    if (sid.isEmpty) {
      throw VtFailure(
        code: VtErrorCode.sidecarNotRunning,
        message: 'Target.attachToTarget não devolveu sessionId para '
            '$targetId.',
      );
    }
    _sessionByTarget[targetId] = sid;
    return sid;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _readSub?.cancel();
    try {
      _socket.add(_encodeFrame(0x8, Uint8List(0)));
      await _socket.flush();
    } catch (_) {}
    _socket.destroy();
  }
}

class _EventWaiter {
  _EventWaiter(
      {required this.sessionId,
      required this.method,
      required this.completer});
  final String sessionId;
  final String method;
  final Completer<Map<String, Object?>> completer;
}
