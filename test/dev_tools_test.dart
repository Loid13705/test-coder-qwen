/// Testes das dev-tools reais (pub/flutter/ci/release).
///
/// Regra da casa: nada de output fake. Quando o binário não existe no host,
/// o teste verifica a degradação honesta (health tipado + ToolFailureResult);
/// quando existe (git/dart), executa de verdade em workspace temporário.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:techvt/domain/errors/vt_failure.dart';
import 'package:techvt/domain/tools/tool_contract.dart';
import 'package:techvt/infrastructure/devtools/dev_tools.dart';
import 'package:techvt/infrastructure/process/process_utils.dart';

class _Sandbox implements SandboxGateway {
  const _Sandbox({this.allowDomain = true});
  final bool allowDomain;
  @override
  Future<String> resolveReadable(String rawPath, ToolContext ctx) async =>
      throw VtFailure.pathOutOfSandbox(rawPath);
  @override
  Future<String> resolveWritable(String rawPath, ToolContext ctx) async =>
      throw VtFailure.pathOutOfSandbox(rawPath);
  @override
  bool isAllowedDomain(String domain, ToolContext ctx) => allowDomain;
}

class _Settings implements SettingsGateway {
  const _Settings([this.values = const {}]);
  final Map<String, Object?> values;
  @override
  Object? get(String key, {String? workspaceId}) => values[key];
}

ToolContext _ctx(String root, {Map<String, Object?> settings = const {}}) =>
    ToolContext(
      workspaceRoots: [root],
      sandbox: const _Sandbox(),
      settings: _Settings(settings),
    );

Future<String?> findGit() async => findBinaryInPath('git');

/// Lista de tools concretas tipada corretamente (cada uma tem seu I/O próprio).
List<VtTool<ToolInput, ToolOutput>> _allDevTools() => [
      PubGetTool(),
      PubAddTool(),
      PubOutdatedTool(),
      FlutterDoctorTool(),
      FlutterRunTool(),
      FlutterBuildApkTool(),
      FlutterBuildWebTool(),
      FlutterTestTool(),
      CiPipelineTriggerTool(),
      ReleaseCreateTool(),
    ];

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('techvt_devtools_');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // já removido
    }
  });

  group('contrato de registro', () {
    test('10 tools pedidas existem com risco/política corretos', () {
      final expected = <String, (ToolCategory, RiskLevel, ApprovalPolicyMode)>{
        'pub.get': (ToolCategory.pub, RiskLevel.networkRead, ApprovalPolicyMode.auto),
        'pub.add': (ToolCategory.pub, RiskLevel.localWrite, ApprovalPolicyMode.reviewEach),
        'pub.outdated': (ToolCategory.pub, RiskLevel.networkRead, ApprovalPolicyMode.auto),
        'flutter.doctor': (ToolCategory.flutter, RiskLevel.readOnly, ApprovalPolicyMode.auto),
        'flutter.run': (ToolCategory.flutter, RiskLevel.execute, ApprovalPolicyMode.reviewEach),
        'flutter.build_apk': (ToolCategory.flutter, RiskLevel.localWrite, ApprovalPolicyMode.reviewEach),
        'flutter.build_web': (ToolCategory.flutter, RiskLevel.localWrite, ApprovalPolicyMode.reviewEach),
        'flutter.test': (ToolCategory.flutter, RiskLevel.execute, ApprovalPolicyMode.auto),
        'ci.pipeline_trigger': (ToolCategory.ci, RiskLevel.externalWrite, ApprovalPolicyMode.explicitApproval),
        'release.create': (ToolCategory.release, RiskLevel.externalWrite, ApprovalPolicyMode.explicitApproval),
      };
      final all = _allDevTools();
      for (final t in all) {
        final e = expected[t.id];
        expect(e, isNotNull, reason: 'tool inesperada ${t.id}');
        expect(t.category, e!.$1);
        expect(t.risk, e.$2);
        expect(t.defaultApproval, e.$3);
        expect(t.inputSchema['type'], 'object');
      }
      expect(all.map((t) => t.id).toSet().length, 10);
    });

    test('schemas serializam para o wire dos providers', () {
      final reg = [PubAddTool(), ReleaseCreateTool()];
      final json = jsonEncode([for (final t in reg) t.catalogEntry()]);
      expect(json, contains('pub.add'));
      expect(json, contains('release.create'));
    });
  });

  group('degradação honesta sem binários', () {
    test('health tipado reflete presença real dos binários no host', () async {
      final ctx = _ctx(tmp.path);
      for (final t in _allDevTools()) {
        final h = await t.health(ctx);
        // só pode ser diagnóstico verdadeiro: ok, missing_binary ou unconfigured
        expect(
            h,
            anyOf(isA<HealthOk>(), isA<HealthMissingBinary>(),
                isA<HealthUnconfigured>()),
            reason: 'health de ${t.id} não é diagnóstico real');
      }
    });

    test('pub.get sem dart acessível → falha real (nunca simulada)', () async {
      final tool = PubGetTool();
      if (await findBinaryInPath('dart') != null) return; // host tem dart: coberto no grupo de execução
      final res = await tool.execute(_ctx(tmp.path), await tool.parseInput({}));
      expect(res, isA<ToolFailureResult<TextOutput>>());
      expect(((res as ToolFailureResult).failure.code),
          VtErrorCode.binaryMissing);
    });

    test('flutter.run valida device contra lista REAL antes de iniciar',
        () async {
      final tool = FlutterRunTool();
      final ctx = _ctx(tmp.path);
      final res = await tool.execute(
          ctx, await tool.parseInput({'deviceId': 'nao-existe-xyz'}));
      expect(res, isA<ToolFailureResult<TextOutput>>());
      final f = (res as ToolFailureResult<TextOutput>).failure;
      // sem flutter → binary_missing; com flutter → device_not_found. Ambos reais.
      expect(f.code,
          anyOf(VtErrorCode.binaryMissing, VtErrorCode.deviceNotFound));
      if (f.code == VtErrorCode.deviceNotFound) {
        expect(f.message, contains('nao-existe-xyz'));
      }
    });
  });

  group('validações estruturais reais', () {
    test('pub.add rejeita spec de pacote malformada', () async {
      final tool = PubAddTool();
      final ctx = _ctx(tmp.path);
      final res =
          await tool.execute(ctx, await tool.parseInput({'package': 'rm -rf /;'}));
      expect(res, isA<ToolFailureResult<TextOutput>>());
      expect(((res as ToolFailureResult).failure.code),
          VtErrorCode.validationFailed);
    });

    test('release.create rejeita versão inválida ANTES de tocar o repo',
        () async {
      final tool = ReleaseCreateTool();
      final ctx = _ctx(tmp.path);
      final res =
          await tool.execute(ctx, await tool.parseInput({'version': 'abc!!'}));
      expect(res, isA<ToolFailureResult<TextOutput>>());
      expect(((res as ToolFailureResult).failure.code),
          VtErrorCode.validationFailed);
      expect(File('${tmp.path}/CHANGELOG.md').existsSync(), isFalse);
    });

    test('ci.pipeline_trigger exige https e domínio na allowlist', () async {
      final tool = CiPipelineTriggerTool();
      final ctxHttp = _ctx(tmp.path);
      var res = await tool.execute(
          ctxHttp, await tool.parseInput({'url': 'http://exemplo.com/dispatch'}));
      expect(((res as ToolFailureResult).failure.code),
          VtErrorCode.validationFailed);
      final ctxDeny = ToolContext(
        workspaceRoots: [tmp.path],
        sandbox: const _Sandbox(allowDomain: false),
        settings: const _Settings(),
      );
      res = await tool.execute(
          ctxDeny, await tool.parseInput({'url': 'https://api.github.com/x'}));
      expect(((res as ToolFailureResult).failure.code),
          VtErrorCode.domainNotAllowed);
    });

    test('validateInput rejeita tipos errados nos schemas novos', () {
      expect(
          () => PubAddTool().validateInput({'package': 42}),
          throwsA(isA<VtFailure>()));
      expect(
          () => FlutterRunTool().validateInput({'timeoutSeconds': 'muito'}),
          throwsA(isA<VtFailure>()));
      expect(() => ReleaseCreateTool().validateInput({}),
          throwsA(isA<VtFailure>())); // version obrigatória
    });
  });

  group('execução real quando binário presente', () {
    test('git presente → release.create cria CHANGELOG + commit + tag reais',
        () async {
      final git = await findGit();
      if (git == null) return; // host sem git: degradação coberta acima
      final repo = Directory('${tmp.path}/repo')..createSync();
      Process.runSync(git, ['-C', repo.path, 'init', '-b', 'main']);
      Process.runSync(git,
          ['-C', repo.path, 'config', 'user.email', 'vt@test.local']);
      Process.runSync(git, ['-C', repo.path, 'config', 'user.name', 'VT Test']);
      File('${repo.path}/a.txt').writeAsStringSync('a\n');
      Process.runSync(git, ['-C', repo.path, 'add', 'a.txt']);
      Process.runSync(git, ['-C', repo.path, 'commit', '-m', 'init']);

      final tool = ReleaseCreateTool();
      final ctx = _ctx(repo.path);
      final res = await tool.execute(
          ctx, await tool.parseInput({'version': '0.2.0', 'notes': 'feat: x'}));
      expect(res, isA<ToolSuccess<TextOutput>>(),
          reason: res is ToolFailureResult<TextOutput>
              ? res.failure.message
              : 'tipo inesperado ${res.runtimeType}');
      final okRes = res as ToolSuccess<TextOutput>;
      // CHANGELOG real escrito
      final changelog = File('${repo.path}/CHANGELOG.md').readAsStringSync();
      expect(changelog, contains('v0.2.0'));
      expect(changelog, contains('feat: x'));
      // tag annotated REAL verificada por git direto
      final tagCheck = Process.runSync(git, ['-C', repo.path, 'tag', '-l']);
      expect(tagCheck.stdout.toString().trim(), contains('v0.2.0'));
      final typeCheck =
          Process.runSync(git, ['-C', repo.path, 'cat-file', '-t', 'v0.2.0']);
      expect(typeCheck.stdout.toString().trim(), 'tag'); // annotated
      // citação aponta para sha real
      expect(okRes.citations.any((c) => c.sourceType == 'commit'), isTrue);
      expect(okRes.artifacts.any((a) => a.kindOf == 'changelog'), isTrue);

      // segunda chamada recusa sobrescrever tag existente (real)
      final again = await tool.execute(
          ctx, await tool.parseInput({'version': '0.2.0'}));
      expect(again, isA<ToolFailureResult<TextOutput>>());
      expect(((again as ToolFailureResult).failure.code),
          VtErrorCode.validationFailed);
    });

    test('dart presente → pub.outdated produz relatório real ou erro real',
        () async {
      final dart = await findBinaryInPath('dart');
      if (dart == null) return;
      final proj = Directory('${tmp.path}/proj')..createSync();
      File('${proj.path}/pubspec.yaml').writeAsStringSync('''
name: vt_probe
environment:
  sdk: ^3.0.0
''');
      final tool = PubOutdatedTool();
      final ctx = _ctx(proj.path);
      final res = await tool.execute(ctx, await tool.parseInput({'json': true}));
      // qualquer um dos dois é honesto; o que NÃO pode é sucesso fabricado
      if (res is ToolSuccess<TextOutput>) {
        expect(res.data.metadata['exitCode'], 0);
        expect(res.data.text, isNotEmpty);
      } else {
        final f = (res as ToolFailureResult).failure;
        expect(
            f.code,
            anyOf(VtErrorCode.buildFailed, VtErrorCode.timeout,
                VtErrorCode.internalError, VtErrorCode.binaryMissing));
      }
    });

    test('flutter.run mata sessão REAL no timeout (sem zombie)', () async {
      final flutter = await findBinaryInPath('flutter');
      if (flutter == null) return;
      final devices = await realDeviceList(_ctx(tmp.path));
      if (devices.isEmpty) return;
      final id = devices.first['id'].toString();
      var started = false;
      final tool = FlutterRunTool(onSessionStarted: (p, d) => started = true);
      final ctx = _ctx(tmp.path);
      final res = await tool.execute(ctx,
          await tool.parseInput({'deviceId': id, 'timeoutSeconds': 5}));
      expect(started, isTrue);
      // sessão terminada por kill real ou exit — metadata honesta
      if (res is ToolSuccess<TextOutput>) {
        expect(res.data.metadata['sessionEnded'],
            anyOf('timeout_kill', 'app_exit'));
      }
    });
  });
}
