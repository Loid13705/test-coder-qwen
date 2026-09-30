/// Implementação real de tools Git (spec catálogo #58–#72).
///
/// Executa o binário `git` via Process.run com arrays de argumentos (sem shell
/// interpolation → proteção contra shell injection). Se o git não existir,
/// retorna binary_missing com ação concreta. Saídas são sempre stdout/stderr
/// reais do processo.
library;

import 'dart:convert';
import 'dart:io';

import '../../domain/errors/vt_failure.dart';
import '../../domain/models/pagination.dart';
import '../../domain/tools/tool_contract.dart';
import '../process/process_utils.dart';


/// Conta linhas de adição/remoção reais de um diff unificado (ignora headers +++/---).
int _countLines(String diff, String sign) {
  var n = 0;
  for (final l in const LineSplitter().convert(diff)) {
    if (l.startsWith('$sign$sign$sign')) continue;
    if (l.startsWith(sign)) n++;
  }
  return n;
}

abstract class _GitToolBase extends VtTool<MapToolInput, TextOutput> {
  @override
  ToolCategory get category => ToolCategory.git;
  @override
  List<String> get capabilities => const ['git'];
  @override
  Duration get timeout => const Duration(seconds: 60);
  @override
  RetryPolicy get retryPolicy => const RetryPolicy();
  @override
  bool get isIdempotent => true;
  @override
  Map<String, Object?> get outputSchema => const {'type': 'object'};

  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async {
    final git = await resolveGit(ctx);
    return git == null ? const HealthMissingBinary('git') : const HealthOk();
  }

  Future<String?> resolveGit(ToolContext ctx) async {
    final custom = ctx.settings.get('git.binaryPath') as String?;
    if (custom != null && File(custom).existsSync()) return custom;
    return findBinaryInPath('git');
  }

  /// Working dir real: raiz do workspace (sandbox aplicado pelo runtime).
  String repoRoot(ToolContext ctx) => ctx.workspaceRoots.first;

  Future<ProcessResult> runGit(
      ToolContext ctx, List<String> args, {String? cwd}) async {
    final git = await resolveGit(ctx);
    if (git == null) throw VtFailure.binaryMissing('git');
    try {
      return await Process.run(git, ['-C', cwd ?? repoRoot(ctx), ...args])
          .timeout(timeout);
    } on ProcessException catch (e) {
      throw VtFailure(
          code: VtErrorCode.binaryMissing,
          message: 'Falha ao iniciar "git": ${e.message}');
    }
  }

  VtFailure failureFrom(ProcessResult res, String verb) => VtFailure(
        code: res.exitCode == 128 ? VtErrorCode.validationFailed : VtErrorCode.internalError,
        message: 'git $verb falhou (exit ${res.exitCode}): '
            '${(res.stderr as String?)?.trim() ?? ''}',
        details: {'exitCode': res.exitCode, 'stderr': res.stderr},
      );

  ToolSuccess<TextOutput> success(ProcessResult res,
          {Map<String, Object?> extra = const {}}) =>
      ToolSuccess(
          data: TextOutput(res.stdout as String, metadata: {
        'exitCode': res.exitCode,
        'stderr': (res.stderr as String?)?.trim(),
        ...extra,
      }));

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) {
    throw VtFailure(
        code: VtErrorCode.internalError, message: 'execute não sobrescrito');
  }
}

// --------------------------------------------------------------- git.status 58
class GitStatusTool extends _GitToolBase {
  @override
  String get id => 'git.status';
  @override
  String get title => 'Git status';
  @override
  String get description => 'Status real do working tree (porcelain v2 + branch).';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  Map<String, Object?> get inputSchema => const {'type': 'object', 'properties': {}};

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final st = await runGit(ctx, ['status', '--porcelain=v2', '--branch']);
      if (st.exitCode != 0) return ToolFailureResult(failureFrom(st, 'status'));
      final br = await runGit(ctx, ['branch', '--show-current']);
      return success(st, extra: {'branch': (br.stdout as String).trim()});
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ------------------------------------------------------------------ git.diff 59
class GitDiffTool extends _GitToolBase {
  @override
  String get id => 'git.diff';
  @override
  String get title => 'Git diff';
  @override
  String get description =>
      'Diff real staged (--cached), unstaged ou entre refs, com paginação por hunks.';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'staged': {'type': 'boolean'},
          'refA': {'type': 'string'},
          'refB': {'type': 'string'},
          'path': {'type': 'string'},
          'hunkCursor': {'type': 'integer'},
          'hunkPageSize': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final args = <String>['diff', '--unified=3'];
      if (input.boolOf('staged')) args.add('--cached');
      if (input.str('refA').isNotEmpty) args.add(input.str('refA'));
      if (input.str('refB').isNotEmpty) args.add(input.str('refB'));
      if (input.str('path').isNotEmpty) {
        args.addAll(['--', input.str('path')]);
      }
      final res = await runGit(ctx, args);
      if (res.exitCode != 0 && res.exitCode != 1) {
        return ToolFailureResult(failureFrom(res, 'diff'));
      }
      final full = res.stdout as String;
      // Splitting em hunks é transformação real do texto retornado pelo git.
      final hunks = full.split(RegExp(r'(?=^@@ )', multiLine: true));
      final pageSize = input.intOrNull('hunkPageSize') ?? 20;
      final start = input.intOrNull('hunkCursor') ?? 0;
      final slice = hunks.skip(start).take(pageSize).join('\n');
      final next = start + pageSize;
      return ToolSuccess(
          data: TextOutput(slice, metadata: {
        'totalHunks': hunks.length,
        'hasMore': next < hunks.length,
        'nextCursor': next < hunks.length ? '$next' : null,
        'additions': _countLines(full, '+'),
        'deletions': _countLines(full, '-'),
      }));
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ------------------------------------------------------------------- git.log 60
class GitLogTool extends _GitToolBase {
  @override
  String get id => 'git.log';
  @override
  String get title => 'Git log';
  @override
  String get description => 'Histórico paginado real via --skip/--max-count.';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer'},
          'skip': {'type': 'integer'},
          'author': {'type': 'string'},
          'pathFilter': {'type': 'string'},
        },
      };

  static const _sep = '\x1e'; // record separator
  static const _field = '\x1f'; // unit separator

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final limit = input.intOrNull('limit') ?? kDefaultPageSizeGitLog;
      final skip = input.intOrNull('skip') ?? 0;
      final args = <String>[
        'log',
        '--pretty=format:%H$_field%an$_field%aI$_field%s$_sep',
        '--max-count=${limit + 1}',
        '--skip=$skip',
      ];
      if (input.str('author').isNotEmpty) args.add('--author=${input.str('author')}');
      if (input.str('pathFilter').isNotEmpty) {
        args.addAll(['--', input.str('pathFilter')]);
      }
      final res = await runGit(ctx, args);
      if (res.exitCode != 0) return ToolFailureResult(failureFrom(res, 'log'));
      final records = (res.stdout as String)
          .split(_sep)
          .where((r) => r.trim().isNotEmpty)
          .toList();
      final hasMore = records.length > limit;
      final page = records.take(limit).map((r) {
        final f = r.split(_field);
        return {
          'sha': f[0],
          'author': f[1],
          'date': f[2],
          'subject': f.length > 3 ? f[3] : '',
        };
      }).toList();
      return ToolSuccess(
          data: TextOutput(jsonEncode(page),
              metadata: {'hasMore': hasMore, 'offset': skip, 'pageSize': limit}));
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ------------------------------------------------------------------ git.show 61
class GitShowTool extends _GitToolBase {
  @override
  String get id => 'git.show';
  @override
  String get title => 'Git show';
  @override
  String get description => 'Mostra commit/tag/blob real (git show).';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['ref'],
        'properties': {'ref': {'type': 'string'}},
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final res = await runGit(ctx, ['show', '--stat', input.str('ref')]);
      if (res.exitCode != 0) return ToolFailureResult(failureFrom(res, 'show'));
      return success(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ---------------------------------------------------------- git.branch_list 62
class GitBranchListTool extends _GitToolBase {
  @override
  String get id => 'git.branch_list';
  @override
  String get title => 'List branches';
  @override
  String get description => 'Lista branches locais e remotas reais.';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {'all': {'type': 'boolean'}},
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final res = await runGit(ctx, [
        'branch',
        if (input.boolOf('all')) '-a',
        '--format=%(refname)%09%(HEAD)%09%(objectname:short)',
      ]);
      if (res.exitCode != 0) return ToolFailureResult(failureFrom(res, 'branch'));
      return success(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// --------------------------------------------------------- git.branch_create 63
class GitBranchCreateTool extends _GitToolBase {
  @override
  String get id => 'git.branch_create';
  @override
  String get title => 'Create branch';
  @override
  String get description => 'Cria branch real (aprovação exigida: local_write).';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['name'],
        'properties': {
          'name': {'type': 'string'},
          'startPoint': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final name = input.str('name');
      if (!RegExp(r'^[\w./-]+$').hasMatch(name)) {
        return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed, message: 'Nome de branch inválido: $name'));
      }
      final args = <String>['branch', name];
      if (input.str('startPoint').isNotEmpty) args.add(input.str('startPoint'));
      final res = await runGit(ctx, args);
      if (res.exitCode != 0) return ToolFailureResult(failureFrom(res, 'branch create'));
      return success(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// --------------------------------------------------------- git.branch_delete 64
class GitBranchDeleteTool extends _GitToolBase {
  @override
  String get id => 'git.branch_delete';
  @override
  String get title => 'Delete branch';
  @override
  String get description =>
      'Delete branch; se não mesclado exige force explícito (proteção real do git).';
  @override
  RiskLevel get risk => RiskLevel.destructive;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.typedConfirmation;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['name'],
        'properties': {
          'name': {'type': 'string'},
          'force': {'type': 'boolean'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final merged = await runGit(ctx, ['branch', '--merged']);
      final isMerged = (merged.stdout as String)
          .split('\n')
          .any((l) => l.trim().replaceAll(RegExp(r'^[* ]+'), '') == input.str('name'));
      if (!isMerged && !input.boolOf('force')) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.validationFailed,
          message:
              'Branch "${input.str('name')}" não está mesclado. Force delete exige confirmação explícita.',
        ));
      }
      final res = await runGit(
          ctx, ['branch', input.boolOf('force') ? '-D' : '-d', input.str('name')]);
      if (res.exitCode != 0) return ToolFailureResult(failureFrom(res, 'branch delete'));
      return success(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// -------------------------------------------------------------- git.checkout 65
class GitCheckoutTool extends _GitToolBase {
  @override
  String get id => 'git.checkout';
  @override
  String get title => 'Checkout';
  @override
  String get description =>
      'Troca branch/commit com checagem real de dirty state antes de mudar.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['target'],
        'properties': {
          'target': {'type': 'string'},
          'create': {'type': 'boolean'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final dirty = await runGit(ctx, ['status', '--porcelain']);
      if ((dirty.stdout as String).trim().isNotEmpty) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Working tree sujo — faça stash ou commit antes do checkout. '
              'Arquivos alterados: ${(dirty.stdout as String).split('\n').length}.',
          details: {'dirtyFiles': (dirty.stdout as String).split('\n')},
        ));
      }
      final args = input.boolOf('create')
          ? ['checkout', '-b', input.str('target')]
          : ['checkout', input.str('target')];
      final res = await runGit(ctx, args);
      if (res.exitCode != 0) return ToolFailureResult(failureFrom(res, 'checkout'));
      return success(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ----------------------------------------------------------------- git.stage 66
class GitStageTool extends _GitToolBase {
  @override
  String get id => 'git.stage';
  @override
  String get title => 'Stage files';
  @override
  String get description => 'Stageia arquivos reais (git add). Stage de hunk usa apply --cached.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['paths'],
        'properties': {
          'paths': {'type': 'array', 'items': {'type': 'string'}},
          'patch': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      if (input.str('patch').isNotEmpty) {
        final proc = await Process.start(
            (await resolveGit(ctx))!, ['-C', repoRoot(ctx), 'apply', '--cached']);
        proc.stdin.write(input.str('patch'));
        await proc.stdin.close();
        final out = await proc.stdout.transform(utf8.decoder).join();
        final err = await proc.stderr.transform(utf8.decoder).join();
        final code = await proc.exitCode;
        if (code != 0) {
          return ToolFailureResult(VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'git apply --cached falhou: $err',
              details: {'stdout': out}));
        }
        return ToolSuccess(data: TextOutput(out, metadata: {'mode': 'hunk-patch'}));
      }
      final paths = input.list('paths');
      if (paths.isEmpty) {
        return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed, message: 'Lista de paths vazia.'));
      }
      final res = await runGit(ctx, ['add', '--', ...paths]);
      if (res.exitCode != 0) return ToolFailureResult(failureFrom(res, 'add'));
      return success(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// --------------------------------------------------------------- git.unstage 67
class GitUnstageTool extends _GitToolBase {
  @override
  String get id => 'git.unstage';
  @override
  String get title => 'Unstage files';
  @override
  String get description => 'Unstage real (git restore --staged).';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['paths'],
        'properties': {
          'paths': {'type': 'array', 'items': {'type': 'string'}}
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final res = await runGit(ctx, ['restore', '--staged', '--', ...input.list('paths')]);
      if (res.exitCode != 0) return ToolFailureResult(failureFrom(res, 'restore --staged'));
      return success(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// --------------------------------------------------------------- git.commit 68
class GitCommitTool extends _GitToolBase {
  @override
  String get id => 'git.commit';
  @override
  String get title => 'Commit staged';
  @override
  String get description =>
      'Commit real das mudanças staged, com aprovação e secret-scan recomendado antes.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['message'],
        'properties': {
          'message': {'type': 'string'},
          'allowEmpty': {'type': 'boolean'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final msg = input.str('message');
      if (msg.trim().isEmpty) {
        return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed, message: 'Mensagem de commit vazia.'));
      }
      final args = <String>['commit', '-m', msg];
      if (input.boolOf('allowEmpty')) args.add('--allow-empty');
      final res = await runGit(ctx, args);
      if (res.exitCode != 0) return ToolFailureResult(failureFrom(res, 'commit'));
      final sha = await runGit(ctx, ['rev-parse', 'HEAD']);
      return success(res, extra: {'commitSha': (sha.stdout as String).trim()});
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ------------------------------------------------------------------ git.push 69
class GitPushTool extends _GitToolBase {
  @override
  String get id => 'git.push';
  @override
  String get title => 'Push';
  @override
  String get description =>
      'Push para remote real. Aprovação EXPLÍCITA obrigatória (external_write).';
  @override
  RiskLevel get risk => RiskLevel.externalWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.explicitApproval;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'remote': {'type': 'string'},
          'branch': {'type': 'string'},
          'setUpstream': {'type': 'boolean'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final args = <String>['push'];
      if (input.boolOf('setUpstream')) args.add('-u');
      if (input.str('remote').isNotEmpty) args.add(input.str('remote'));
      if (input.str('branch').isNotEmpty) args.add(input.str('branch'));
      final res = await runGit(ctx, args);
      if (res.exitCode != 0) return ToolFailureResult(failureFrom(res, 'push'));
      return success(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ------------------------------------------------------------------ git.pull 70
class GitPullTool extends _GitToolBase {
  @override
  String get id => 'git.pull';
  @override
  String get title => 'Pull';
  @override
  String get description => 'Pull real (merge ou rebase); conflitos retornam erro tipado com lista real.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {'rebase': {'type': 'boolean'}},
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final res = await runGit(
          ctx, ['pull', if (input.boolOf('rebase')) '--rebase' else '--no-rebase']);
      if (res.exitCode != 0) {
        final conflicts = await runGit(ctx, ['diff', '--name-only', '--diff-filter=U']);
        final list = (conflicts.stdout as String).split('\n').where((s) => s.isNotEmpty).toList();
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.validationFailed,
          message: list.isEmpty
              ? 'git pull falhou: ${(res.stderr as String?)?.trim()}'
              : 'Conflitos reais de merge em ${list.length} arquivo(s).',
          details: {'conflicts': list},
          recoveryActions: const [
            RecoveryAction(kind: 'open_logs', label: 'Resolver conflitos no Review Mode')
          ],
        ));
      }
      return success(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ------------------------------------------------------------------ git.fetch 71
class GitFetchTool extends _GitToolBase {
  @override
  String get id => 'git.fetch';
  @override
  String get title => 'Fetch';
  @override
  String get description => 'Fetch real sem alterar working tree.';
  @override
  RiskLevel get risk => RiskLevel.networkRead;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {'remote': {'type': 'string'}, 'prune': {'type': 'boolean'}},
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final res = await runGit(ctx, [
        'fetch',
        if (input.boolOf('prune')) '--prune',
        if (input.str('remote').isNotEmpty) input.str('remote'),
      ]);
      if (res.exitCode != 0) return ToolFailureResult(failureFrom(res, 'fetch'));
      return success(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

// ------------------------------------------------------------ git.stash_apply 72
class GitStashTool extends _GitToolBase {
  @override
  String get id => 'git.stash_apply';
  @override
  String get title => 'Stash push/pop/apply';
  @override
  String get description => 'Stash real com handling de conflito no pop/apply.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['action'],
        'properties': {
          'action': {'type': 'string', 'enum': ['push', 'pop', 'apply', 'list']},
          'message': {'type': 'string'},
          'index': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) async {
    try {
      final action = input.str('action');
      final args = switch (action) {
        'push' => ['stash', 'push', '-m', input.str('message').isEmpty ? 'techVT checkpoint' : input.str('message')],
        'pop' => ['stash', 'pop', if (input.intOrNull('index') != null) 'stash@{${input.intOrNull('index')}}'],
        'apply' => ['stash', 'apply', if (input.intOrNull('index') != null) 'stash@{${input.intOrNull('index')}}'],
        'list' => ['stash', 'list'],
        _ => throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Ação de stash desconhecida: "$action" (use push|pop|apply|list).'),
      };
      final res = await runGit(ctx, args.whereType<String>().toList());
      if (res.exitCode != 0) {
        final conflicts = await runGit(ctx, ['diff', '--name-only', '--diff-filter=U']);
        final list = (conflicts.stdout as String).split('\n').where((s) => s.isNotEmpty).toList();
        if (list.isNotEmpty) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Stash aplicado com conflitos reais em ${list.length} arquivo(s).',
            details: {'conflicts': list},
          ));
        }
        return ToolFailureResult(failureFrom(res, 'stash $action'));
      }
      return success(res);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}
