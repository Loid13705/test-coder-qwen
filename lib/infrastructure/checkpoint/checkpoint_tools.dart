/// Tools de checkpoint (spec catálogo: ToolCategory.checkpoint).
///
/// Expõem o [CheckpointStore] (snapshot em disco + SQLite) ao tool loop:
/// - `checkpoint.create` — snapshot pré-write real (local_write, reviewEach);
/// - `checkpoint.list`   — histórico por workspace (read-only, auto);
/// - `checkpoint.restore`— rollback com trava de drift; destrutivo por
///   definição (destructive, explicitApproval) e NUNCA idempotente.
///
/// Nenhuma simulação: bytes copiados de verdade, hashes verificados de verdade,
/// falha tipada quando o estado do disco diverge do registrado.
library;

import 'dart:async';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import '../process/process_utils.dart';
import 'checkpoint_store.dart';

Future<ToolResult<O>> _guard<O extends ToolOutput>(
    VtTool<dynamic, O> tool, Future<ToolResult<O>> Function() body) async {
  try {
    return await body().timeout(tool.timeout);
  } on TimeoutException {
    return ToolFailureResult<O>(VtFailure.timeout(tool.timeout));
  } on VtFailure catch (f) {
    return ToolFailureResult<O>(f);
  }
}

abstract class _CheckpointTool extends VtTool<MapToolInput, TextOutput> {
  _CheckpointTool(this.store);
  final CheckpointStore store;

  @override
  ToolCategory get category => ToolCategory.checkpoint;
  @override
  List<String> get capabilities => const ['filesystem', 'sqlite'];
  @override
  Duration get timeout => const Duration(seconds: 30);
  @override
  RetryPolicy get retryPolicy => const RetryPolicy();
  @override
  Map<String, Object?> get outputSchema => const {'type': 'object'};

  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async => const HealthOk(
      'checkpoint store pronto (SQLite + pasta de snapshots)');

  /// Workspace efetivo para escopo do registro (primeira raiz ou input).
  String workspaceOf(ToolContext ctx, MapToolInput input) {
    final explicit = input.str('workspace');
    if (explicit.isNotEmpty) return normalizeSlashes(explicit);
    if (ctx.workspaceRoots.isEmpty) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Nenhum workspace aberto para escopar o checkpoint.',
      );
    }
    return normalizeSlashes(ctx.workspaceRoots.first);
  }

  /// Caminho absoluto validado pelo sandbox de escrita/leitura real.
  Future<String> resolvePath(
      ToolContext ctx, String rawPath, bool writable) async {
    if (rawPath.isEmpty) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Parâmetro "path" é obrigatório.',
      );
    }
    return writable
        ? ctx.sandbox.resolveWritable(rawPath, ctx)
        : ctx.sandbox.resolveReadable(rawPath, ctx);
  }
}

// --------------------------------------------------------- checkpoint.create
class CheckpointCreateTool extends _CheckpointTool {
  CheckpointCreateTool(CheckpointStore store) : super(store);

  @override
  String get id => 'checkpoint.create';
  @override
  String get title => 'Criar checkpoint';
  @override
  String get description =>
      'Snapshot real dos bytes atuais de um arquivo ANTES de uma escrita '
      'destrutiva. Grava cópia na pasta de dados + metadados com SHA-256 no '
      'banco local. Use antes de fs.write_text/fs.delete em arquivos que já '
      'existem.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => false; // cada chamada gera um snapshot novo
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path'],
        'properties': {
          'path': {'type': 'string', 'description': 'Arquivo alvo (abs ou relativo à raiz)'},
          'reason': {'type': 'string', 'description': 'Por que este snapshot existe'},
          'workspace': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) => _guard(this, () async {
    final ws = workspaceOf(ctx, input);
    final abs = await resolvePath(ctx, input.str('path'), true);
    final rec = await store.create(
      workspaceRoot: ws,
      absPath: abs,
      reason: input.str('reason'),
    );
    return ToolSuccess(
      data: TextOutput(
        'Checkpoint ${rec.id}\n'
        'arquivo: ${rec.relPath}\n'
        'existia antes: ${rec.existedBefore}\n'
        'sha256(before): ${rec.sha256Before ?? "(inexistente)"}',
        metadata: {...rec.toJson(), 'snapshotPath': rec.snapshotPath},
      ),
    );
  });
}

// ----------------------------------------------------------- checkpoint.list
class CheckpointListTool extends _CheckpointTool {
  CheckpointListTool(CheckpointStore store) : super(store);

  @override
  String get id => 'checkpoint.list';
  @override
  String get title => 'Listar checkpoints';
  @override
  String get description =>
      'Histórico de checkpoints do workspace (mais recentes primeiro), com '
      'hash e motivo registrados. Somente leitura.';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'workspace': {'type': 'string'},
          'path': {
            'type': 'string',
            'description': 'Filtra por caminho relativo exato'
          },
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) => _guard(this, () async {
    final ws = workspaceOf(ctx, input);
    final limit = (input.intOrNull('limit') ?? 50).clamp(1, 200);
    final filterRel = input.str('path').isEmpty
        ? null
        : relativePath(normalizeSlashes(await resolvePath(ctx, input.str('path'), false)), ws);
    final records = store.list(workspaceRoot: ws, limit: limit).where((r) {
      if (filterRel == null) return true;
      return normalizeSlashes(r.relPath) == normalizeSlashes(filterRel);
    }).toList(growable: false);

    if (records.isEmpty) {
      return const ToolSuccess(
          data: TextOutput('Nenhum checkpoint registrado para este workspace.'));
    }
    final lines = records
        .map((r) => '${r.id}  ${r.createdAt}  ${r.relPath}'
            '${r.existedBefore ? "" : "  (criado novo)"}'
            '${r.reason.isEmpty ? "" : "  — ${r.reason}"}')
        .join('\n');
    return ToolSuccess(
      data: TextOutput(lines, metadata: {
        'count': records.length,
        'checkpoints': records.map((r) => r.toJson()).toList(),
      }),
    );
  });
}

// -------------------------------------------------------- checkpoint.restore
class CheckpointRestoreTool extends _CheckpointTool {
  CheckpointRestoreTool(CheckpointStore store) : super(store);

  @override
  String get id => 'checkpoint.restore';
  @override
  String get title => 'Restaurar checkpoint';
  @override
  String get description =>
      'Rollback REAL: restaura os bytes do snapshot (ou remove o arquivo se '
      'ele não existia antes). Se o arquivo mudou desde o checkpoint, exige '
      'force=true — sem ele a operação falha com erro tipado para proteger '
      'edições posteriores.';
  @override
  RiskLevel get risk => RiskLevel.destructive;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.explicitApproval;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['id'],
        'properties': {
          'id': {'type': 'string', 'description': 'id retornado por checkpoint.create/list'},
          'force': {
            'type': 'boolean',
            'description':
                'Restaurar mesmo com drift (descarta edições feitas após o checkpoint)'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) => _guard(this, () async {
    final id = input.str('id');
    if (id.isEmpty) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Parâmetro "id" é obrigatório.',
      );
    }
    final outcome = await store.restore(id, force: input.boolOf('force'));
    final msg = outcome.removedFile
        ? 'Arquivo "${outcome.restored.relPath}" não existia antes do write; '
            'removido (rollback completo).'
        : 'Arquivo "${outcome.restored.relPath}" restaurado para o estado '
            'pré-write (sha256 ${outcome.restored.sha256Before}).';
    return ToolSuccess(
      data: TextOutput(
        '$msg${outcome.wasDrifted ? "\nATENÇÃO: houve drift resolvido com force — edições posteriores foram descartadas." : ""}',
        metadata: {
          'checkpoint': outcome.restored.id,
          'removedFile': outcome.removedFile,
          'wasDrifted': outcome.wasDrifted,
        },
      ),
    );
  });
}
