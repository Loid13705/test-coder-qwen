/// Implementação real de tools da cadeia de desenvolvimento (spec catálogo
/// §PUB / §FLUTTER / §CI / §RELEASE).
///
/// Todas executam binários reais (`dart`, `flutter`, `git`) via Process com
/// arrays de argumentos — sem shell interpolation e sem simulação:
/// - a saída é stdout/stderr cru do processo;
/// - exit code != 0 vira VtFailure tipado (build_failed/test_failed/...);
/// - binário ausente vira binary_missing com ação de recuperação;
/// - efeito colateral e política de aprovação vêm do contrato de cada tool.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import '../process/process_utils.dart';

typedef HttpClientFactory = HttpClient Function();

HttpClient _defaultHttpClient() =>
    HttpClient()..connectionTimeout = const Duration(seconds: 15);

/// Resultado bruto de um processo real.
class ProcResult {
  const ProcResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
  String get combined => stderr.isEmpty ? stdout : '$stdout\n[stderr]\n$stderr';
}

/// Executa [exe] com [args] em [cwd], captura pipes e respeita [limit]
/// matando o processo no timeout (kill REAL — não deixa zombie).
Future<ProcResult> runCaptured(
  String exe,
  List<String> args, {
  required String cwd,
  required Duration limit,
}) async {
  final Process proc;
  try {
    proc = await Process.start(exe, args, workingDirectory: cwd);
  } on ProcessException catch (e) {
    throw VtFailure(
      code: VtErrorCode.binaryMissing,
      message: 'Falha ao iniciar "$exe": ${e.message}',
    );
  }
  final outF =
      proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final errF =
      proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
  final exit = await proc.exitCode.timeout(limit, onTimeout: () {
    proc.kill(ProcessSignal.sigterm);
    throw VtFailure(
      code: VtErrorCode.timeout,
      message: '"$exe ${args.join(' ')}" excedeu ${limit.inSeconds}s; '
          'processo terminado com SIGTERM.',
    );
  });
  // dá tempo aos pipes de drenarem após o exit
  final out =
      await outF.timeout(const Duration(seconds: 5), onTimeout: () => '');
  final err =
      await errF.timeout(const Duration(seconds: 5), onTimeout: () => '');
  return ProcResult(exit, out, err);
}

/// Base comum das dev-tools: resolução de binário (settings → PATH), cwd =
/// raiz do workspace, execução com timeout real e mapeamento honesto de erros.
abstract class DevToolBase extends VtTool<MapToolInput, TextOutput> {
  /// Nome do binário no PATH (ex.: 'flutter').
  String get binaryName;

  /// Chave de setting para caminho customizado do binário.
  String get binarySettingKey;

  @override
  List<String> get capabilities => const ['devtools'];

  @override
  Duration get timeout => const Duration(minutes: 15);

  @override
  RetryPolicy get retryPolicy => const RetryPolicy();

  @override
  bool get isIdempotent => false;

  @override
  Map<String, Object?> get outputSchema => const {'type': 'object'};

  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  Future<String?> resolveBinary(ToolContext ctx) async {
    final custom = ctx.settings.get(binarySettingKey) as String?;
    if (custom != null && await File(custom).exists()) return custom;
    return findBinaryInPath(binaryName);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async {
    final b = await resolveBinary(ctx);
    return b == null ? HealthMissingBinary(binaryName) : const HealthOk();
  }

  /// Diretório de trabalho real: raiz do workspace (ou override em settings).
  String workingDir(ToolContext ctx) {
    final override = ctx.settings.get('devtools.cwd') as String?;
    if (override != null && override.isNotEmpty) return override;
    return ctx.workspaceRoots.first;
  }

  Future<ProcResult> runProcess(
    ToolContext ctx,
    List<String> args, {
    String? cwd,
    Duration? limit,
  }) async {
    final exe = await resolveBinary(ctx);
    if (exe == null) throw VtFailure.binaryMissing(binaryName);
    return runCaptured(exe, args,
        cwd: cwd ?? workingDir(ctx), limit: limit ?? timeout);
  }

  /// Roda o binário `flutter` (respeitando settings) independentemente do
  /// binário default da tool — usado pelas variants flutter:* dos comandos.
  Future<ProcResult> runFlutter(ToolContext ctx, List<String> args) async {
    final custom = ctx.settings.get('devtools.flutterBinaryPath') as String?;
    final exe = (custom != null && await File(custom).exists())
        ? custom
        : await findBinaryInPath('flutter');
    if (exe == null) throw VtFailure.binaryMissing('flutter');
    return runCaptured(exe, args,
        cwd: workingDir(ctx), limit: Duration(seconds: flutterTimeoutSeconds));
  }

  /// Timeout das chamadas flutter: herda o da tool (segundos).
  int get flutterTimeoutSeconds => timeout.inSeconds;

  /// Flutter real: pubspec menciona o SDK flutter E o binário existe.
  Future<bool> isFlutterWorkspace(ToolContext ctx) async {
    final pubspec = joinPath(workingDir(ctx), 'pubspec.yaml');
    try {
      if (await File(pubspec).exists()) {
        final content = await File(pubspec).readAsString();
        if (content.contains('sdk: flutter')) return true;
      }
    } on FileSystemException {
      // arquivo ilegível: trata como não-flutter e deixa o comando reclamar
    }
    return false;
  }

  /// Escolhe dart|flutter conforme o projeto; se flutter for exigido mas o
  /// binário faltar, degrada para dart com aviso na metadata (nunca falha por
  /// capricho — a flag `flutter:true` força erro real).
  Future<(ProcResult res, String flavor)> pubCommand(
    ToolContext ctx,
    List<String> afterPub, {
    bool forceFlutter = false,
  }) async {
    final flutterProject = await isFlutterWorkspace(ctx);
    if (forceFlutter || (flutterProject && await _flutterAvailable(ctx))) {
      if (forceFlutter && !await _flutterAvailable(ctx)) {
        throw VtFailure.binaryMissing('flutter',
            hint: 'comando pedido com flutter:true mas o binário não existe.');
      }
      final r = await runFlutter(ctx, ['pub', ...afterPub]);
      return (r, 'flutter');
    }
    final r = await runProcess(ctx, ['pub', ...afterPub]);
    return (r, 'dart');
  }

  Future<bool> _flutterAvailable(ToolContext ctx) async {
    final custom = ctx.settings.get('devtools.flutterBinaryPath') as String?;
    if (custom != null && await File(custom).exists()) return true;
    return await findBinaryInPath('flutter') != null;
  }

  ToolSuccess<TextOutput> ok(ProcResult r,
          {Map<String, Object?> extra = const {}}) =>
      ToolSuccess(
          data: TextOutput(r.combined,
              metadata: {'exitCode': r.exitCode, ...extra}));

  VtFailure failure(ProcResult r, VtErrorCode code, String verb) => VtFailure(
        code: code,
        message: '$binaryName $verb falhou (exit ${r.exitCode}).',
        details: {'exitCode': r.exitCode, 'stderr': r.stderr},
      );

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) {
    throw VtFailure(
        code: VtErrorCode.internalError, message: 'execute não sobrescrito');
  }
}

// ------------------------------------------------------------------ pub.get
class PubGetTool extends DevToolBase {
  @override
  String get id => 'pub.get';
  @override
  String get title => 'Pub get';
  @override
  String get description =>
      'Executa "dart pub get"/"flutter pub get" REAL no workspace (auto-detecta '
      'projeto Flutter pelo pubspec). Resolve dependências verdadeiras.';
  @override
  ToolCategory get category => ToolCategory.pub;
  @override
  RiskLevel get risk => RiskLevel.networkRead;
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
          'flutter': {
            'type': 'boolean',
            'description':
                'Força flutter pub get (default: auto-detectar). Se true e o '
                    'binário flutter estiver ausente, erro real.'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final (res, flavor) =
          await pubCommand(ctx, ['get'], forceFlutter: input.boolOf('flutter'));
      if (res.exitCode != 0) {
        return ToolFailureResult(
            failure(res, VtErrorCode.buildFailed, 'pub get'));
      }
      return ok(res, extra: {'flavor': flavor});
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ------------------------------------------------------------------ pub.add
class PubAddTool extends DevToolBase {
  @override
  String get id => 'pub.add';
  @override
  String get title => 'Pub add dependency';
  @override
  String get description =>
      'Adiciona dependência REAL via "dart/flutter pub add" (escreve '
      'pubspec.yaml + lockfile). Aprovação obrigatória: altera manifest + rede.';
  @override
  ToolCategory get category => ToolCategory.pub;
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  String get binaryName => 'dart';
  @override
  String get binarySettingKey => 'devtools.dartBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['package'],
        'properties': {
          'package': {
            'type': 'string',
            'description': 'Nome ou spec ("http:^1.2.0", "pkg:path=./x").'
          },
          'dev': {
            'type': 'boolean',
            'description': 'adicionar como dev_dependencies'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final pkg = input.str('package');
      if (!RegExp(r'^[\w.\-]+(:[^]*)?$').hasMatch(pkg)) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Spec de pacote inválida: "$pkg".',
        ));
      }
      final args = <String>[if (input.boolOf('dev')) '--dev', pkg];
      final (res, flavor) = await pubCommand(ctx, ['add', ...args]);
      if (res.exitCode != 0) {
        return ToolFailureResult(
            failure(res, VtErrorCode.buildFailed, 'pub add'));
      }
      return ok(res, extra: {
        'flavor': flavor,
        'modifiedFiles': [
          joinPath(workingDir(ctx), 'pubspec.yaml'),
          joinPath(workingDir(ctx), 'pubspec.lock'),
        ],
      });
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// -------------------------------------------------------------- pub.outdated
class PubOutdatedTool extends DevToolBase {
  @override
  String get id => 'pub.outdated';
  @override
  String get title => 'Pub outdated';
  @override
  String get description =>
      'Lista pacotes desatualizados REAIS ("pub outdated --output=json"; cai '
      'para texto cru se a versão local não suportar JSON). Somente leitura.';
  @override
  ToolCategory get category => ToolCategory.pub;
  @override
  RiskLevel get risk => RiskLevel.networkRead;
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
          'json': {
            'type': 'boolean',
            'description':
                'usa --output=json (default true; fallback texto real)'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final wantJson = input.values['json'] as bool? ?? true;
      var (res, flavor) =
          await pubCommand(ctx, ['outdated', if (wantJson) '--output=json']);
      // flags desconhecidas em pub antigo → degradamos p/ saída textual REAL
      if (wantJson &&
          res.exitCode != 0 &&
          !res.stdout.trimLeft().startsWith('{')) {
        (res, flavor) = await pubCommand(ctx, ['outdated']);
      }
      if (res.exitCode != 0) {
        return ToolFailureResult(
            failure(res, VtErrorCode.internalError, 'pub outdated'));
      }
      int? count;
      if (res.stdout.trimLeft().startsWith('{')) {
        try {
          final j = jsonDecode(res.stdout) as Map<String, Object?>;
          count = ((j['packages'] as List?) ?? const []).length;
        } on FormatException {
          count = null;
        }
      }
      return ok(res, extra: {
        'flavor': flavor,
        'format': count != null ? 'json' : 'text',
        if (count != null) 'count': count,
      });
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ------------------------------------------------------------ flutter.doctor
class FlutterDoctorTool extends DevToolBase {
  @override
  String get id => 'flutter.doctor';
  @override
  String get title => 'Flutter doctor';
  @override
  String get description =>
      'Executa "flutter doctor -v" REAL e retorna o diagnóstico cru do host.';
  @override
  ToolCategory get category => ToolCategory.flutter;
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  Duration get timeout => const Duration(minutes: 5);
  @override
  String get binaryName => 'flutter';
  @override
  String get binarySettingKey => 'devtools.flutterBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'machine': {'type': 'boolean', 'description': 'usa --machine (JSON)'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final machine = input.boolOf('machine');
      final res = await runFlutter(
          ctx, ['doctor', if (!machine) '-v', if (machine) '--machine']);
      if (res.exitCode != 0) {
        return ToolFailureResult(
            failure(res, VtErrorCode.internalError, 'doctor'));
      }
      return ok(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// -------------------------------------------------------------- flutter.devices
/// Lista devices REAIS parseando "flutter devices --machine" (que embrulha o
/// JSON em meio a linhas de log — extraímos o array entre colchetes).
Future<List<Map<String, Object?>>> realDeviceList(ToolContext ctx) async {
  final res = await FlutterDevicesHelper.instance.run(ctx);
  final trimmed = res.stdout.trim();
  final start = trimmed.indexOf('[');
  final end = trimmed.lastIndexOf(']');
  if (start < 0 || end <= start) return const [];
  final list = jsonDecode(trimmed.substring(start, end + 1)) as List;
  return list.cast<Map<String, Object?>>();
}

class FlutterDevicesHelper {
  static final FlutterDevicesHelper instance = FlutterDevicesHelper._();
  FlutterDevicesHelper._();

  Future<ProcResult> run(ToolContext ctx) async {
    final custom = ctx.settings.get('devtools.flutterBinaryPath') as String?;
    final exe = (custom != null && await File(custom).exists())
        ? custom
        : await findBinaryInPath('flutter');
    if (exe == null) throw VtFailure.binaryMissing('flutter');
    final root = ctx.workspaceRoots.isNotEmpty
        ? ctx.workspaceRoots.first
        : Directory.current.path;
    return runCaptured(exe, const ['devices', '--machine'],
        cwd: root, limit: const Duration(minutes: 2));
  }
}

// ---------------------------------------------------------------- flutter.run
class FlutterRunTool extends DevToolBase {
  FlutterRunTool({this.onSessionStarted});

  /// Hook de integração: recebe o [Process] real já iniciado (a UI pode
  /// anexar stream de logs e botão stop). Opcional.
  final void Function(Process process, String deviceId)? onSessionStarted;

  @override
  String get id => 'flutter.run';
  @override
  String get title => 'Flutter run';
  @override
  String get description =>
      'Roda "flutter run -d <device>" no workspace. Valida o device contra '
      '"flutter devices" ANTES de iniciar; device inexistente → device_not_found '
      'com a lista real disponível.';
  @override
  ToolCategory get category => ToolCategory.flutter;
  @override
  RiskLevel get risk => RiskLevel.execute;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  String get binaryName => 'flutter';
  @override
  String get binarySettingKey => 'devtools.flutterBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['deviceId'],
        'properties': {
          'deviceId': {'type': 'string'},
          'target': {'type': 'string', 'description': 'ex.: lib/main.dart'},
          'dartDefine': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'timeoutSeconds': {
            'type': 'integer',
            'description': 'duração máxima da sessão (default 300s; kill real).'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    Process? proc;
    try {
      final deviceId = input.str('deviceId');
      final devices = await realDeviceList(ctx);
      final realIds = devices
          .map((d) => d['id']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      if (!realIds.contains(deviceId)) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.deviceNotFound,
          message: 'Dispositivo/emulador "$deviceId" não encontrado. Reais '
              'disponíveis agora: '
              '${realIds.isEmpty ? 'nenhum' : realIds.join(', ')}',
          recoveryActions: const [
            RecoveryAction(
                kind: 'list_devices', label: 'Rodar flutter devices'),
          ],
        ));
      }
      final exe = await resolveBinary(ctx);
      if (exe == null) throw VtFailure.binaryMissing('flutter');
      final args = <String>['run', '-d', deviceId];
      if (input.str('target').isNotEmpty) args.add(input.str('target'));
      for (final d in input.list('dartDefine')) {
        args.addAll(['--dart-define', d]);
      }
      proc = await Process.start(exe, args, workingDirectory: workingDir(ctx));
      onSessionStarted?.call(proc, deviceId);
      final outF =
          proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
      final errF =
          proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
      final secs = input.intOrNull('timeoutSeconds') ?? 300;
      var killedByTimeout = false;
      final exit =
          await proc.exitCode.timeout(Duration(seconds: secs), onTimeout: () {
        proc!.kill(ProcessSignal.sigterm);
        killedByTimeout = true;
        return 0;
      });
      final out =
          await outF.timeout(const Duration(seconds: 10), onTimeout: () => '');
      final err =
          await errF.timeout(const Duration(seconds: 10), onTimeout: () => '');
      final res = ProcResult(exit, out, err);
      if (!killedByTimeout && exit != 0) {
        return ToolFailureResult(failure(res, VtErrorCode.buildFailed, 'run'));
      }
      return ok(res, extra: {
        'deviceId': deviceId,
        'sessionEnded': killedByTimeout ? 'timeout_kill' : 'app_exit',
        if (!killedByTimeout) 'appExitCode': exit,
      });
    } on ProcessException catch (e) {
      return ToolFailureResult(VtFailure(
          code: VtErrorCode.binaryMissing,
          message: 'Falha ao iniciar "flutter": ${e.message}'));
    } on VtFailure catch (f) {
      proc?.kill(ProcessSignal.sigterm);
      return ToolFailureResult(f);
    }
  }
}

// -------------------------------------------------------- flutter.build_apk
class FlutterBuildApkTool extends DevToolBase {
  @override
  String get id => 'flutter.build_apk';
  @override
  String get title => 'Flutter build apk';
  @override
  String get description =>
      'Build Android APK REAL ("flutter build apk --release|debug|profile"). '
      'Artefato aponta para o .apk verificado no disco.';
  @override
  ToolCategory get category => ToolCategory.flutter;
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  Duration get timeout => const Duration(minutes: 30);
  @override
  String get binaryName => 'flutter';
  @override
  String get binarySettingKey => 'devtools.flutterBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'debug': {'type': 'boolean'},
          'profile': {'type': 'boolean'},
          'splitPerAbi': {'type': 'boolean'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final mode = input.boolOf('debug')
          ? 'debug'
          : input.boolOf('profile')
              ? 'profile'
              : 'release';
      final args = <String>['build', 'apk', '--$mode'];
      if (input.boolOf('splitPerAbi')) args.add('--split-per-abi');
      final res = await runFlutter(ctx, args);
      if (res.exitCode != 0) {
        return ToolFailureResult(
            failure(res, VtErrorCode.buildFailed, 'build apk'));
      }
      final apk = joinPath(
          workingDir(ctx), 'build/app/outputs/flutter-apk/app-$mode.apk');
      final exists = await File(apk).exists();
      return ok(res, extra: {
        'artifact': apk,
        'artifactExists': exists,
        if (exists) 'sizeBytes': await File(apk).length(),
      });
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// -------------------------------------------------------- flutter.build_web
class FlutterBuildWebTool extends DevToolBase {
  @override
  String get id => 'flutter.build_web';
  @override
  String get title => 'Flutter build web';
  @override
  String get description =>
      'Build web REAL ("flutter build web"). Artefato: build/web/index.html '
      'verificado no disco.';
  @override
  ToolCategory get category => ToolCategory.flutter;
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  Duration get timeout => const Duration(minutes: 30);
  @override
  String get binaryName => 'flutter';
  @override
  String get binarySettingKey => 'devtools.flutterBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'renderer': {
            'type': 'string',
            'description': 'auto|html-web|canvaskit|skwasm'
          },
          'baseHref': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final args = <String>['build', 'web'];
      final renderer = input.str('renderer');
      if (renderer.isNotEmpty) args.addAll(['--web-renderer', renderer]);
      final href = input.str('baseHref');
      if (href.isNotEmpty) args.addAll(['--base-href', href]);
      final res = await runFlutter(ctx, args);
      if (res.exitCode != 0) {
        return ToolFailureResult(
            failure(res, VtErrorCode.buildFailed, 'build web'));
      }
      final index = joinPath(workingDir(ctx), 'build/web/index.html');
      final exists = await File(index).exists();
      return ok(res, extra: {'artifact': index, 'artifactExists': exists});
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ---------------------------------------------------------------- flutter.test
class FlutterTestTool extends DevToolBase {
  @override
  String get id => 'flutter.test';
  @override
  String get title => 'Flutter test';
  @override
  String get description =>
      'Roda testes Flutter REAIS ("flutter test"). Exit != 0 vira test_failed '
      'com stdout/stderr crus na failure — nunca output fake.';
  @override
  ToolCategory get category => ToolCategory.test;
  @override
  RiskLevel get risk => RiskLevel.execute;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  Duration get timeout => const Duration(minutes: 20);
  @override
  String get binaryName => 'flutter';
  @override
  String get binarySettingKey => 'devtools.flutterBinaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'paths': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'arquivos/dirs específicos (default: tudo)',
          },
          'name': {'type': 'string', 'description': 'filtro -n regex'},
          'expanded': {'type': 'boolean', 'description': '--reporter=expanded'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final args = <String>['test'];
      if (input.boolOf('expanded')) args.add('--reporter=expanded');
      final name = input.str('name');
      if (name.isNotEmpty) args.addAll(['-n', name]);
      args.addAll(input.list('paths'));
      final res = await runFlutter(ctx, args);
      if (res.exitCode != 0) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.testFailed,
          message: 'flutter test falhou (exit ${res.exitCode}).',
          details: {
            'exitCode': res.exitCode,
            'stdout': res.stdout,
            'stderr': res.stderr
          },
          recoveryActions: const [
            RecoveryAction(
                kind: 'rerun_failed', label: 'Re-rodar apenas os falhos'),
          ],
        ));
      }
      return ok(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ----------------------------------------------------- ci.pipeline_trigger
class CiPipelineTriggerTool extends DevToolBase {
  CiPipelineTriggerTool({HttpClientFactory? httpClientFactory})
      : _http = httpClientFactory ?? _defaultHttpClient;

  final HttpClientFactory _http;

  @override
  String get id => 'ci.pipeline_trigger';
  @override
  String get title => 'Trigger CI pipeline';
  @override
  String get description =>
      'Dispara pipeline externo REAL via HTTP POST (GitHub Actions '
      'repository_dispatch ou endpoint genérico Bearer). External write: '
      'aprovação explícita sempre; token nunca ecoado.';
  @override
  ToolCategory get category => ToolCategory.ci;
  @override
  RiskLevel get risk => RiskLevel.externalWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.explicitApproval;
  @override
  bool get isIdempotent => false;
  @override
  Duration get timeout => const Duration(seconds: 60);
  @override
  String get binaryName => 'dart'; // não usa binário; campo do contrato
  @override
  String get binarySettingKey => 'devtools.dartBinaryPath';

  @override
  List<String> get capabilities => const ['network'];

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['url'],
        'properties': {
          'url': {
            'type': 'string',
            'description': 'Endpoint https. GitHub Actions: '
                'https://api.github.com/repos/{owner}/{repo}/dispatches'
          },
          'eventType': {
            'type': 'string',
            'description':
                'event_type do repository_dispatch (default vt-pipeline)'
          },
          'branch': {'type': 'string'},
          'payload': {'type': 'object'},
          'tokenSetting': {
            'type': 'string',
            'description':
                'chave de settings com o Bearer token (default "ci.token")'
          },
        },
      };

  @override
  Future<ToolHealth> health(ToolContext ctx) async =>
      (ctx.settings.get('ci.token') == null &&
              Platform.environment['VT_CI_TOKEN'] == null)
          ? const HealthUnconfigured('ci.token (Bearer para trigger)')
          : const HealthOk();

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    HttpClient? client;
    try {
      final urlStr = input.str('url');
      final Uri uri;
      try {
        uri = Uri.parse(urlStr);
      } on FormatException {
        return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'URL inválida: "$urlStr".'));
      }
      if (uri.scheme != 'https') {
        return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed,
            message:
                'Trigger de CI exige https (token em trânsito): "$urlStr".'));
      }
      if (!ctx.sandbox.isAllowedDomain(uri.host, ctx)) {
        return ToolFailureResult(VtFailure.domainNotAllowed(uri.host));
      }
      final tokenKey = input.str('tokenSetting').isEmpty
          ? 'ci.token'
          : input.str('tokenSetting');
      final token = ctx.settings.get(tokenKey)?.toString() ??
          Platform.environment['VT_CI_TOKEN'] ??
          '';
      final eventType = input.str('eventType').isEmpty
          ? 'vt-pipeline'
          : input.str('eventType');
      final payload = <String, Object?>{
        ...?((input.values['payload'] as Map?)?.cast<String, Object?>()),
        if (input.str('branch').isNotEmpty) 'ref': input.str('branch'),
      };
      final body = <String, Object?>{
        'event_type': eventType,
        if (payload.isNotEmpty) 'client_payload': payload,
      };
      client = _http();
      final req = await client.openUrl('POST', uri).timeout(timeout);
      req.headers.contentType = ContentType.json;
      req.headers.set('Accept', 'application/vnd.github+json');
      if (token.isNotEmpty) req.headers.set('Authorization', 'Bearer $token');
      req.write(jsonEncode(body));
      final resp = await req.close().timeout(timeout);
      final respBody =
          await resp.transform(const Utf8Decoder(allowMalformed: true)).join();
      final status = resp.statusCode;
      if (status >= 300) {
        return ToolFailureResult(VtFailure(
          code: status == 401 || status == 403
              ? VtErrorCode.permissionDenied
              : VtErrorCode.internalError,
          message:
              'CI trigger respondeu HTTP $status em ${uri.host}${uri.path}.',
          details: {'status': status, 'body': _redact(respBody, token)},
        ));
      }
      return ToolSuccess(
        data: TextOutput(
            'Pipeline disparado: HTTP $status em ${uri.host}${uri.path} '
            '(event_type=$eventType).\nResposta: ${_redact(respBody, token)}',
            metadata: {
              'httpStatus': status,
              'host': uri.host,
              'eventType': eventType,
            }),
        citations: [
          Citation(
              sourceType: 'url',
              sourceRef: urlStr,
              label: 'endpoint CI (${uri.host})'),
        ],
      );
    } on TimeoutException {
      return ToolFailureResult(VtFailure(
          code: VtErrorCode.timeout,
          message: 'CI trigger excedeu ${timeout.inSeconds}s sem resposta.'));
    } on SocketException catch (e) {
      return ToolFailureResult(VtFailure(
          code: VtErrorCode.networkUnavailable,
          message:
              'Sem conexão com o endpoint de CI: ${e.osError?.message ?? e.message}'));
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    } finally {
      client?.close(force: true);
    }
  }

  static String _redact(String s, String token) =>
      token.isEmpty ? s : s.replaceAll(token, '[REDACTED]');
}

// ----------------------------------------------------------- release.create
class ReleaseCreateTool extends DevToolBase {
  ReleaseCreateTool({HttpClientFactory? httpClientFactory})
      : _http = httpClientFactory ?? _defaultHttpClient;

  final HttpClientFactory _http;

  @override
  String get id => 'release.create';
  @override
  String get title => 'Create release';
  @override
  String get description =>
      'Cria tag annotated REAL + seção nova em CHANGELOG.md + commit; opcional: '
      'push da tag e GitHub Release via API. External write: aprovação explícita.';
  @override
  ToolCategory get category => ToolCategory.release;
  @override
  RiskLevel get risk => RiskLevel.externalWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.explicitApproval;
  @override
  String get binaryName => 'git';
  @override
  String get binarySettingKey => 'git.binaryPath';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['version'],
        'properties': {
          'version': {'type': 'string', 'description': 'ex.: 1.4.0 (sem "v")'},
          'notes': {
            'type': 'string',
            'description': 'notas da release/changelog'
          },
          'remote': {'type': 'string', 'description': 'default origin'},
          'pushTag': {'type': 'boolean', 'description': 'git push REAL da tag'},
          'githubRepo': {
            'type': 'string',
            'description': 'owner/repo p/ GitHub Release (opcional)'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final version = input.str('version');
      if (!RegExp(r'^\d+(\.\d+)*([\-+].*)?$').hasMatch(version)) {
        return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Versão inválida "$version" (esperado x.y.z[-pre]).'));
      }
      final root = workingDir(ctx);
      final tag = 'v$version';
      final notes = input.str('notes');
      // 1) recusa sobrescrever tag existente (real)
      final tags = await _runGit(ctx, ['tag', '-l', tag]);
      if (tags.exitCode != 0) {
        return ToolFailureResult(
            failure(tags, VtErrorCode.internalError, 'tag -l'));
      }
      if (tags.stdout.trim() == tag) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Tag "$tag" já existe — recuso sobrescrever.',
        ));
      }
      // 2) CHANGELOG.md real (insere seção sob o header)
      final changelogPath = joinPath(root, 'CHANGELOG.md');
      final existing = await File(changelogPath).exists()
          ? await File(changelogPath).readAsString()
          : '# Changelog\n';
      final date = DateTime.now().toIso8601String().substring(0, 10);
      final section =
          '\n## $tag - $date\n\n${notes.isEmpty ? '_sem notas_' : notes}\n\n';
      final nl = existing.indexOf('\n');
      final insertAt = (nl >= 0 && existing.startsWith('# ')) ? nl + 1 : 0;
      final updated = existing.replaceRange(insertAt, insertAt, section);
      await File(changelogPath).writeAsString(updated, flush: true);
      // 3) commit do changelog (apenas se houve mudança material)
      final addRes = await _runGit(ctx, ['add', 'CHANGELOG.md']);
      if (addRes.exitCode != 0) {
        return ToolFailureResult(
            failure(addRes, VtErrorCode.internalError, 'add'));
      }
      final stagedDiff = await _runGit(ctx, ['diff', '--cached', '--quiet']);
      if (stagedDiff.exitCode == 1) {
        final c = await _runGit(
            ctx, ['commit', '-m', 'chore(release): $tag changelog']);
        if (c.exitCode != 0) {
          return ToolFailureResult(
              failure(c, VtErrorCode.internalError, 'commit'));
        }
      } else if (stagedDiff.exitCode != 0) {
        return ToolFailureResult(
            failure(stagedDiff, VtErrorCode.internalError, 'diff --cached'));
      }
      // 4) tag annotated REAL apontando para HEAD
      final tagRes = await _runGit(ctx,
          ['tag', '-a', tag, '-m', notes.isEmpty ? 'Release $tag' : notes]);
      if (tagRes.exitCode != 0) {
        return ToolFailureResult(
            failure(tagRes, VtErrorCode.internalError, 'tag'));
      }
      final logLine = await _runGit(ctx, ['rev-parse', tag]);
      final sha = logLine.stdout.trim();
      final artifacts = <ArtifactRef>[
        ArtifactRef(kindOf: 'tag', pathOrUri: 'git:$tag'),
        ArtifactRef(kindOf: 'changelog', pathOrUri: changelogPath),
      ];
      final citations = <Citation>[
        if (sha.isNotEmpty)
          Citation(
              sourceType: 'commit',
              sourceRef: sha,
              label: 'HEAD rotulado $tag'),
      ];
      // 5) push da tag (opcional — external write real)
      if (input.boolOf('pushTag')) {
        final remote =
            input.str('remote').isEmpty ? 'origin' : input.str('remote');
        final p = await _runGit(ctx, ['push', remote, tag]);
        if (p.exitCode != 0) {
          return ToolFailureResult(
              failure(p, VtErrorCode.internalError, 'push $remote $tag'));
        }
      }
      // 6) GitHub Release via API real (opcional)
      String? ghNote;
      final repo = input.str('githubRepo');
      if (repo.isNotEmpty) {
        final token = ctx.settings.get('release.githubToken')?.toString() ??
            Platform.environment['GH_TOKEN'] ??
            '';
        if (token.isEmpty) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.apiKeyMissing,
            message:
                'githubRepo pedido mas sem GH_TOKEN nem settings release.githubToken.',
          ));
        }
        final client = _http();
        try {
          final uri = Uri.parse('https://api.github.com/repos/$repo/releases');
          final req = await client
              .openUrl('POST', uri)
              .timeout(const Duration(seconds: 30));
          req.headers.set('Accept', 'application/vnd.github+json');
          req.headers.set('Authorization', 'Bearer $token');
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(
              {'tag_name': tag, 'name': 'Release $tag', 'body': notes}));
          final resp = await req.close().timeout(const Duration(seconds: 30));
          final body = await resp
              .transform(const Utf8Decoder(allowMalformed: true))
              .join();
          if (resp.statusCode >= 300) {
            return ToolFailureResult(VtFailure(
              code: resp.statusCode == 401 || resp.statusCode == 403
                  ? VtErrorCode.permissionDenied
                  : VtErrorCode.internalError,
              message: 'GitHub Release falhou (HTTP ${resp.statusCode}).',
              details: {'body': body.replaceAll(token, '[REDACTED]')},
            ));
          }
          final j = jsonDecode(body) as Map<String, Object?>;
          final url = j['html_url']?.toString() ?? '';
          ghNote = 'GitHub release criado: $url';
          if (url.isNotEmpty) {
            citations.add(Citation(
                sourceType: 'url',
                sourceRef: url,
                label: 'GitHub release $tag'));
          }
        } finally {
          client.close(force: true);
        }
      }
      return ToolSuccess(
        data: TextOutput(
            'Release $tag criada: CHANGELOG.md + commit + tag annotated'
            '${input.boolOf('pushTag') ? ' + push' : ''}.'
            '${ghNote != null ? '\n$ghNote' : ''}',
            metadata: {'version': version, 'tag': tag, 'sha': sha}),
        citations: citations,
        artifacts: artifacts,
      );
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }

  Future<ProcResult> _runGit(ToolContext ctx, List<String> args) async {
    final git = await resolveBinary(ctx);
    if (git == null) throw VtFailure.binaryMissing('git');
    return runCaptured(git, ['-C', workingDir(ctx), ...args],
        cwd: workingDir(ctx), limit: timeout);
  }
}
