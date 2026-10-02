/// Tools GitHub (spec catálogo: github.*).
///
/// Execução REAL via CLI `gh` (GitHub CLI) — sem simulação e sem inventar
/// URLs/números:
/// - `github.issue_create` — cria issue real (`gh issue create`) e devolve o
///   número/URL impressos pelo próprio gh;
/// - `github.pr_create`    — cria pull request real (`gh pr create`).
///
/// Health tipado: `gh` ausente → binary_missing com ação de instalação; repo
/// sem remote origin ou sessão não autenticada falham com erro real do gh,
/// propagado cru. external_write ⇒ aprovação explícita sempre.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import '../process/process_utils.dart';

abstract class _GithubTool extends VtTool<MapToolInput, TextOutput> {
  @override
  ToolCategory get category => ToolCategory.issueTracker;
  @override
  List<String> get capabilities => const ['github'];
  @override
  Duration get timeout => const Duration(seconds: 120);
  @override
  RetryPolicy get retryPolicy => const RetryPolicy(maxAttempts: 1);
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get outputSchema => const {'type': 'object'};
  @override
  RiskLevel get risk => RiskLevel.externalWrite;
  @override
  ApprovalPolicyMode get defaultApproval =>
      ApprovalPolicyMode.explicitApproval;

  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async {
    final gh = await resolveGh(ctx);
    if (gh == null) return const HealthMissingBinary('gh');
    return const HealthOk();
  }

  Future<String?> resolveGh(ToolContext ctx) async {
    final custom = ctx.settings.get('github.binaryPath') as String?;
    if (custom != null && File(custom).existsSync()) return custom;
    return findBinaryInPath('gh');
  }

  String repoRoot(ToolContext ctx) => ctx.workspaceRoots.isEmpty
      ? Directory.current.path
      : ctx.workspaceRoots.first;

  /// Roda `gh <args>` REAL no repo do workspace. [repoOverride] permite alvo
  /// explícito `owner/name` (flag --repo nativa do gh).
  Future<ProcessResult> runGh(ToolContext ctx, List<String> args,
      {String? repoOverride}) async {
    final gh = await resolveGh(ctx);
    if (gh == null) {
      throw VtFailure.binaryMissing('gh',
          hint: ' Instale o GitHub CLI (https://cli.github.com) e rode '
              '"gh auth login".');
    }
    final full = [...args];
    if (repoOverride != null && repoOverride.isNotEmpty) {
      full.insert(0, '--repo');
      full.insert(1, repoOverride);
    }
    try {
      return await Process.run(gh, full, workingDirectory: repoRoot(ctx))
          .timeout(timeout);
    } on ProcessException catch (e) {
      throw VtFailure(
          code: VtErrorCode.binaryMissing,
          message: 'Falha ao iniciar "gh": ${e.message}');
    }
  }

  ToolSuccess<TextOutput> ok(Object data,
          {List<Citation> citations = const []}) =>
      ToolSuccess(
          data: TextOutput(const JsonEncoder.withIndent('  ').convert(data)),
          citations: citations);

  ToolFailureResult<TextOutput> fail(ProcessResult res, String verb) =>
      ToolFailureResult(VtFailure(
        code: VtErrorCode.internalError,
        message: 'gh $verb falhou (exit ${res.exitCode}): '
            '${(res.stderr as String?)?.trim().isNotEmpty == true ? res.stderr : res.stdout}',
        details: {'exitCode': res.exitCode, 'stderr': res.stderr},
      ));
}

// ---------------------------------------------------------- github.issue_create
class GithubIssueCreateTool extends _GithubTool {
  @override
  String get id => 'github.issue_create';
  @override
  String get title => 'Cria issue GitHub';
  @override
  String get description =>
      'Cria uma issue REAL via GitHub CLI ("gh issue create"). Título e corpo '
      'reais; labels/assignees/milestone opcionais. Retorna número e URL '
      'exatamente como impressos pelo gh — nada é montado por nós. Requer '
      '"gh auth login" e repo com remote origin (ou parâmetro "repo" '
      'owner/name).';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'body': {'type': 'string'},
          'labels': {'type': 'array', 'items': {'type': 'string'}},
          'assignees': {'type': 'array', 'items': {'type': 'string'}},
          'milestone': {'type': 'string'},
          'repo': {'type': 'string'},
        },
        'required': ['title'],
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final args = <String>[
        'issue', 'create', '--title', input.str('title'),
      ];
      final body = input.str('body');
      if (body.isNotEmpty) args.addAll(['--body', body]);
      for (final l in input.list('labels')) {
        if (l.trim().isNotEmpty) args.addAll(['--label', l.trim()]);
      }
      for (final a in input.list('assignees')) {
        if (a.trim().isNotEmpty) args.addAll(['--assignee', a.trim()]);
      }
      final ms = input.str('milestone');
      if (ms.isNotEmpty) args.addAll(['--milestone', ms]);
      final res = await runGh(ctx, args, repoOverride: input.str('repo'));
      if (res.exitCode != 0) return fail(res, 'issue create');
      final url = (res.stdout as String).trim();
      final numMatch = RegExp(r'/issues/(\d+)').firstMatch(url);
      return ok({
        'created': true,
        'number': numMatch != null ? int.parse(numMatch.group(1)!) : null,
        'url': url,
        'title': input.str('title'),
      }, citations: [
        Citation(sourceType: 'url', sourceRef: url, label: 'issue criada'),
      ]);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    } on TimeoutException {
      return ToolFailureResult(VtFailure.timeout(timeout));
    }
  }
}

// ------------------------------------------------------------- github.pr_create
class GithubPrCreateTool extends _GithubTool {
  @override
  String get id => 'github.pr_create';
  @override
  String get title => 'Cria Pull Request';
  @override
  String get description =>
      'Cria um pull request REAL via GitHub CLI ("gh pr create") a partir da '
      'branch atual do workspace (ou base/head explícitos; sem base+head usa '
      '--fill sobre o estado real do branch). Retorna a URL impressa pelo gh. '
      'A branch precisa existir no remote quando "head" é usado — o erro do '
      'gh é reportado cru, sem maquiagem.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'body': {'type': 'string'},
          'base': {'type': 'string'},
          'head': {'type': 'string'},
          'draft': {'type': 'boolean'},
          'repo': {'type': 'string'},
        },
        'required': ['title'],
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    try {
      final args = <String>['pr', 'create', '--title', input.str('title')];
      final body = input.str('body');
      if (body.isNotEmpty) args.addAll(['--body', body]);
      final base = input.str('base');
      if (base.isNotEmpty) args.addAll(['--base', base]);
      final head = input.str('head');
      if (head.isNotEmpty) args.addAll(['--head', head]);
      if (input.boolOf('draft')) args.add('--draft');
      if (base.isEmpty && head.isEmpty && body.isEmpty) args.add('--fill');
      final res = await runGh(ctx, args, repoOverride: input.str('repo'));
      if (res.exitCode != 0) return fail(res, 'pr create');
      final url = (res.stdout as String).trim().split('\n').last.trim();
      final numMatch = RegExp(r'/pull/(\d+)').firstMatch(url);
      return ok({
        'created': true,
        'number': numMatch != null ? int.parse(numMatch.group(1)!) : null,
        'url': url,
        'title': input.str('title'),
        'draft': input.boolOf('draft'),
      }, citations: [
        Citation(sourceType: 'url', sourceRef: url, label: 'PR criado'),
      ]);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    } on TimeoutException {
      return ToolFailureResult(VtFailure.timeout(timeout));
    }
  }
}
