/// Tools de memória de longo prazo (spec catálogo: memory.*).
///
/// Expõem o [MemoryStore] SQLite real ao tool loop do ChatService. Risco:
/// leitura automática, escrita exige aprovação (local_write), delete é
/// destrutivo. Nenhuma simulação — tudo persiste via FFI nativo.
library;

import 'dart:async';
import 'dart:convert';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import 'memory_store.dart';

Future<ToolResult<O>> _guard<O extends ToolOutput>(
    VtTool<dynamic, O> tool, Future<ToolResult<O>> Function() body) async {
  try {
    return await body().timeout(tool.timeout);
  } on TimeoutException {
    return ToolFailureResult<O>(VtFailure.timeout(tool.timeout));
  } on VtFailure catch (f) {
    return ToolFailureResult<O>(f);
  } on FormatException catch (e) {
    return ToolFailureResult<O>(VtFailure(
        code: VtErrorCode.validationFailed, message: e.message));
  }
}

abstract class _MemoryTool extends VtTool<MapToolInput, TextOutput> {
  _MemoryTool(this.store);
  final MemoryStore store;

  static const _schema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Map<String, Object?> get outputSchema => _schema;
  @override
  RetryPolicy get retryPolicy => const RetryPolicy();
  @override
  List<String> get capabilities => const ['sqlite'];
  @override
  Duration get timeout => const Duration(seconds: 10);
  @override
  ToolCategory get category => ToolCategory.memory;
  @override
  bool get isIdempotent => true;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  RiskLevel get risk => RiskLevel.readOnly;

  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async =>
      const HealthOk('libsqlite3 carregada');

  /// Workspace raiz efetivo (multi-root): usa a primeira raiz como escopo
  /// padrão da memória; chamador pode sobrepor via input `workspace`.
  String workspaceOf(ToolContext ctx, MapToolInput input) {
    final explicit = input.str('workspace');
    if (explicit.isNotEmpty) return explicit;
    if (ctx.workspaceRoots.isEmpty) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Nenhum workspace aberto para escopar a memória.',
      );
    }
    return ctx.workspaceRoots.first;
  }

  String encodePage(List<MemoryRecord> recs) => jsonEncode([
        for (final r in recs) r.toJson(),
      ]);
}

// ------------------------------------------------------------- memory.search
class MemorySearchTool extends _MemoryTool {
  MemorySearchTool(super.store);

  @override
  String get id => 'memory.search';
  @override
  String get title => 'Search memories';
  @override
  String get description =>
      'Busca lexical ponderada nas memórias do workspace, com ranking por '
      'relevância + reforço de recall. Retorna página de registros JSON.';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['query'],
        'properties': {
          'query': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': ['fact', 'preference', 'procedure', 'decision']
          },
          'limit': {'type': 'integer'},
          'workspace': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final page = store.search(
          workspaceId: workspaceOf(ctx, input),
          query: input.str('query'),
          kind: input.values['kind'] as String?,
          pageSize: input.intOrNull('limit') ?? 10,
        );
        return ToolSuccess(
          data: TextOutput(encodePage(page.items)),
          usage: {
            'totalMatched': page.totalEstimate,
            'returned': page.items.length,
          },
          citations: [
            for (final r in page.items)
              Citation(
                sourceType: 'memory',
                sourceRef: 'memory://${r.id}',
                label: r.title,
              ),
          ],
        );
      });
}

// --------------------------------------------------------------- memory.recall
class MemoryRecallTool extends _MemoryTool {
  MemoryRecallTool(super.store);

  @override
  String get id => 'memory.recall';
  @override
  String get title => 'Recall memory by id';
  @override
  String get description =>
      'Recupera uma memória inteira pelo id e reforça seu peso de recall.';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['id'],
        'properties': {
          'id': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final id = input.intOrNull('id');
        if (id == null) {
          throw VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'id deve ser inteiro.',
          );
        }
        final rec = store.get(id);
        if (rec == null) {
          throw VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Memória $id não existe.',
          );
        }
        // Reforço de recall: +peso e timestamp apenas neste registro.
        store.recall(id);
        final reinforced = store.get(id) ?? rec;
        return ToolSuccess(
          data: TextOutput(jsonEncode(reinforced.toJson())),
          citations: [
            Citation(
                sourceType: 'memory',
                sourceRef: 'memory://${reinforced.id}',
                label: reinforced.title),
          ],
        );
      });
}

// ---------------------------------------------------------------- memory.stats
class MemoryStatsTool extends _MemoryTool {
  MemoryStatsTool(super.store);

  @override
  String get id => 'memory.stats';
  @override
  String get title => 'Memory stats';
  @override
  String get description =>
      'Contagem e peso médio das memórias do workspace por kind.';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'workspace': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final ws = workspaceOf(ctx, input);
        // O driver FFI retorna todas as colunas como texto (sqlite3_column_text);
        // converte count/avg_weight para números no JSON exposto ao modelo.
        final rows = [
          for (final r in store.stats(workspaceId: ws))
            {
              ...r,
              'count': int.tryParse('${r['count']}') ?? 0,
              'avg_weight': double.tryParse('${r['avg_weight']}'),
            },
        ];
        return ToolSuccess(data: TextOutput(jsonEncode(rows)));
      });
}

// ---------------------------------------------------------------- memory.save
class MemorySaveTool extends _MemoryTool {
  MemorySaveTool(super.store);

  @override
  String get id => 'memory.save';
  @override
  String get title => 'Save memory';
  @override
  String get description =>
      'Cria ou atualiza uma memória persistente (fact/preference/procedure/'
      'decision) no workspace. Escrita local: exige aprovação.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['title', 'body'],
        'properties': {
          'id': {'type': 'integer'},
          'kind': {
            'type': 'string',
            'enum': ['fact', 'preference', 'procedure', 'decision']
          },
          'title': {'type': 'string'},
          'body': {'type': 'string'},
          'tags': {'type': 'array', 'items': {'type': 'string'}},
          'weight': {'type': 'number'},
          'workspace': {'type': 'string'},
        },
      };

  static const _kinds = {'fact', 'preference', 'procedure', 'decision'};

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final kind = input.values['kind'] as String? ?? 'fact';
        if (!_kinds.contains(kind)) {
          throw VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'kind inválido "$kind" (esperado: $_kinds).',
          );
        }
        final rec = store.upsert(
          id: input.intOrNull('id'),
          workspaceId: workspaceOf(ctx, input),
          kind: kind,
          title: input.str('title'),
          body: input.str('body'),
          tags: input.list('tags'),
          weight: (input.values['weight'] as num?)?.toDouble() ?? 1.0,
        );
        return ToolSuccess(
          data: TextOutput(jsonEncode(rec.toJson())),
          citations: [
            Citation(
                sourceType: 'memory',
                sourceRef: 'memory://${rec.id}',
                label: rec.title),
          ],
        );
      });
}

// -------------------------------------------------------------- memory.forget
class MemoryForgetTool extends _MemoryTool {
  MemoryForgetTool(super.store);

  @override
  String get id => 'memory.forget';
  @override
  String get title => 'Delete memory';
  @override
  String get description =>
      'Remove permanentemente uma memória pelo id. Destrutivo: aprovação '
      'explícita obrigatória.';
  @override
  RiskLevel get risk => RiskLevel.destructive;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.explicitApproval;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['id'],
        'properties': {
          'id': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final id = input.intOrNull('id');
        if (id == null || !store.delete(id)) {
          throw VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Memória $id não existia.',
          );
        }
        return const ToolSuccess(data: TextOutput('{"deleted":true}'));
      });
}
