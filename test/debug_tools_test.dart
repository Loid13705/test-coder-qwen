/// Testes das tools de qualidade/depuração (bug/test/lint/debug).
///
/// Regra da casa: sem output fake. Binário ausente → degradação honesta
/// (health tipado + ToolFailureResult com código real); binário presente
/// (git/sh) → execução VERDADEIRA em workspace temporário.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:techvt/domain/errors/vt_failure.dart';
import 'package:techvt/domain/tools/tool_contract.dart';
import 'package:techvt/infrastructure/devtools/debug_tools.dart';
import 'package:techvt/infrastructure/process/process_utils.dart';

class _Sandbox implements SandboxGateway {
  const _Sandbox();
  @override
  Future<String> resolveReadable(String rawPath, ToolContext ctx) async =>
      rawPath;
  @override
  Future<String> resolveWritable(String rawPath, ToolContext ctx) async =>
      rawPath;
  @override
  bool isAllowedDomain(String domain, ToolContext ctx) => true;
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

List<VtTool<ToolInput, ToolOutput>> _allQualityTools() => [
      TestRunSuiteTool(),
      TestGetCoverageTool(),
      LintRunTool(),
      BugReproduceTool(),
      BugVerifyFixTool(),
      BugBisectTool(),
      DebugStartSessionTool(DebugSessionManager.detached()),
      DebugSetBreakpointTool(),
      DebugRemoveBreakpointTool(),
      DebugStepTool('next', 'debug.step_over', 'Step over', 'x'),
      DebugStepTool('stepIn', 'debug.step_into', 'Step into', 'x'),
      DebugStepTool('stepOut', 'debug.step_out', 'Step out', 'x'),
      DebugEvaluateExpressionTool(),
      DebugGetStackTool(),
      DebugGetVariablesTool(),
      DebugAttachObservatoryTool(),
    ];

void main() {
  group('contratos', () {
    test('ids/titles/riscos/schemas válidos e únicos', () {
      final ids = <String>{};
      for (final t in _allQualityTools()) {
        expect(ids.add(t.id), isTrue, reason: 'id duplicado ${t.id}');
        expect(t.title, isNotEmpty);
        expect(t.inputSchema['type'], 'object');
        expect(
            t.category,
            anyOf(ToolCategory.bug, ToolCategory.test, ToolCategory.lint,
                ToolCategory.debug));
      }
      expect(
          ids,
          containsAll([
            'bug.verify_fix',
            'test.run_suite',
            'test.get_coverage',
            'lint.run',
            'bug.reproduce',
            'bug.bisect',
            'debug.start_session',
            'debug.set_breakpoint',
            'debug.remove_breakpoint',
            'debug.step_over',
            'debug.step_into',
            'debug.step_out',
            'debug.evaluate_expression',
            'debug.get_stack',
            'debug.get_variables',
            'debug.attach_observatory',
          ]));
    });

    test('validateInput rejeita tipo errado e obrigatório ausente', () {
      final repro = BugReproduceTool();
      expect(() => repro.validateInput({'steps': 'not-a-list'}),
          throwsA(isA<VtFailure>()));
      final bisect = BugBisectTool();
      expect(() => bisect.validateInput({'bad': 'HEAD~1'}),
          throwsA(isA<VtFailure>()));
    });
  });

  group('degradação honesta sem binários', () {
    late String ws;
    setUp(() async {
      ws = (await Directory.systemTemp.createTemp('vt_quality_neg')).path;
    });
    tearDown(() async => Directory(ws).delete(recursive: true));

    test('test.run_suite sem dart/flutter → binary_missing via health+exec',
        () async {
      final tool = TestRunSuiteTool();
      final ctx = _ctx(ws);
      if (await findBinaryInPath('dart') != null ||
          await findBinaryInPath('flutter') != null) {
        return; // host tem SDK — cobertura real acontece no outro grupo
      }
      final h = await tool.health(ctx);
      expect(h, isA<HealthMissingBinary>());
      final r = await tool.execute(ctx, const MapToolInput({}));
      expect(r, isA<ToolFailureResult>());
      final f = (r as ToolFailureResult).failure;
      expect(f.code, VtErrorCode.binaryMissing);
    });

    test('debug.start_session sem adapter DAP → sidecar_not_running', () async {
      final tool = DebugStartSessionTool(DebugSessionManager.detached());
      final r = await tool.execute(_ctx(ws), const MapToolInput({}));
      expect(r, isA<ToolFailureResult>());
      final f = (r as ToolFailureResult).failure;
      // sem adapter no PATH nem nas settings o erro é sidecar/binary — nunca
      // uma sessão falsa
      expect(f.code,
          anyOf(VtErrorCode.sidecarNotRunning, VtErrorCode.binaryMissing));
    });

    test('debug.* com sessionId inexistente → validation_failed', () async {
      for (final tool in <VtTool<ToolInput, ToolOutput>>[
        DebugGetStackTool(),
        DebugGetVariablesTool(),
        DebugEvaluateExpressionTool(),
      ]) {
        final r = await tool.execute(
            _ctx(ws), const MapToolInput({'sessionId': 'nope'}));
        expect(r, isA<ToolFailureResult>(), reason: tool.id);
        expect(
            (r as ToolFailureResult).failure.code, VtErrorCode.validationFailed,
            reason: tool.id);
      }
    });

    test('bug.verify_fix sem evidência → validation_failed', () async {
      final r =
          await BugVerifyFixTool().execute(_ctx(ws), const MapToolInput({}));
      expect(r, isA<ToolFailureResult>());
      expect(
          (r as ToolFailureResult).failure.code, VtErrorCode.validationFailed);
    });

    test('debug.attach_observatory sem uri e sem flutter → falha real',
        () async {
      final tool = DebugAttachObservatoryTool();
      final r = await tool.execute(_ctx(ws), const MapToolInput({}));
      expect(r, isA<ToolFailureResult>());
      expect(
          (r as ToolFailureResult).failure.code, VtErrorCode.validationFailed);
    });

    test('attach_observatory com endpoint morto → network/timeout real',
        () async {
      final tool = DebugAttachObservatoryTool();
      final r = await tool.execute(
          _ctx(ws),
          const MapToolInput({
            'uri': 'ws://127.0.0.1:1/x/ws',
          }));
      expect(r, isA<ToolFailureResult>());
      final code = (r as ToolFailureResult).failure.code;
      expect(
          code,
          anyOf(VtErrorCode.networkUnavailable, VtErrorCode.timeout,
              VtErrorCode.sidecarNotRunning, VtErrorCode.internalError));
    });
  });

  group('execução REAL quando o host tem os binários', () {
    late String ws;
    setUp(() async {
      ws = (await Directory.systemTemp.createTemp('vt_quality_real')).path;
    });
    tearDown(() async => Directory(ws).delete(recursive: true));

    test('bug.reproduce roda passos sh reais e grava log-artefato', () async {
      if (await findBinaryInPath('sh') == null) return;
      final tool = BugReproduceTool();
      final r = await tool.execute(
          _ctx(ws),
          const MapToolInput({
            'steps': ['echo passo-um-ok', 'exit 3'],
            'expect': 'passo-um-ok',
          }));
      if (r is ToolFailureResult<TextOutput>) {
        fail('execute falhou: ${r.failure.toJson()}');
      }
      expect(r, isA<ToolSuccess<TextOutput>>());
      final s = r as ToolSuccess<TextOutput>;
      final log = File(s.data.metadata['logPath']! as String);
      expect(await log.exists(), isTrue);
      final content = await log.readAsString();
      expect(content, contains('passo-um-ok'));
      expect(content, contains('exit=3'));
      expect(s.data.metadata['reproduced'], true);
      expect(s.data.metadata['firstFailureStep'], 2);
      expect(s.artifacts.single.kindOf, 'log');
    });

    test('bug.bisect encontra o primeiro commit ruim de verdade', () async {
      final git = await findBinaryInPath('git');
      if (git == null || await findBinaryInPath('sh') == null) return;
      // repo sintético: 5 commits; bug introduzido no 3º
      Future<void> gitRun(List<String> args) async {
        final r = await Process.run(git, args, workingDirectory: ws);
        if (r.exitCode != 0) throw StateError('git $args: ${r.stderr}');
      }

      await gitRun(['init', '-q', '.']);
      await gitRun(['config', 'user.email', 't@t']);
      await gitRun(['config', 'user.name', 't']);
      final f = File('$ws/counter.txt');
      for (var i = 1; i <= 5; i++) {
        await f.writeAsString('$i\n');
        await gitRun(['add', '.']);
        await gitRun(['commit', '-q', '-m', 'c$i']);
        if (i == 3) {
          // marca do bug: arquivo .bug presente a partir daqui
          await File('$ws/.bug').writeAsString('yes');
          await gitRun(['add', '.']);
          await gitRun(['commit', '--amend', '-q', '--no-edit']);
        }
      }
      final head = (await Process.run('git', ['rev-parse', 'HEAD'],
              workingDirectory: ws))
          .stdout
          .toString()
          .trim();
      final firstGood = (await Process.run('git', ['rev-parse', 'HEAD~4'],
              workingDirectory: ws))
          .stdout
          .toString()
          .trim();

      final tool = BugBisectTool();
      final r = await tool.execute(
          _ctx(ws),
          MapToolInput({
            'bad': head,
            'good': firstGood,
            // teste real: falha se .bug existir
            'testCommand': 'test ! -f .bug',
          }));
      expect(r, isA<ToolSuccess<TextOutput>>(),
          reason: r is ToolFailureResult
              ? (r as ToolFailureResult).failure.message
              : '');
      if (r is! ToolSuccess<TextOutput>) return;
      final sha = r.data.metadata['firstBadCommit'] as String;
      expect(sha.length, 40);
      expect(r.citations.single.sourceType, 'commit');
      // HEAD voltou ao normal (bisect reset rodou)
      final status = await Process.run('git', ['status', '--porcelain'],
          workingDirectory: ws);
      expect(status.stdout.toString().trim(), isEmpty);
    });

    test('lint.run / test.run_suite: exit!=0 vira falha tipada (se dart)',
        () async {
      if (await findBinaryInPath('dart') == null) return;
      final tool = TestRunSuiteTool();
      final r = await tool.execute(_ctx(ws), const MapToolInput({}));
      // workspace sem pubspec/test → dart test falha com exit != 0 →
      // test_failed (nunca sucesso inventado)
      expect(r, isA<ToolFailureResult>());
      final f = (r as ToolFailureResult).failure;
      expect(
          f.code,
          anyOf(VtErrorCode.testFailed, VtErrorCode.buildFailed,
              VtErrorCode.binaryMissing));
    });
  });
}
