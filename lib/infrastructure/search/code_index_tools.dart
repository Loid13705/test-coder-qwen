/// Tools de índice de código (spec catálogo: codeIndex).
///
/// Exponem o [CodeIndexStore] (SQLite + varredura real do FS) ao tool loop:
/// scan incremental, busca de símbolos com ranking e estatísticas. Risco:
/// leitura automática; scan escreve no DB local (local_write); purge é
/// destrutivo. Nenhuma simulação — tudo via FFI nativo e filesystem real.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import 'code_index_store.dart';

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

abstract class _CodeIndexTool extends VtTool<MapToolInput, TextOutput> {
  _CodeIndexTool(this.index);
  final CodeIndexStore index;

  @override
  Map<String, Object?> get outputSchema => const {
        'type': 'object',
        'properties': <String, Object?>{},
      };
  @override
  RetryPolicy get retryPolicy => const RetryPolicy();
  @override
  List<String> get capabilities => const ['sqlite', 'filesystem'];
  @override
  Duration get timeout => const Duration(seconds: 30);
  @override
  ToolCategory get category => ToolCategory.codeIndex;
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

  /// Workspace efetivo: input explícito > primeira raiz do contexto.
  String workspaceOf(ToolContext ctx, MapToolInput input) {
    final explicit = input.str('workspace');
    if (explicit.isNotEmpty) return explicit;
    if (ctx.workspaceRoots.isEmpty) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Nenhum workspace aberto para escopar o índice.',
      );
    }
    return ctx.workspaceRoots.first;
  }
}

// ------------------------------------------------------- code_index.scan
class CodeIndexScanTool extends _CodeIndexTool {
  CodeIndexScanTool(super.index);

  @override
  String get id => 'code_index.scan';
  @override
  String get title => 'Scan workspace index';
  @override
  String get description =>
      'Varredura incremental do workspace: indexa símbolos de arquivos .dart '
      'novos/alterados (SHA-256 + mtime) e remove documentos órfãos. '
      'Retorna estatísticas reais da operação.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  Duration get timeout => const Duration(minutes: 5);
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
        final root = workspaceOf(ctx, input);
        if (!Directory(root).existsSync()) {
          throw VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Workspace inexistente: $root',
          );
        }
        final stats = index.scanWorkspace(workspaceId: root, root: root);
        return ToolSuccess(
            data: TextOutput(jsonEncode(stats.toJson()),
                metadata: {'workspace': root}));
      });
}

// ------------------------------------------------------ code_index.search
class CodeIndexSearchTool extends _CodeIndexTool {
  CodeIndexSearchTool(super.index);

  @override
  String get id => 'code_index.search';
  @override
  String get title => 'Search code symbols';
  @override
  String get description =>
      'Busca lexical ponderada no índice de símbolos do workspace '
      '(nome exato > prefixo > substring > assinatura), paginada.';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['query'],
        'properties': {
          'query': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': [
              'class', 'mixin', 'enum', 'extension', 'typedef',
              'function', 'field'
            ]
          },
          'limit': {'type': 'integer'},
          'cursor': {'type': 'string'},
          'workspace': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final ws = workspaceOf(ctx, input);
        final query = input.str('query');
        if (query.trim().isEmpty) {
          throw VtFailure(
              code: VtErrorCode.validationFailed, message: 'Query vazia.');
        }
        final page = index.searchSymbols(
          workspaceId: ws,
          query: query,
          kind: input.values['kind'] as String?,
          pageSize: input.intOrNull('limit') ?? 25,
          offset: int.tryParse(input.str('cursor')) ?? 0,
        );
        return ToolSuccess(
            data: TextOutput(
                jsonEncode([for (final h in page.items) h.toJson()]),
                metadata: {
                  'hasMore': page.hasMore,
                  'nextCursor': page.nextCursor,
                  'total': page.totalEstimate,
                }));
      });
}

// ------------------------------------------------------- code_index.stats
class CodeIndexStatsTool extends _CodeIndexTool {
  CodeIndexStatsTool(super.index);

  @override
  String get id => 'code_index.stats';
  @override
  String get title => 'Code index statistics';
  @override
  String get description =>
      'Estatísticas reais do índice do workspace: documentos, símbolos e '
      'distribuição por tipo.';
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
        return ToolSuccess(
            data: TextOutput(jsonEncode(index.stats(ws)),
                metadata: {'workspace': ws}));
      });
}

// ------------------------------------------------------- code_index.purge
class CodeIndexPurgeTool extends _CodeIndexTool {
  CodeIndexPurgeTool(super.index);

  @override
  String get id => 'code_index.purge';
  @override
  String get title => 'Purge code index';
  @override
  String get description =>
      'Remove todo o índice de um workspace (reindex limpo no próximo scan).';
  @override
  RiskLevel get risk => RiskLevel.destructive;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.explicitApproval;

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
        final removed = index.purge(ws);
        return ToolSuccess(
            data: TextOutput(jsonEncode({'documentsRemoved': removed}),
                metadata: {'workspace': ws}));
      });
}
