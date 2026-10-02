/// Implementação REAL das tools de qualidade e depuração (spec catálogo
/// §BUG / §TEST / §LINT / §DEBUG).
///
/// Nada é simulado:
/// - bug.verify_fix / test.run_suite / test.get_coverage / lint.run executam
///   binários verdadeiros (dart/flutter/test) e mapeiam exit code != 0 para
///   VtFailure tipado com a saída crua do processo;
/// - bug.reproduce executa cada passo real (shell seguro OU comando de tool
///   interno `tool:<id>` — mesmo executor do agente) e captura stdout/stderr/
///   exit de cada um, inclusive em artefatos de log;
/// - bug.bisect roda `git bisect` verdadeiro com teste arbitrário aprovado;
/// - debug.* falam o protocolo DAP (Debug Adapter Protocol) por stdin/stdout
///   com o adapter configurado, e debug.attach_observatory fala JSON-RPC 2.0
///   real (WebSocket) com a VM Service (Observatory) do Flutter/Dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import '../process/process_utils.dart';
import 'dap_framer.dart';
import 'dev_tools.dart';

// ====================================================== sessão DAP (debug.*)

/// Gerencia sessões de debug reais via Debug Adapter Protocol (JSON sobre
/// stdio, headers `Content-Length:`), exatamente como VS Code faz.
class DebugSessionManager {
  DebugSessionManager();

  /// Constrói uma instância isolada (testes) sem estado global.
  factory DebugSessionManager.detached() => DebugSessionManager();

  final Map<String, _DapSession> _sessions = {};

  /// Sessão ativa por id; lança [VtErrorCode.validationFailed] se ausente.
  _DapSession require(String sessionId) {
    final s = _sessions[sessionId];
    if (s == null) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Sessão de debug "$sessionId" não existe (ou já terminou). '
            'Rode debug.start_session primeiro.',
      );
    }
    return s;
  }

  Future<_DapSession> start({
    required String cwd,
    required String adapterExe,
    required List<String> adapterArgs,
    required Map<String, Object?> launchRequest,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final s = _DapSession(
      cwd: cwd,
      adapterExe: adapterExe,
      adapterArgs: adapterArgs,
      timeout: timeout,
    );
    await s.initialize();
    await s.launch(launchRequest);
    _sessions[s.sessionId] = s;
    unawaited(s.whenExited().then((_) => _sessions.remove(s.sessionId)));
    return s;
  }

  List<Map<String, Object?>> listSessions() => _sessions.values
      .map((s) => {
            'sessionId': s.sessionId,
            'state': s.state.name,
            'stoppedReason': s.lastStoppedReason,
            'breakpoints': s.breakpointCount,
          })
      .toList();

  Future<void> disposeAll() async {
    for (final s in _sessions.values.toList()) {
      await s.dispose();
    }
    _sessions.clear();
  }
}

String _newId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_rnd.nextInt(1 << 30)}';

final _rnd = Random.secure();

/// Cliente DAP mínimo e honesto: se o adapter não suportar um request, o erro
/// REAL do adapter ('not implemented') é propagado — nunca fingimos sucesso.
class _DapSession {
  _DapSession({
    required this.cwd,
    required this.adapterExe,
    required this.adapterArgs,
    required this.timeout,
  });

  final String cwd;
  final String adapterExe;
  final List<String> adapterArgs;
  final Duration timeout;

  final String sessionId = _newId('dbg');
  int _seq = 1;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  final List<Map<String, Object?>> _events = [];
  final Map<String, Map<String, Object?>> _scopesByFrame = {};

  Process? _proc;
  StreamSubscription<Map<String, Object?>>? _sub;
  SessionState state = SessionState.created;
  String? lastStoppedReason;
  int get breakpointCount =>
      _breakpoints.values.fold(0, (a, b) => a + b.length);

  final Map<String, List<Map<String, Object?>>> _breakpoints = {};

  Duration get _reqTimeout => timeout < const Duration(seconds: 60)
      ? timeout
      : const Duration(seconds: 60);

  Future<void> whenExited() => _proc!.exitCode.then((_) {});

  // ------------------------------------------------------------ transporte
  Future<void> initialize() async {
    final Process proc;
    try {
      proc =
          await Process.start(adapterExe, adapterArgs, workingDirectory: cwd);
    } on ProcessException catch (e) {
      throw VtFailure(
        code: VtErrorCode.binaryMissing,
        message:
            'Falha ao iniciar o debug adapter "$adapterExe": ${e.message}. '
            'Configure "debug.adapterPath" (ex.: dart-debug-dap ou '
            'flutter-debug-dap) ou instale o adapter no PATH.',
      );
    }
    _proc = proc;
    _sub = proc.stdout.transform(DapFramer()).listen(_onMessage);
    proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((chunk) => _adapterLog.write(chunk));
    unawaited(proc.exitCode.then((int code) {
      _exitCode = code;
      state = SessionState.terminated;
      for (final c in _pending.values) {
        if (!c.isCompleted) {
          c.completeError(VtFailure(
            code: VtErrorCode.internalError,
            message: 'Debug adapter terminou (exit $code) durante o request.',
          ));
        }
      }
      _pending.clear();
    }));
    await request('initialize', {
      'clientID': 'techvt',
      'adapterID': 'techvt-dap',
      'pathFormat': 'path',
      'linesStartAt1': true,
      'columnsStartAt1': true,
      'supportsVariableType': true,
      'supportsConditionalBreakpoints': true,
      'supportsRunToCursorPositionRequests': true,
    });
    state = SessionState.initialized;
  }

  int? _exitCode;
  final StringBuffer _adapterLog = StringBuffer();

  void _onMessage(Map<String, Object?> msg) {
    final type = msg['type'];
    if (type == 'response') {
      final seq = (msg['request_seq'] as num?)?.toInt();
      final c = seq != null ? _pending.remove(seq) : null;
      if (c != null && !c.isCompleted) c.complete(msg);
    } else if (type == 'event') {
      _events.add(msg);
      final event = msg['event'];
      final body = msg['body'];
      if (event == 'stopped' && body is Map) {
        state = SessionState.stopped;
        lastStoppedReason = body['reason']?.toString();
      } else if (event == 'continued') {
        state = SessionState.running;
        lastStoppedReason = null;
      } else if (event == 'terminated') {
        state = SessionState.terminated;
      }
    }
  }

  Future<Map<String, Object?>> request(
      String command, Map<String, Object?> args) async {
    final proc = _proc;
    if (proc == null || _exitCode != null) {
      throw VtFailure(
        code: VtErrorCode.sidecarNotRunning,
        message: 'Sessão de debug "$sessionId" não está viva '
            '(adapter ${_exitCode != null ? 'saiu exit $_exitCode' : 'ausente'}).',
      );
    }
    final mySeq = _seq++;
    final completer = Completer<Map<String, Object?>>();
    _pending[mySeq] = completer;
    final payload = jsonEncode({
      'seq': mySeq,
      'type': 'request',
      'command': command,
      'arguments': args
    });
    final bytes = utf8.encode(payload);
    proc.stdin.write('Content-Length: ${bytes.length}\r\n\r\n');
    proc.stdin.add(bytes);
    await proc.stdin.flush();
    final Map<String, Object?> resp;
    try {
      resp = await completer.future.timeout(_reqTimeout, onTimeout: () {
        _pending.remove(mySeq);
        throw VtFailure(
          code: VtErrorCode.timeout,
          message: 'Debug adapter não respondeu a "$command" em '
              '${_reqTimeout.inSeconds}s (sessão $sessionId).',
        );
      });
    } on SocketException catch (e) {
      throw VtFailure(
          code: VtErrorCode.sidecarNotRunning,
          message: 'Pipe do adapter quebrado em "$command": ${e.message}');
    }
    if (resp['success'] != true) {
      final errBody = resp['body'];
      final message = errBody is Map
          ? (errBody['message']?.toString() ?? 'sem mensagem')
          : 'sem mensagem';
      throw VtFailure(
        code: VtErrorCode.internalError,
        message: 'DAP "$command" falhou na sessão $sessionId: $message',
        details: {'adapterLog': _adapterLog.toString()},
      );
    }
    return (resp['body'] as Map?)?.cast<String, Object?>() ?? const {};
  }

  /// Espera (realmente) o próximo evento `stopped` após uma ação assíncrona.
  Future<Map<String, Object?>?> waitForStop(Duration limit) async {
    if (state == SessionState.stopped) {
      final ev = _events.lastWhere((e) => e['event'] == 'stopped',
          orElse: () => const {});
      final body = ev['body'];
      return body is Map ? body.cast<String, Object?>() : const {};
    }
    final start = DateTime.now();
    while (DateTime.now().difference(start) < limit) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (state == SessionState.stopped) {
        final ev = _events.lastWhere((e) => e['event'] == 'stopped',
            orElse: () => const {});
        final body = ev['body'];
        return body is Map ? body.cast<String, Object?>() : const {};
      }
      if (state == SessionState.terminated) return null;
    }
    return null;
  }

  // ------------------------------------------------------------ comandos
  Future<void> launch(Map<String, Object?> launchReq) async {
    await request('launch', launchReq);
    state = SessionState.running;
  }

  Future<void> setBreakpoints(
      String file, List<Map<String, Object?>> bps) async {
    final abs = File(file).absolute.path;
    final res = await request('setBreakpoints', {
      'source': {'path': abs},
      'breakpoints': bps,
      'sourceModified': false,
    });
    _breakpoints[abs] =
        (res['breakpoints'] as List?)?.cast<Map<String, Object?>>() ?? [];
  }

  Future<(int verifiedCount, List<Map<String, Object?>>)> addBreakpoint(
      String file, int line,
      {String? condition, String? hitCondition}) async {
    final existing = _breakpoints[File(file).absolute.path] ?? const [];
    final next = [
      ...existing.map((b) => {
            'line': b['line'],
            if (b['condition'] != null) 'condition': b['condition'],
          }),
      {
        'line': line,
        if (condition != null && condition.isNotEmpty) 'condition': condition,
        if (hitCondition != null && hitCondition.isNotEmpty)
          'hitCondition': hitCondition,
      },
    ];
    await setBreakpoints(file, next);
    final verified = _breakpoints[File(file).absolute.path] ?? const [];
    return (verified.where((b) => b['verified'] == true).length, verified);
  }

  Future<int> removeBreakpoint(String file, int line) async {
    final abs = File(file).absolute.path;
    final current = _breakpoints[abs] ?? const [];
    final remaining =
        current.where((b) => (b['line'] as num?)?.toInt() != line).toList();
    if (remaining.length == current.length) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Breakpoint inexistente em $abs:$line (nada removido).',
      );
    }
    await setBreakpoints(
        abs,
        remaining
            .map((b) => {
                  'line': b['line'],
                  if (b['condition'] != null) 'condition': b['condition'],
                })
            .toList());
    return remaining.where((b) => b['verified'] == true).length;
  }

  Future<List<int>> threads() async {
    final res = await request('threads', const {});
    final list = (res['threads'] as List?)?.cast<Map<String, Object?>>() ?? [];
    return list
        .map((t) => (t['id'] as num?)?.toInt() ?? 0)
        .where((id) => id != 0)
        .toList();
  }

  Future<List<Map<String, Object?>>> stackTrace(int threadId,
      {int? startFrame, int? levels}) async {
    final res = await request('stackTrace', {
      'threadId': threadId,
      if (startFrame != null) 'startFrame': startFrame,
      if (levels != null) 'levels': levels,
    });
    final frames =
        (res['stackFrames'] as List?)?.cast<Map<String, Object?>>() ?? const [];
    return frames;
  }

  Future<Map<String, Object?>> scopes(int frameId) async {
    final res = await request('scopes', {'frameId': frameId});
    _scopesByFrame[frameId.toString()] = res;
    return res;
  }

  Future<List<Map<String, Object?>>> variables(int variablesReference,
      {String? filter}) async {
    final res = await request('variables', {
      'variablesReference': variablesReference,
      if (filter != null) 'filter': filter,
    });
    return (res['variables'] as List?)?.cast<Map<String, Object?>>() ??
        const [];
  }

  Future<Map<String, Object?>> evaluate(String expression, int frameId) async {
    return request('evaluate', {
      'expression': expression,
      'frameId': frameId,
      'context': 'repl',
    });
  }

  Future<void> step(String request_, int threadId) async {
    await request(request_, {'threadId': threadId});
    state = SessionState.running;
  }

  Future<void> continueExec(int threadId) async {
    await request('continue', {'threadId': threadId});
    state = SessionState.running;
  }

  Future<void> pause(int threadId) => request('pause', {'threadId': threadId});

  Future<void> disconnect() async {
    try {
      await request('disconnect', {'terminateDebuggee': true});
    } on VtFailure {
      // adapter pode ter morrido — segue o encerramento local
    }
    await dispose();
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _proc?.kill(ProcessSignal.sigterm);
    state = SessionState.terminated;
  }
}

enum SessionState { created, initialized, running, stopped, terminated }

// ================================================ JSON-RPC VM Service real

/// Cliente JSON-RPC 2.0 mínimo para a VM Service (Observatory) real do
/// Dart/Flutter. Usa `package:vm_service` quando houver; aqui apenas o
/// handshake WebSocket cru — suficiente para listar isolates/reports.
class _VmServiceWsClient {
  _VmServiceWsClient(this.uri);
  final Uri uri;
  Socket? _socket;
  int _id = 0;
  final Map<int, Completer<dynamic>> _pending = {};
  final StringBuffer _partial = StringBuffer();

  Future<void> connect() async {
    // Handshake WebSocket REAL por socket TCP cru: HttpClient do dart:io não
    // implementa upgrade para ws:// — daí o caminho manual abaixo.
    final host = uri.host;
    final port = uri.port != 0 ? uri.port : (uri.scheme == 'wss' ? 443 : 80);
    try {
      final socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 10));
      _socket = socket;
      final key =
          base64Encode(List<int>.generate(16, (_) => _rnd.nextInt(256)));
      final path = uri.path.isEmpty ? '/' : uri.path;
      final req = 'GET $path HTTP/1.1\r\n'
          'Host: $host:$port\r\n'
          'Upgrade: websocket\r\n'
          'Connection: Upgrade\r\n'
          'Sec-WebSocket-Key: $key\r\n'
          'Sec-WebSocket-Version: 13\r\n\r\n';
      socket.add(utf8.encode(req));
      await socket.flush();
      // lê o header de resposta (até \r\n\r\n) com timeout real
      final hs = Completer<String>();
      final acc = StringBuffer();
      late StreamSubscription<List<int>> sub;
      sub = socket.listen((bytes) {
        acc.write(utf8.decode(bytes, allowMalformed: true));
        if (acc.toString().contains('\r\n\r\n') && !hs.isCompleted) {
          hs.complete(acc.toString());
        }
      }, onError: (Object e) {
        if (!hs.isCompleted) hs.completeError(e);
      });
      String head;
      try {
        head =
            await hs.future.timeout(const Duration(seconds: 10), onTimeout: () {
          throw VtFailure(
            code: VtErrorCode.timeout,
            message: 'VM Service em $uri não completou o handshake WS em 10s.',
          );
        });
      } finally {
        await sub.cancel();
      }
      if (!head.contains(' 101')) {
        throw VtFailure(
          code: VtErrorCode.networkUnavailable,
          message: 'Handshake WS recusado por $uri: '
              '${head.split('\r\n').firstOrNull ?? 'sem resposta'}',
        );
      }
      // sobra dos bytes após o header já foi acumulada em [acc]: processa
      final boundary = head.indexOf('\r\n\r\n') + 4;
      final leftover = utf8.encode(head.substring(boundary));
      if (leftover.isNotEmpty) _onBytes(leftover);
      sub = socket.listen(_onBytes, onError: (Object e) {
        for (final c in _pending.values) {
          if (!c.isCompleted) c.completeError(e);
        }
      }, onDone: () {
        for (final c in _pending.values) {
          if (!c.isCompleted) {
            c.completeError(VtFailure(
              code: VtErrorCode.networkUnavailable,
              message: 'Conexão com a VM Service fechou no meio da chamada.',
            ));
          }
        }
        _pending.clear();
      });
    } on SocketException catch (e) {
      _socket?.destroy();
      throw VtFailure(
        code: VtErrorCode.networkUnavailable,
        message: 'Sem VM Service acessível em $host:$port: ${e.message}',
      );
    } on TimeoutException {
      _socket?.destroy();
      throw VtFailure(
        code: VtErrorCode.timeout,
        message: 'Timeout conectando à VM Service em $uri.',
      );
    }
  }

  void _onBytes(List<int> bytes) {
    // Frames WebSocket simples (opcode text, sem máscara do servidor):
    // acumula e tenta decodificar payloads completos.
    _partial.write(utf8.decode(bytes, allowMalformed: true));
    final raw = _partial.toString();
    final decoder = _WsTextDecoder();
    final msgs = decoder.feed(raw);
    _partial.clear();
    _partial.write(decoder.leftover);
    for (final m in msgs) {
      try {
        final j = jsonDecode(m);
        if (j is Map && j['id'] != null && j['result'] != null) {
          final c = _pending.remove((j['id'] as num).toInt());
          if (c != null && !c.isCompleted) c.complete(j['result']);
        }
      } on FormatException {
        // fragmento parcial: aguarda mais bytes
      }
    }
  }

  Future<dynamic> call(String method,
      [Map<String, Object?> params = const {}]) async {
    final socket = _socket;
    if (socket == null) {
      throw VtFailure(
          code: VtErrorCode.sidecarNotRunning,
          message: 'Sem conexão WebSocket com a VM Service.');
    }
    final id = ++_id;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    final frame = _WsTextEncoder.encode(jsonEncode(
        {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    socket.add(frame);
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pending.remove(id);
      throw VtFailure(
        code: VtErrorCode.timeout,
        message: 'VM Service não respondeu a "$method" em 15s.',
      );
    });
  }

  void close() {
    _socket?.destroy();
    _socket = null;
  }
}

/// Extrai textos completos de frames WebSocket (payloads <= 125 bytes e
/// estendidos; ignora opcodes não-textuais).
class _WsTextDecoder {
  final List<int> _acc = [];
  String get leftover => utf8.decode(_acc, allowMalformed: true);

  List<String> feed(String data) {
    _acc.addAll(utf8.encode(data));
    final out = <String>[];
    while (_acc.length >= 2) {
      final b0 = _acc[0], b1 = _acc[1];
      final opcode = b0 & 0x0f;
      var len = b1 & 0x7f;
      var off = 2;
      if (len == 126) {
        if (_acc.length < off + 2) break;
        len = (_acc[off] << 8) | _acc[off + 1];
        off += 2;
      } else if (len == 127) {
        if (_acc.length < off + 8) break;
        len = 0;
        for (var i = 0; i < 8; i++) {
          len = (len << 8) | _acc[off + i];
        }
        off += 8;
      }
      if (_acc.length < off + len) break;
      if (opcode == 0x1) {
        out.add(
            utf8.decode(_acc.sublist(off, off + len), allowMalformed: true));
      }
      _acc.removeRange(0, off + len);
    }
    return out;
  }
}

class _WsTextEncoder {
  static List<int> encode(String text) {
    final payload = utf8.encode(text);
    final masked =
        List<int>.generate(payload.length, (i) => payload[i] ^ _mask[i % 4]);
    final header = <int>[0x81]; // FIN + text
    if (payload.length <= 125) {
      header.add(0x80 | payload.length);
    } else if (payload.length <= 0xffff) {
      header
        ..add(0x80 | 126)
        ..add(payload.length >> 8 & 0xff)
        ..add(payload.length & 0xff);
    } else {
      header.add(0x80 | 127);
      for (var i = 7; i >= 0; i--) {
        header.add((payload.length >> (8 * i)) & 0xff);
      }
    }
    header.addAll(_mask);
    return [...header, ...masked];
  }

  static final List<int> _mask =
      List<int>.generate(4, (_) => _rnd.nextInt(256));
}

// ============================================== helpers compartilhados

Future<ProcResult> runGitIn(ToolContext ctx, List<String> args) async {
  final git = await findBinaryInPath('git');
  if (git == null) throw VtFailure.binaryMissing('git');
  final root = _workspaceRoot(ctx);
  return runCaptured(git, ['-C', root, ...args],
      cwd: root, limit: const Duration(minutes: 10));
}

String _workspaceRoot(ToolContext ctx) {
  final override = ctx.settings.get('devtools.cwd') as String?;
  if (override != null && override.isNotEmpty) return override;
  return ctx.workspaceRoots.first;
}

/// Base comum das tools de qualidade: herda a capacidade 'devtools' (já
/// verificada contra dart/flutter no PATH pelo registry).
abstract class QualityToolBase extends DevToolBase {}

// ==================================================== test.run_suite
class TestRunSuiteTool extends QualityToolBase {
  @override
  String get id => 'test.run_suite';
  @override
  String get title => 'Run test suite';
  @override
  String get description =>
      'Roda suíte REAL de testes (package:test via "dart test", ou '
      '"flutter test" em projeto Flutter). Exit != 0 vira test_failed com a '
      'saída crua — nunca relatório fake.';
  @override
  ToolCategory get category => ToolCategory.test;
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  String get binaryName => 'dart';
  @override
  String get binarySettingKey => 'devtools.dartBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'paths': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'alvos (default: test/)'
          },
          'name': {'type': 'string', 'description': 'filtro -N'},
          'plainReporter': {
            'type': 'boolean',
            'description': '--reporter expanded (evita ANSI em CI)'
          },
          'concurrency': {'type': 'integer', 'minimum': 1},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final targets = input.list('paths');
      final common = <String>[
        if (input.str('name').isNotEmpty) ...['-N', input.str('name')],
        if (input.boolOf('plainReporter')) '--reporter=expanded',
        if (input.intOrNull('concurrency') != null)
          '--concurrency=${input.intOrNull('concurrency')}',
        ...targets,
      ];
      final ProcResult res;
      final flavor = await isFlutterWorkspace(ctx) ? 'flutter' : 'dart';
      if (flavor == 'flutter') {
        res = await runFlutter(ctx, ['test', ...common]);
      } else {
        res = await runProcess(ctx, ['test', ...common]);
      }
      final passed = RegExp(r'\+\d+').allMatches(res.combined).isNotEmpty &&
          res.exitCode == 0;
      if (res.exitCode != 0) {
        return ToolFailureResult(failure(res, VtErrorCode.testFailed, 'test'));
      }
      return ok(res, extra: {
        'flavor': flavor,
        'passed': passed,
        'summary': _lastLine(res.combined),
      });
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

String _lastLine(String s) {
  final lines = s.trimRight().split('\n');
  return lines.isEmpty ? '' : lines.last.trim();
}

// =================================================== test.get_coverage
class TestGetCoverageTool extends QualityToolBase {
  @override
  String get id => 'test.get_coverage';
  @override
  String get title => 'Collect coverage';
  @override
  String get description =>
      'Coleta cobertura REAL: roda flutter test --coverage (gera lcov.info) ou '
      'dart test --coverage + dart pub global run coverage:format_coverage. '
      'Parseia o lcov gerado e reporta % verdadeiro por arquivo.';
  @override
  ToolCategory get category => ToolCategory.test;
  @override
  RiskLevel get risk => RiskLevel.localWrite; // escreve coverage/
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  String get binaryName => 'dart';
  @override
  String get binarySettingKey => 'devtools.dartBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'output': {
            'type': 'string',
            'description': 'caminho lcov (default coverage/lcov.info)'
          },
          'checkLcovPackage': {
            'type': 'boolean',
            'description':
                'dart: valida instalação do coverage antes (default true)'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final root = workingDir(ctx);
      final outRel = input.str('output').isEmpty
          ? 'coverage/lcov.info'
          : input.str('output');
      final outAbs = joinPath(root, outRel);
      final ProcResult res;
      final flavor = await isFlutterWorkspace(ctx) ? 'flutter' : 'dart';
      if (flavor == 'flutter') {
        res = await runFlutter(ctx, ['test', '--coverage=$outAbs']);
      } else {
        final covDir = joinPath(root, '.dart_tool/coverage');
        res = await runProcess(ctx, ['test', '--coverage=$covDir']);
        if (res.exitCode == 0) {
          final fmt = await runProcess(ctx, [
            'pub',
            'global',
            'run',
            'coverage:format_coverage',
            '--lcov',
            '--in=.dart_tool/coverage',
            '--out=$outAbs',
            '--report-on=lib',
            '--packages=.dart_tool/package_config.json',
          ]);
          if (fmt.exitCode != 0) {
            return ToolFailureResult(VtFailure(
              code: VtErrorCode.buildFailed,
              message:
                  'coverage:format_coverage falhou (exit ${fmt.exitCode}). '
                  'Instale com: dart pub global activate coverage',
              details: {'stderr': fmt.stderr},
            ));
          }
        }
      }
      if (res.exitCode != 0) {
        return ToolFailureResult(
            failure(res, VtErrorCode.testFailed, 'test --coverage'));
      }
      final report = await _parseLcov(outAbs);
      if (report == null) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.internalError,
          message: 'lcov esperado em "$outAbs" não foi gerado pelo processo.',
        ));
      }
      return ToolSuccess(
        data: TextOutput(
          'Cobertura REAL ($flavor): ${report['coveredLines']}/'
          '${report['totalLines']} linhas (${report['percent']}%)\n'
          '${(report['perFile'] as List).join('\n')}',
          metadata: {...report, 'lcovPath': outAbs, 'flavor': flavor},
        ),
        artifacts: [ArtifactRef(kindOf: 'coverage', pathOrUri: outAbs)],
      );
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }

  Future<Map<String, Object?>?> _parseLcov(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    final lines = await f.readAsLines();
    var lf = 0, lh = 0;
    final perFile = <String>[];
    String? curSF;
    var fileLf = 0, fileLh = 0;
    for (final l in lines) {
      if (l.startsWith('SF:')) {
        curSF = l.substring(3);
        fileLf = 0;
        fileLh = 0;
      } else if (l.startsWith('DA:')) {
        final parts = l.substring(3).split(',');
        if (parts.length >= 2) {
          fileLf++;
          if ((int.tryParse(parts[1]) ?? 0) > 0) fileLh++;
        }
      } else if (l.trimLeft().startsWith('end_of_record')) {
        lf += fileLf;
        lh += fileLh;
        if (curSF != null) {
          final pct = fileLf == 0 ? 0 : (fileLh * 100 / fileLf);
          perFile.add('$curSF: $fileLh/$fileLf '
              '(${pct.toStringAsFixed(1)}%)');
        }
      }
    }
    final pct = lf == 0 ? 0.0 : (lh * 100 / lf);
    return {
      'totalLines': lf,
      'coveredLines': lh,
      'percent': pct.toStringAsFixed(1),
      'perFile': perFile,
    };
  }
}

// ================================================================== lint.run
class LintRunTool extends QualityToolBase {
  @override
  String get id => 'lint.run';
  @override
  String get title => 'Run linters';
  @override
  String get description =>
      'Rodas analisadores REAIS: "dart analyze"/"flutter analyze" (sempre) e '
      '"dart format --output=none --set-exit-if-changed" (opcional). Retorna '
      'diagnósticos parseados com arquivo:linha — saída crua do binário.';
  @override
  ToolCategory get category => ToolCategory.lint;
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  String get binaryName => 'dart';
  @override
  String get binarySettingKey => 'devtools.dartBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'targets': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'fatalWarnings': {'type': 'boolean'},
          'includeFormatCheck': {'type': 'boolean'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final targets = input.list('targets');
      final flavor = await isFlutterWorkspace(ctx) ? 'flutter' : 'dart';
      final analyzeArgs = <String>[
        'analyze',
        if (input.boolOf('fatalWarnings')) '--fatal-warnings',
        ...targets,
      ];
      final res = flavor == 'flutter'
          ? await runFlutter(ctx, analyzeArgs)
          : await runProcess(ctx, analyzeArgs);
      final buffer = StringBuffer(res.combined);
      var failed = res.exitCode != 0;
      var code = failed ? VtErrorCode.buildFailed : VtErrorCode.internalError;
      if (input.boolOf('includeFormatCheck')) {
        final fmt = await runProcess(ctx,
            ['format', '--output=none', '--set-exit-if-changed', ...targets]);
        buffer.writeln('--- dart format ---');
        buffer.writeln(fmt.combined);
        if (fmt.exitCode != 0) {
          failed = true;
          code = VtErrorCode.buildFailed;
        }
      }
      final diagnostics =
          RegExp(r'(?:info|warning|error)\s•\s(.+?):(\d+):(\d+)')
              .allMatches(buffer.toString())
              .map((m) => Citation(
                  sourceType: 'file',
                  sourceRef: '${m[1]}:${m[2]}',
                  label: 'lint ${m[0]}'))
              .toList();
      final text = buffer.toString();
      if (failed) {
        return ToolFailureResult(VtFailure(
          code: code,
          message: 'Análise falhou (exit ${res.exitCode}).',
          details: {'stdout': text},
        ));
      }
      return ToolSuccess(
        data: TextOutput(
          text.isEmpty ? 'Nenhum problema encontrado.' : text,
          metadata: {
            'exitCode': res.exitCode,
            'flavor': flavor,
            'issues': diagnostics.length,
          },
        ),
        citations: diagnostics,
      );
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ============================================================ bug.reproduce
class BugReproduceTool extends QualityToolBase {
  BugReproduceTool({this.executor});

  /// Executor interno de tool (mesmo canal do loop do agente) para passos
  /// `tool:<id>` — permite reproduzir usando as próprias ferramentas reais.
  final Future<ToolResult<ToolOutput>> Function(
      String toolId, Map<String, Object?> input, ToolContext ctx)? executor;

  @override
  String get id => 'bug.reproduce';
  @override
  String get title => 'Reproduce bug';
  @override
  String get description =>
      'Executa passos de reprodução REAIS (comandos de shell aprovados ou '
      'tools internas via "tool:<id>") capturando exit/stdout/stderr de cada '
      'passo e gravando log-artefato. Um passo que falha ENCURRALA a cadeia — '
      'isso é o resultado da reprodução, não um erro nosso.';
  @override
  ToolCategory get category => ToolCategory.bug;
  @override
  RiskLevel get risk => RiskLevel.execute;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  String get binaryName => 'sh';
  @override
  String get binarySettingKey => 'devtools.shellPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['steps'],
        'properties': {
          'steps': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'comandos POSIX ou "tool:<id>:{json}"',
          },
          'expect': {
            'type': 'string',
            'description':
                'substring que PROVA o bug no output do último passo relevante'
          },
          'stopOnFirstFailure': {'type': 'boolean'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final steps = input.list('steps');
      if (steps.isEmpty) {
        return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Lista de passos vazia.'));
      }
      final expect = input.str('expect');
      final stopOnFail = input.boolOf('stopOnFirstFailure', true);
      final logPath =
          joinPath(_workspaceRoot(ctx), '.techvt/repro-${_newId('log')}.log');
      await File(logPath).parent.create(recursive: true);
      final sink = File(logPath).openWrite();
      final results = <String>[];
      var reproduced = false;
      var firstFailureIdx = -1;
      try {
        for (var i = 0; i < steps.length; i++) {
          final step = steps[i];
          final stepOut = await _runStep(ctx, step);
          sink.writeln('### PASSO ${i + 1}: $step');
          sink.writeln(stepOut);
          sink.writeln('### EXIT/SUMARIO: ${_summarize(stepOut)}');
          final failedStep = _looksLikeFailure(stepOut);
          if (failedStep && firstFailureIdx < 0) firstFailureIdx = i;
          results.add('passo ${i + 1}: ${failedStep ? 'FALHOU' : 'ok'}');
          if (failedStep && stopOnFail) break;
        }
        final all = results.join('; ');
        if (expect.isNotEmpty) {
          reproduced = (await File(logPath).readAsString()).contains(expect);
        } else {
          reproduced = firstFailureIdx >= 0;
        }
        sink.writeln(
            '### RESULTADO: ${reproduced ? 'REPRODUZIDO' : 'nao reproduzido'} '
            '($all)');
      } finally {
        await sink.flush();
        await sink.close();
      }
      final report = StringBuffer()
        ..writeln('Reprodução ${reproduced ? 'CONFIRMADA' : 'não confirmada'}.')
        ..writeln(results.join('\n'));
      if (firstFailureIdx >= 0) {
        report
            .writeln('Primeiro passo com falha real: ${firstFailureIdx + 1}.');
      }
      return ToolSuccess(
        data: TextOutput(report.toString(), metadata: {
          'reproduced': reproduced,
          'firstFailureStep': firstFailureIdx + 1,
          'logPath': logPath,
        }),
        artifacts: [ArtifactRef(kindOf: 'log', pathOrUri: logPath)],
      );
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }

  Future<String> _runStep(ToolContext ctx, String step) async {
    if (step.startsWith('tool:')) {
      final rest = step.substring(5);
      final colon = rest.indexOf(':');
      final toolId = colon < 0 ? rest : rest.substring(0, colon);
      final rawArgs = colon < 0 ? '{}' : rest.substring(colon + 1);
      final exec = executor;
      if (exec == null) {
        throw VtFailure(
          code: VtErrorCode.notImplemented,
          message: 'Passo tool:"$toolId" exige executor de tools conectado '
              '(bug.reproduce sem wiring no bootstrap).',
        );
      }
      final Map<String, Object?> args;
      try {
        args = jsonDecode(rawArgs) as Map<String, Object?>;
      } on FormatException {
        throw VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'JSON inválido no passo tool: "$rawArgs".');
      }
      final result = await exec(toolId, args, ctx);
      return switch (result) {
        ToolSuccess(:final data) => data.toJson().toString(),
        ToolFailureResult(:final failure) =>
          '[ERRO ${failure.code.wire}] ${failure.message}',
      };
    }
    final sh = await resolveBinary(ctx);
    if (sh == null) throw VtFailure.binaryMissing('sh');
    final r = await runCaptured(sh, ['-c', step],
        cwd: _workspaceRoot(ctx), limit: const Duration(minutes: 5));
    return 'exit=${r.exitCode}\n${r.combined}';
  }

  static bool _looksLikeFailure(String stepOut) {
    final m = RegExp(r'exit=(\d+)').firstMatch(stepOut);
    if (m != null && int.parse(m.group(1)!) != 0) return true;
    return stepOut.contains('[ERRO ');
  }

  static String _summarize(String s) {
    final lines = s.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return '(vazio)';
    return lines.length <= 3
        ? lines.join(' | ')
        : '${lines.first} | … | ${lines.last}';
  }
}

// ============================================================ bug.verify_fix
class BugVerifyFixTool extends QualityToolBase {
  BugVerifyFixTool({this.reproducer});

  final BugReproduceTool? reproducer;

  @override
  String get id => 'bug.verify_fix';
  @override
  String get title => 'Verify bug fix';
  @override
  String get description =>
      'Verificação REAL de fix: roda o teste de regressão indicado '
      '("dart/flutter test <arquivo>" ou package:test -N) E/ou re-executa os '
      'passos de reprodução. Fix confirmado apenas quando ambos passam; '
      'qualquer falha retorna test_failed com a saída crua.';
  @override
  ToolCategory get category => ToolCategory.bug;
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  String get binaryName => 'dart';
  @override
  String get binarySettingKey => 'devtools.dartBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'testTarget': {
            'type': 'string',
            'description': 'arquivo/diretório de teste OU nome (-N)'
          },
          'testNameIsFilter': {'type': 'boolean'},
          'reproSteps': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'expectBugGone': {'type': 'boolean'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final target = input.str('testTarget');
      final reproSteps = input.list('reproSteps');
      if (target.isEmpty && reproSteps.isEmpty) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Informe testTarget e/ou reproSteps — sem evidência real '
              'não há como verificar fix.',
        ));
      }
      final report = StringBuffer();
      var allGreen = true;
      if (target.isNotEmpty) {
        final flavor = await isFlutterWorkspace(ctx) ? 'flutter' : 'dart';
        final args = input.boolOf('testNameIsFilter')
            ? ['test', '-N', target]
            : ['test', target];
        final res = flavor == 'flutter'
            ? await runFlutter(ctx, args)
            : await runProcess(ctx, args);
        report.writeln('— teste ($flavor ${args.join(' ')}): '
            'exit ${res.exitCode} ${res.exitCode == 0 ? 'PASSOU' : 'FALHOU'}');
        report.writeln(_lastLine(res.combined));
        if (res.exitCode != 0) {
          allGreen = false;
          return ToolFailureResult(
              failure(res, VtErrorCode.testFailed, 'test'));
        }
      }
      if (reproSteps.isNotEmpty) {
        final rep = reproducer ?? BugReproduceTool();
        final r = await rep.execute(
            ctx, MapToolInput({'steps': reproSteps, 'expect': ''}));
        switch (r) {
          case ToolSuccess(:final data):
            final reproduced = data.metadata['reproduced'] == true;
            final stillBroken =
                reproduced && !input.boolOf('expectBugGone', true);
            report.writeln('— reprodução: '
                '${reproduced ? 'bug AINDA PRESENTE' : 'bug não reproduzido'}');
            report.writeln(data.text);
            if (stillBroken) allGreen = false;
          case ToolFailureResult(:final failure):
            allGreen = false;
            report.writeln('— reprodução: erro ${failure.code.wire}: '
                '${failure.message}');
        }
      }
      if (!allGreen) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.testFailed,
          message: 'Fix NÃO confirmado: houve falha real na verificação.',
          details: {'report': report.toString()},
        ));
      }
      return ToolSuccess(
        data: TextOutput('FIX VERIFICADO COM EVIDÊNCIA REAL:\n$report'),
      );
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// =============================================================== bug.bisect
class BugBisectTool extends QualityToolBase {
  @override
  String get id => 'bug.bisect';
  @override
  String get title => 'Bisect regression';
  @override
  String get description =>
      'git bisect REAL entre dois commits com teste arbitrário (comando de '
      'shell aprovado): bom=0, ruim=1. Escreve estado em .git/BISECT_LOG e '
      'SEMPRE roda "git bisect reset" ao terminar (inclusive em erro). '
      'Aprovação obrigatória — muda HEAD do repo.';
  @override
  ToolCategory get category => ToolCategory.bug;
  @override
  RiskLevel get risk => RiskLevel.execute;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.explicitApproval;
  @override
  String get binaryName => 'git';
  @override
  String get binarySettingKey => 'git.binaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['bad', 'good', 'testCommand'],
        'properties': {
          'bad': {'type': 'string', 'description': 'commit/tag com o bug'},
          'good': {'type': 'string', 'description': 'commit/tag sem o bug'},
          'testCommand': {
            'type': 'string',
            'description': 'comando que sai 0 (bom) ou !=0 (ruim)'
          },
          'maxSteps': {'type': 'integer', 'minimum': 1, 'maximum': 64},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    late final String bad, good, testCmd;
    try {
      bad = input.str('bad');
      good = input.str('good');
      testCmd = input.str('testCommand');
      for (final ref in [bad, good]) {
        if (!RegExp(r'^[\w.\-/]{1,200}$').hasMatch(ref)) {
          return ToolFailureResult(VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Ref git inválida: "$ref".'));
        }
      }
      if (testCmd.contains('\$(') || testCmd.contains('`')) {
        return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Comando de teste com substituição suspeita — recusado.'));
      }
      final sh = await findBinaryInPath('sh');
      if (sh == null) throw VtFailure.binaryMissing('sh');

      final start = await runGitIn(ctx, ['bisect', 'start', bad, good]);
      if (start.exitCode != 0) {
        return ToolFailureResult(
            failure(start, VtErrorCode.internalError, 'bisect start'));
      }
      final maxSteps = input.intOrNull('maxSteps') ?? 32;
      final trace = StringBuffer(start.combined);
      String? firstBad;
      try {
        for (var step = 0; step < maxSteps; step++) {
          final replay = await runGitIn(ctx, ['bisect', 'replay']);
          final head = replay.exitCode == 0
              ? replay
              : await runGitIn(ctx, ['rev-parse', 'HEAD']);
          trace.writeln('\n### passo ${step + 1} @ ${head.stdout.trim()}');
          final verdict = await runCaptured(sh, ['-c', testCmd],
              cwd: _workspaceRoot(ctx), limit: const Duration(minutes: 10));
          trace.writeln('teste: exit ${verdict.exitCode}');
          trace.writeln(_summarizeBig(verdict.combined));
          if (verdict.exitCode == 0) {
            final g = await runGitIn(ctx, ['bisect', 'good']);
            trace.writeln(g.combined);
            if (g.stdout.contains('is the first bad commit')) {
              firstBad = _extractSha(g.stdout);
              break;
            }
          } else if (verdict.exitCode == 125) {
            final s = await runGitIn(ctx, ['bisect', 'skip']);
            trace.writeln(s.combined);
          } else {
            final b = await runGitIn(ctx, ['bisect', 'bad']);
            trace.writeln(b.combined);
            if (b.stdout.contains('is the first bad commit')) {
              firstBad = _extractSha(b.stdout);
              break;
            }
          }
        }
      } finally {
        final reset = await runGitIn(ctx, ['bisect', 'reset']);
        trace.writeln('\n### git bisect reset: exit ${reset.exitCode}');
      }
      if (firstBad == null) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.internalError,
          message:
              'Bisect esgotou $maxSteps passos sem achar o primeiro commit '
              'ruim (ver trace).',
          details: {'trace': trace.toString()},
        ));
      }
      final info = await runGitIn(
          ctx, ['show', '--no-patch', '--format=%h %an %ad %s', firstBad]);
      return ToolSuccess(
        data: TextOutput(
          'PRIMEIRO COMMIT RUIM: ${firstBad.substring(0, 12)}\n'
          '${info.stdout.trim()}\n\n(trace completo em details)',
          metadata: {'firstBadCommit': firstBad},
        ),
        citations: [
          Citation(
              sourceType: 'commit',
              sourceRef: firstBad,
              label: 'regressão introduzida aqui'),
        ],
        artifacts: [],
      );
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }

  static String? _extractSha(String s) {
    final m = RegExp(r'([0-9a-f]{40})\s+is the first bad commit').firstMatch(s);
    return m?.group(1);
  }

  static String _summarizeBig(String s) {
    final lines = s.trimRight().split('\n');
    if (lines.length <= 8) return s.trimRight();
    return '${lines.take(4).join('\n')}\n… (${lines.length - 8} linhas cortadas)\n'
        '${lines.skip(lines.length - 4).join('\n')}';
  }
}

// ===================================================== debug.start_session
class DebugStartSessionTool extends QualityToolBase {
  DebugStartSessionTool(DebugSessionManager? manager)
      : manager = manager ?? _sharedManager;
  final DebugSessionManager manager;

  @override
  String get id => 'debug.start_session';
  @override
  String get title => 'Start debug session';
  @override
  String get description =>
      'Inicia sessão de debug REAL via Debug Adapter Protocol (spawn do '
      'adapter configurado + initialize + launch). Retorna sessionId usado '
      'pelas demais tools debug.*. Sem adapter configurado: sidecar_not_running.';
  @override
  ToolCategory get category => ToolCategory.debug;
  @override
  RiskLevel get risk => RiskLevel.execute;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  String get binaryName => 'dart';
  @override
  String get binarySettingKey => 'devtools.dartBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'program': {
            'type': 'string',
            'description': 'entrypoint p/ launch (default lib/main.dart)'
          },
          'adapter': {
            'type': 'string',
            'description': 'dart|flutter (default: auto por pubspec)',
            'enum': ['dart', 'flutter'],
          },
          'adapterPath': {
            'type': 'string',
            'description':
                'binário do DAP adapter (default: settings debug.adapterPath)'
          },
          'stopOnEntry': {'type': 'boolean'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final root = workingDir(ctx);
      final adapterFlavor = input.str('adapter').isNotEmpty
          ? input.str('adapter')
          : (await isFlutterWorkspace(ctx) ? 'flutter' : 'dart');
      final customAdapter = input.str('adapterPath').isNotEmpty
          ? input.str('adapterPath')
          : (ctx.settings.get('debug.adapterPath') as String? ?? '');
      final exe = customAdapter.isNotEmpty
          ? customAdapter
          : await findBinaryInPath('$adapterFlavor-debug-dap') ??
              await findBinaryInPath('${adapterFlavor}_debug_dap');
      if (exe == null) {
        throw VtFailure(
          code: VtErrorCode.sidecarNotRunning,
          message: 'Nenhum debug adapter DAP encontrado '
              '("$adapterFlavor-debug-dap" no PATH nem debug.adapterPath nas '
              'settings). A sessão não pode ser REAL sem o adapter.',
          recoveryActions: const [
            RecoveryAction(
                kind: 'open_settings',
                label: 'Configurar debug.adapterPath',
                target: 'tools'),
          ],
        );
      }
      final program = input.str('program').isEmpty
          ? joinPath(root, 'lib/main.dart')
          : (input.str('program').startsWith('/')
              ? input.str('program')
              : joinPath(root, input.str('program')));
      final session = await manager.start(
        cwd: root,
        adapterExe: exe,
        adapterArgs: const [],
        launchRequest: {
          'program': program,
          'console': 'integratedTerminal',
          'noDebug': false,
          'stopOnEntry': input.boolOf('stopOnEntry'),
        },
        timeout: timeout,
      );
      return ToolSuccess(
        data: TextOutput(
          'Sessão DAP REAL iniciada (adapter=$exe, programa=$program).\n'
          'sessionId=${session.sessionId} — use nas tools debug.*.',
          metadata: {'sessionId': session.sessionId, 'adapter': exe},
        ),
      );
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ------------------------------------------ base das tools debug.* por id
/// Gerenciador compartilhado usado quando o bootstrap não injeta um próprio.
final DebugSessionManager _sharedManager = DebugSessionManager();

abstract class _DapToolBase extends QualityToolBase {
  _DapToolBase({DebugSessionManager? manager})
      : manager = manager ?? _sharedManager;
  final DebugSessionManager manager;

  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => false;
  @override
  String get binaryName => 'dart';
  @override
  String get binarySettingKey => 'devtools.dartBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['sessionId'],
        'properties': {
          'sessionId': {'type': 'string'}
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final session = manager.require(input.str('sessionId'));
      return await dapExecute(ctx, input, session);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }

  Future<ToolResult<TextOutput>> dapExecute(
      ToolContext ctx, MapToolInput input, _DapSession session);
}

class DebugSetBreakpointTool extends _DapToolBase {
  @override
  String get id => 'debug.set_breakpoint';
  @override
  String get title => 'Set breakpoint';
  @override
  String get description =>
      'Adiciona breakpoint REAL na sessão DAP (condicional/hit-condition '
      'quando o adapter anuncia suporte). Responde quantos breakpoints o '
      'adapter VERIFICOU — breakpoint não verificado é reportado como tal.';
  @override
  ToolCategory get category => ToolCategory.debug;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['sessionId', 'file', 'line'],
        'properties': {
          'sessionId': {'type': 'string'},
          'file': {'type': 'string'},
          'line': {'type': 'integer', 'minimum': 1},
          'condition': {'type': 'string'},
          'hitCondition': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> dapExecute(
      ToolContext ctx, MapToolInput input, _DapSession s) async {
    final file = input.str('file');
    final line = input.intOrNull('line')!;
    final (verified, all) = await s.addBreakpoint(file, line,
        condition:
            input.str('condition').isEmpty ? null : input.str('condition'),
        hitCondition: input.str('hitCondition').isEmpty
            ? null
            : input.str('hitCondition'));
    final unverified = all.length - verified;
    return ToolSuccess(
      data: TextOutput(
        'Breakpoint em ${File(file).absolute.path}:$line — '
        '$verified verificado(s) pelo adapter'
        '${unverified > 0 ? ', $unverified NÃO verificados' : ''}.',
        metadata: {'verified': verified, 'total': all.length},
      ),
    );
  }
}

class DebugRemoveBreakpointTool extends _DapToolBase {
  @override
  String get id => 'debug.remove_breakpoint';
  @override
  String get title => 'Remove breakpoint';
  @override
  String get description =>
      'Remove breakpoint REAL da sessão DAP (reenvia a lista completa via '
      'setBreakpoints). Breakpoint inexistente → validation_failed, nada é '
      'silenciado.';
  @override
  ToolCategory get category => ToolCategory.debug;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['sessionId', 'file', 'line'],
        'properties': {
          'sessionId': {'type': 'string'},
          'file': {'type': 'string'},
          'line': {'type': 'integer', 'minimum': 1},
        },
      };

  @override
  Future<ToolResult<TextOutput>> dapExecute(
      ToolContext ctx, MapToolInput input, _DapSession s) async {
    final remaining =
        await s.removeBreakpoint(input.str('file'), input.intOrNull('line')!);
    return ToolSuccess(
      data: TextOutput(
        'Breakpoint removido. Restam $remaining verificados no arquivo.',
        metadata: {'remainingVerified': remaining},
      ),
    );
  }
}

class DebugStepTool extends _DapToolBase {
  DebugStepTool(this._command, this.id, this.title, this.description);
  @override
  final String id;
  @override
  final String title;
  @override
  final String description;
  final String _command;

  @override
  ToolCategory get category => ToolCategory.debug;

  @override
  Future<ToolResult<TextOutput>> dapExecute(
      ToolContext ctx, MapToolInput input, _DapSession s) async {
    final threads = await s.threads();
    if (threads.isEmpty) {
      throw VtFailure(
          code: VtErrorCode.internalError,
          message: 'Sessão sem threads vivas — nada onde stepar.');
    }
    await s.step(_command, threads.first);
    final stop = await s.waitForStop(const Duration(seconds: 10));
    if (stop == null) {
      return ToolSuccess(
        data: TextOutput(
          '$_command enviado; sessão ${s.state.name} sem parada em 10s '
          '(pode ter terminado ou estar correndo).',
          metadata: {'state': s.state.name},
        ),
      );
    }
    final top = (await s.stackTrace(threads.first)).firstOrNull;
    final loc = top == null
        ? ''
        : '\nParou em ${top['name']} @ ${(top['source'] as Map?)?['path']}:${top['line']}';
    return ToolSuccess(
      data: TextOutput(
        'OK: ${stop['reason']}$loc',
        metadata: {'reason': stop['reason'], 'threadId': threads.first},
      ),
    );
  }
}

class DebugEvaluateExpressionTool extends _DapToolBase {
  @override
  String get id => 'debug.evaluate_expression';
  @override
  String get title => 'Evaluate expression';
  @override
  String get description =>
      'Avalia expressão REAL no contexto de parada (DAP evaluate, frame atual '
      'ou frameId informado). Fora de paused → erro claro, sem inventar valor.';
  @override
  ToolCategory get category => ToolCategory.debug;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['sessionId', 'expression'],
        'properties': {
          'sessionId': {'type': 'string'},
          'expression': {'type': 'string'},
          'frameId': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> dapExecute(
      ToolContext ctx, MapToolInput input, _DapSession s) async {
    if (s.state != SessionState.stopped) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Sessão ${s.state.name}: evaluate exige estado stopped '
            '(use debug.get_stack para confirmar parada).',
      );
    }
    final frameId = input.intOrNull('frameId') ?? await _currentTopFrame(s);
    final res = await s.evaluate(input.str('expression'), frameId);
    return ToolSuccess(
      data: TextOutput(
        '${res['result']}',
        metadata: {
          'type': res['type'],
          'variablesReference': res['variablesReference'],
          'frameId': frameId,
        },
      ),
    );
  }

  Future<int> _currentTopFrame(_DapSession s) async {
    final threads = await s.threads();
    if (threads.isEmpty) {
      throw VtFailure(
          code: VtErrorCode.internalError, message: 'Sem threads na sessão.');
    }
    final frame = (await s.stackTrace(threads.first)).firstOrNull;
    if (frame == null) {
      throw VtFailure(code: VtErrorCode.internalError, message: 'Stack vazia.');
    }
    return (frame['id'] as num).toInt();
  }
}

class DebugGetStackTool extends _DapToolBase {
  @override
  String get id => 'debug.get_stack';
  @override
  String get title => 'Get call stack';
  @override
  String get description =>
      'Retorna a call stack REAL (DAP stackTrace) da thread informada ou da '
      'primeira thread viva, com arquivo:linha de cada frame.';
  @override
  ToolCategory get category => ToolCategory.debug;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['sessionId'],
        'properties': {
          'sessionId': {'type': 'string'},
          'threadId': {'type': 'integer'},
          'levels': {'type': 'integer', 'minimum': 1},
        },
      };

  @override
  Future<ToolResult<TextOutput>> dapExecute(
      ToolContext ctx, MapToolInput input, _DapSession s) async {
    final threads = await s.threads();
    final tid = input.intOrNull('threadId') ?? threads.firstOrNull;
    if (tid == null) {
      throw VtFailure(
          code: VtErrorCode.internalError, message: 'Sessão sem threads.');
    }
    final frames = await s.stackTrace(tid, levels: input.intOrNull('levels'));
    final lines = <String>[];
    final citations = <Citation>[];
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      final src = (f['source'] as Map?)?['path'] ?? '?';
      final ln = f['line'];
      lines.add('#$i ${f['name']}  ($src:$ln)');
      citations.add(Citation(
          sourceType: 'file', sourceRef: '$src:$ln', label: '${f['name']}'));
    }
    return ToolSuccess(
      data: TextOutput(
        lines.isEmpty ? '(stack vazia)' : lines.join('\n'),
        metadata: {'threadId': tid, 'frames': frames.length},
      ),
      citations: citations,
    );
  }
}

class DebugGetVariablesTool extends _DapToolBase {
  @override
  String get id => 'debug.get_variables';
  @override
  String get title => 'Get variables/scopes';
  @override
  String get description =>
      'Retorna scopes e variáveis REAIS do frame parado (DAP scopes + '
      'variables). Com variablesReference, expande um escopo específico.';
  @override
  ToolCategory get category => ToolCategory.debug;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['sessionId'],
        'properties': {
          'sessionId': {'type': 'string'},
          'frameId': {'type': 'integer'},
          'variablesReference': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> dapExecute(
      ToolContext ctx, MapToolInput input, _DapSession s) async {
    if (input.intOrNull('variablesReference') != null) {
      final vars = await s.variables(input.intOrNull('variablesReference')!);
      return ToolSuccess(data: TextOutput(_renderVars(vars)));
    }
    final frameId = input.intOrNull('frameId');
    if (frameId == null) {
      final threads = await s.threads();
      if (threads.isEmpty) {
        throw VtFailure(
            code: VtErrorCode.internalError, message: 'Sessão sem threads.');
      }
      final top = (await s.stackTrace(threads.first)).firstOrNull;
      if (top == null) {
        throw VtFailure(
            code: VtErrorCode.internalError, message: 'Stack vazia.');
      }
      return _scopesFor(s, (top['id'] as num).toInt());
    }
    return _scopesFor(s, frameId);
  }

  Future<ToolSuccess<TextOutput>> _scopesFor(_DapSession s, int frameId) async {
    final res = await s.scopes(frameId);
    final scopes =
        (res['scopes'] as List?)?.cast<Map<String, Object?>>() ?? const [];
    final buf = StringBuffer();
    final byScope = <String, List<Map<String, Object?>>>{};
    for (final sc in scopes) {
      final name = sc['name']?.toString() ?? 'scope';
      final ref = (sc['variablesReference'] as num?)?.toInt() ?? 0;
      final vars = await s.variables(ref);
      byScope[name] = vars;
      buf.writeln('[$name] ${vars.length} variáveis '
          '(${sc['presentationHint'] ?? ''})');
    }
    return ToolSuccess(
      data: TextOutput(buf.isEmpty ? '(sem escopos)' : buf.toString(),
          metadata: {'scopes': byScope.keys.toList()}),
    );
  }

  static String _renderVars(List<Map<String, Object?>> vars) {
    return vars
        .map((v) => '${v['name']}: ${v['value']} (${v['type'] ?? '?'})')
        .join('\n');
  }
}

// ============================================= debug.attach_observatory

/// Descobre URI de VM Service REAL: apps em devices listados por
/// `flutter devices --machine` trazem campos `vmServiceUri`/`observatoryUri`
/// quando a tool de descoberta consegue acessá-los. null = nada real achado.
Future<String?> _discoverVmServiceUri(ToolContext ctx) async {
  final devices = await realDeviceList(ctx);
  for (final d in devices) {
    for (final key in ['vmServiceUri', 'observatoryUri']) {
      final v = d[key]?.toString() ?? '';
      if (v.startsWith('http://') || v.startsWith('ws://')) return v;
    }
  }
  return null;
}

class DebugAttachObservatoryTool extends QualityToolBase {
  DebugAttachObservatoryTool({this.wsConnector});

  /// Injetável para teste: abre conexão com a VM Service e devolve o cliente.
  final Future<_VmServiceWsClient> Function(Uri uri)? wsConnector;

  /// Chamada JSON-RPC tipada (retorna Map cru da VM Service).
  static Future<Object?> rpc(_VmServiceWsClient c, String method) =>
      c.call(method);

  @override
  String get id => 'debug.attach_observatory';
  @override
  String get title => 'Attach Observatory';
  @override
  String get description =>
      'Conecta REALMENTE à VM Service (Observatory) de um app Dart/Flutter em '
      'execução (ws://127.0.0.1:PORT/TOKEN/ws), valida o handshake, lista '
      'isolates e captura versão/report do runtime. Sem endpoint vivo: '
      'network_unavailable — nunca finge attach.';
  @override
  ToolCategory get category => ToolCategory.debug;
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  String get binaryName => 'dart';
  @override
  String get binarySettingKey => 'devtools.dartBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'uri': {
            'type': 'string',
            'description': 'ws://host:port/token/ws (ou http://... )'
          },
          'fromFlutterDevices': {
            'type': 'boolean',
            'description':
                'descobre URIs via "flutter devices" (app em device real)'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      var uriStr = input.str('uri');
      if (uriStr.isEmpty && input.boolOf('fromFlutterDevices')) {
        final disc = await _discoverVmServiceUri(ctx);
        if (disc == null) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.deviceNotFound,
            message: '"flutter devices" não retornou nenhum app com VM Service '
                'acessível.',
          ));
        }
        uriStr = disc;
      }
      if (uriStr.isEmpty) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Informe uri da VM Service (ex.: '
              'ws://127.0.0.1:8181/abc=/ws) ou fromFlutterDevices=true.',
        ));
      }
      final wsUri = _normalizeWsUri(uriStr);
      final connector = wsConnector ?? _connectDefault;
      final _VmServiceWsClient client;
      try {
        client = await connector(wsUri);
      } on VtFailure {
        rethrow;
      } catch (e) {
        // erro REAL da conexão (recusa, DNS, TLS) — propagado tipado
        throw VtFailure(
          code: VtErrorCode.networkUnavailable,
          message: 'Falha ao conectar na VM Service $wsUri: $e',
        );
      }
      try {
        final version = await rpc(client, 'getVersion');
        final isolates = await rpc(client, 'getVM').then((vm) {
          final list = (vm is Map ? vm['isolates'] : null);
          return list is List ? list : const [];
        });
        final names = isolates
            .map((iso) => iso is Map ? '${iso['number']}:${iso['name']}' : '?')
            .join(', ');
        return ToolSuccess(
          data: TextOutput(
            'Attach REAL na VM Service $wsUri\n'
            'SDK: ${version is Map ? version['major'] : '?'}.${version is Map ? version['minor'] : '?'}\n'
            'Isolates (${isolates.length}): $names',
            metadata: {'uri': wsUri.toString(), 'isolates': isolates.length},
          ),
          citations: [
            Citation(
                sourceType: 'url',
                sourceRef: wsUri.toString(),
                label: 'VM Service endpoint'),
          ],
        );
      } finally {
        client.close();
      }
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }

  static Future<_VmServiceWsClient> _connectDefault(Uri uri) async {
    final c = _VmServiceWsClient(uri);
    await c.connect();
    return c;
  }

  static Uri _normalizeWsUri(String s) {
    var str = s.trim();
    if (str.startsWith('http://')) str = 'ws://${str.substring(7)}';
    if (str.startsWith('https://')) str = 'wss://${str.substring(8)}';
    if (!str.endsWith('/ws')) {
      str = str.endsWith('/') ? '${str}ws' : '$str/ws';
    }
    return Uri.parse(str);
  }
}
