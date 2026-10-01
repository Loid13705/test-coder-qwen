/// Tools de busca semântica/híbrida sobre o índice vetorial local.
///
/// Regra da casa: sem embeddings reais configurados, as tools NÃO fingem —
/// `code_index.embed` falha com providerNotConfigured + ação de recovery, e
/// `code_index.search_semantic` degrada para lexical puro reportando
/// `mode: "lexical"` na resposta (honesto sobre o que rodou).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import '../provider/provider_contract.dart';
import 'code_index_store.dart';
import 'vector_index_store.dart';

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

abstract class _VectorTool extends VtTool<MapToolInput, TextOutput> {
  _VectorTool(this.vectors, this.embedderResolver);

  final VectorIndexStore vectors;

  /// Resolve o embedding provider efetivo do momento (pode ser null quando o
  /// usuário ainda não configurou credenciais — nunca se presume um).
  final EmbeddingProvider? Function() embedderResolver;

  @override
  Map<String, Object?> get outputSchema => const {
        'type': 'object',
        'properties': <String, Object?>{},
      };
  @override
  RetryPolicy get retryPolicy => const RetryPolicy();
  @override
  List<String> get capabilities => const ['sqlite', 'network'];
  @override
  Duration get timeout => const Duration(minutes: 2);
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
  Future<ToolHealth> health(ToolContext ctx) async {
    final e = embedderResolver();
    if (e == null) {
      return const HealthDegraded(
          'sem provider de embeddings configurado — busca degrada para lexical');
    }
    final dims = e.embeddingCapabilities.dimensions;
    return HealthOk(dims != null
        ? 'embeddings ok (${e.embeddingModelId}, ${dims}d)'
        : 'provider "${e.embeddingModelId}" aguardando verificação de dimensões');
  }

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

  EmbeddingProvider requireEmbedder() {
    final e = embedderResolver();
    if (e == null) {
      throw VtFailure(
        code: VtErrorCode.providerNotConfigured,
        message: 'Busca semântica exige um provider de embeddings real '
            '(ex.: OpenAI text-embedding-3-small ou Ollama nomic-embed-text).',
        setupUri: 'techvt://settings/providers',
        recoveryActions: const [
          RecoveryAction(
              kind: 'configure_provider',
              label: 'Configurar provider de embeddings em Settings → AI'),
        ],
      );
    }
    return e;
  }
}

// --------------------------------------------------- code_index.embed
class CodeIndexEmbedTool extends _VectorTool {
  CodeIndexEmbedTool(super.vectors, super.embedderResolver);

  @override
  String get id => 'code_index.embed';
  @override
  String get title => 'Embed workspace chunks';
  @override
  String get description =>
      'Gera embeddings REAIS (via /embeddings do provider configurado) para os '
      'chunks dos documentos alterados no índice do workspace. Incremental: '
      'só re-embedda arquivos cujo conteúdo mudou. Requer scan prévio.';
  @override
  RiskLevel get risk => RiskLevel.networkRead;
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
        final stats = await vectors.embedWorkspace(
          workspaceId: root,
          embedder: requireEmbedder(),
        );
        return ToolSuccess(
            data: TextOutput(jsonEncode(stats), metadata: {'workspace': root}));
      });
}

// --------------------------------------------- code_index.search_semantic
class CodeIndexSemanticSearchTool extends _VectorTool {
  CodeIndexSemanticSearchTool(super.vectors, super.embedderResolver);

  @override
  String get id => 'code_index.search_semantic';
  @override
  String get title => 'Hybrid code search';
  @override
  String get description =>
      'Busca híbrida por intenção/descrição ("onde valido tokens de sessão"): '
      'fusão de similaridade vetorial (cosseno) + ranking léxico de símbolos. '
      'Sem vetos indexados ou sem provider, roda lexical puro e reporta '
      'mode:"lexical" na resposta.';
  @override
  Duration get timeout => const Duration(seconds: 60);
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['query'],
        'properties': {
          'query': {'type': 'string'},
          'workspace': {'type': 'string'},
          'kind': {'type': 'string'},
          'top_k': {'type': 'integer', 'minimum': 1, 'maximum': 50},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final root = workspaceOf(ctx, input);
        final query = input.str('query').trim();
        if (query.isEmpty) {
          throw VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Parâmetro "query" é obrigatório e não pode ser vazio.',
          );
        }
        // Sem provider OU sem vetores indexados → lexical puro honesto.
        final embedder = embedderResolver();
        final useVectors = embedder != null && vectors.hasVectors;
        final result = await vectors.hybridSearch(
          workspaceId: root,
          query: query,
          embedder: useVectors ? embedder : null,
          kind: input.str('kind').isEmpty ? null : input.str('kind'),
          topK: (input.intOrNull('top_k') ?? 15).clamp(1, 50),
        );
        return ToolSuccess(
            data: TextOutput(jsonEncode(result), metadata: {'workspace': root}));
      });
}

// -------------------------------------------------- code_index.vector_stats
class CodeIndexVectorStatsTool extends _VectorTool {
  CodeIndexVectorStatsTool(super.vectors, super.embedderResolver);

  @override
  String get id => 'code_index.vector_stats';
  @override
  String get title => 'Vector index stats';
  @override
  String get description =>
      'Estatísticas reais do índice vetorial: chunks armazenados, modelo de '
      'embedding efetivo, se está pronto para busca semântica e por quê.';
  @override
  Duration get timeout => const Duration(seconds: 10);
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': <String, Object?>{},
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final e = embedderResolver();
        return ToolSuccess(data: TextOutput(jsonEncode({
          'chunks': vectors.chunkCount,
          'indexedModel': vectors.indexedModel,
          'configuredEmbedder': e?.embeddingModelId,
          'verifiedDimensions': e?.embeddingCapabilities.dimensions,
          'semanticReady':
              e != null && vectors.hasVectors && vectors.indexedModel == e.embeddingModelId,
        })));
      });
}
