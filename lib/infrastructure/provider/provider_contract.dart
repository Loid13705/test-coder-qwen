/// Contrato real de AI providers + catálogo de modelos com capacidades.
///
/// Não existe provider "default que finge conexão": sem configuração, o estado
/// retornado é `unconfigured`/`api_key_missing` com ação concreta.
library;

import '../../domain/errors/vt_failure.dart';

enum ProviderStatus { unconfigured, offline, ok, rateLimited, error }

enum ModelSource { remote, local }

class ModelCapabilities {
  const ModelCapabilities({
    this.tools = false,
    this.vision = false,
    this.streaming = false,
    this.jsonMode = false,
    this.longContext = false,
    this.fast = false,
    this.cheap = false,
  });

  final bool tools;
  final bool vision;
  final bool streaming;
  final bool jsonMode;
  final bool longContext;
  final bool fast;
  final bool cheap;

  Map<String, Object?> toJson() => {
        'tools': tools,
        'vision': vision,
        'streaming': streaming,
        'jsonMode': jsonMode,
        'longContext': longContext,
        'fast': fast,
        'cheap': cheap,
      };
}

/// Preço por 1M tokens — só preenchido quando a cost table tem preço REAL
/// conhecido (metadata pública do provider). `null` = custo desconhecido.
class ModelPricing {
  const ModelPricing({this.inputPer1MUsd, this.outputPer1MUsd});
  final double? inputPer1MUsd;
  final double? outputPer1MUsd;

  bool get known => inputPer1MUsd != null && outputPer1MUsd != null;

  double? estimateCostUsd(int promptTokens, int completionTokens) => known
      ? (promptTokens / 1e6) * inputPer1MUsd! +
          (completionTokens / 1e6) * outputPer1MUsd!
      : null;
}

class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.providerId,
    required this.displayName,
    required this.contextWindow,
    required this.capabilities,
    this.pricing = const ModelPricing(),
    this.source = ModelSource.remote,
    this.enabled = true,
  });

  final String id;
  final String providerId;
  final String displayName;
  final int contextWindow;
  final ModelCapabilities capabilities;
  final ModelPricing pricing;
  final ModelSource source;
  final bool enabled;

  Map<String, Object?> toJson() => {
        'id': id,
        'providerId': providerId,
        'displayName': displayName,
        'contextWindow': contextWindow,
        'capabilities': capabilities.toJson(),
        'inputPer1MUsd': pricing.inputPer1MUsd,
        'outputPer1MUsd': pricing.outputPer1MUsd,
        'source': source.name,
        'enabled': enabled,
      };
}

/// Catálogo estático de capacidades/preços CONHECIDOS publicamente pelos
/// providers (OpenAI, Anthropic, Google, DeepSeek, Ollama local).
/// Nada aqui é inventado: preços divergentes devem ser corrigidos na cost
/// table editável em Settings → Models (settings.get('models.costTable')).
const kKnownModels = <ModelInfo>[
  ModelInfo(
    id: 'gpt-4o',
    providerId: 'openai',
    displayName: 'GPT-4o',
    contextWindow: 128000,
    capabilities: ModelCapabilities(
        tools: true, vision: true, streaming: true, jsonMode: true),
    pricing: ModelPricing(inputPer1MUsd: 2.50, outputPer1MUsd: 10.00),
  ),
  ModelInfo(
    id: 'gpt-4o-mini',
    providerId: 'openai',
    displayName: 'GPT-4o mini',
    contextWindow: 128000,
    capabilities: ModelCapabilities(
        tools: true,
        vision: true,
        streaming: true,
        jsonMode: true,
        fast: true,
        cheap: true),
    pricing: ModelPricing(inputPer1MUsd: 0.15, outputPer1MUsd: 0.60),
  ),
  ModelInfo(
    id: 'o3-mini',
    providerId: 'openai',
    displayName: 'o3-mini',
    contextWindow: 200000,
    capabilities:
        ModelCapabilities(tools: true, streaming: true, jsonMode: true),
    pricing: ModelPricing(inputPer1MUsd: 1.10, outputPer1MUsd: 4.40),
  ),
  ModelInfo(
    id: 'claude-sonnet-4-20250514',
    providerId: 'anthropic',
    displayName: 'Claude Sonnet 4',
    contextWindow: 200000,
    capabilities: ModelCapabilities(
        tools: true, vision: true, streaming: true, longContext: true),
    pricing: ModelPricing(inputPer1MUsd: 3.00, outputPer1MUsd: 15.00),
  ),
  ModelInfo(
    id: 'claude-3-5-haiku-20241022',
    providerId: 'anthropic',
    displayName: 'Claude Haiku 3.5',
    contextWindow: 200000,
    capabilities: ModelCapabilities(
        tools: true, vision: true, streaming: true, fast: true, cheap: true),
    pricing: ModelPricing(inputPer1MUsd: 0.80, outputPer1MUsd: 4.00),
  ),
  ModelInfo(
    id: 'gemini-2.5-pro',
    providerId: 'google',
    displayName: 'Gemini 2.5 Pro',
    contextWindow: 1048576,
    capabilities: ModelCapabilities(
        tools: true,
        vision: true,
        streaming: true,
        jsonMode: true,
        longContext: true),
    pricing: ModelPricing(inputPer1MUsd: 1.25, outputPer1MUsd: 10.00),
  ),
  ModelInfo(
    id: 'gemini-2.5-flash',
    providerId: 'google',
    displayName: 'Gemini 2.5 Flash',
    contextWindow: 1048576,
    capabilities: ModelCapabilities(
        tools: true,
        vision: true,
        streaming: true,
        jsonMode: true,
        longContext: true,
        fast: true,
        cheap: true),
    pricing: ModelPricing(inputPer1MUsd: 0.30, outputPer1MUsd: 2.50),
  ),
  ModelInfo(
    id: 'deepseek-chat',
    providerId: 'deepseek',
    displayName: 'DeepSeek Chat (V3)',
    contextWindow: 64000,
    capabilities: ModelCapabilities(
        tools: true, streaming: true, jsonMode: true, fast: true, cheap: true),
    pricing: ModelPricing(inputPer1MUsd: 0.27, outputPer1MUsd: 1.10),
  ),
  // Modelos locais via Ollama: sem preço (não há custo por token); capacidades
  // conservadoras até detecção real pelo model discovery do provider local.
  ModelInfo(
    id: 'qwen2.5-coder:7b',
    providerId: 'ollama',
    displayName: 'Qwen2.5 Coder 7B (local)',
    contextWindow: 32768,
    capabilities: ModelCapabilities(streaming: true),
    source: ModelSource.local,
  ),
  ModelInfo(
    id: 'llama3.1:8b',
    providerId: 'ollama',
    displayName: 'Llama 3.1 8B (local)',
    contextWindow: 128000,
    capabilities: ModelCapabilities(streaming: true),
    source: ModelSource.local,
  ),
];

/// Chunk de streaming real vindo do provider (nunca gerado localmente).
sealed class StreamChunk {
  const StreamChunk();
}

class DeltaChunk extends StreamChunk {
  const DeltaChunk(this.text);
  final String text;
}

class ToolCallStartChunk extends StreamChunk {
  const ToolCallStartChunk(
      {required this.callId,
      required this.toolId,
      required this.argsJson,
      this.providerToolUseId});
  final String callId;
  final String toolId;
  final String argsJson;

  /// Id nativo do provider para o tool_use (Anthropic exige `tool_use_id` no
  /// tool_result e ignora nosso callId interno).
  final String? providerToolUseId;
}

class UsageChunk extends StreamChunk {
  const UsageChunk(
      {required this.promptTokens, required this.completionTokens});
  final int promptTokens;
  final int completionTokens;
}

class DoneChunk extends StreamChunk {
  const DoneChunk([this.finishReason]);
  final String? finishReason;
}

class ErrorChunk extends StreamChunk {
  const ErrorChunk(this.failure);
  final VtFailure failure;
}

/// Handle de uma requisição de streaming em andamento. `stop()` CANCELA a
/// requisição HTTP real (aborta a conexão) — não é "parar de ouvir": o
/// servidor recebe o cancelamento e a mensagem parcial preservada é a que
/// realmente chegou antes do abort.
class StreamHandle {
  StreamHandle(this._cancel);

  /// Handle sem ação de cancelamento pendente (ex.: stream já finalizado).
  factory StreamHandle.noop() => StreamHandle(() async {});
  final Future<void> Function() _cancel;
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  Future<void> stop() async {
    if (_cancelled) return;
    _cancelled = true;
    await _cancel();
  }
}

class ChatRequestMessage {
  const ChatRequestMessage({
    required this.role,
    required this.content,
    this.toolCallId,
    this.toolName,
  });
  final String role; // system|user|assistant|tool

  /// Para `role == 'tool'`: id do tool call que este resultado responde.
  final String? toolCallId;

  /// Nome da tool (wire Anthropic usa `name` no tool_result).
  final String? toolName;
  final String content;
}

class ChatRequestOptions {
  const ChatRequestOptions({
    this.temperature,
    this.topP,
    this.maxTokens,
    this.stopSequences = const [],
    this.seed,
    this.jsonMode = false,
    this.allowedToolIds = const [],
  });

  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final List<String> stopSequences;
  final int? seed;
  final bool jsonMode;
  final List<String> allowedToolIds;
}

/// Contrato de provider. Implementações reais fazem HTTP ao endpoint do
/// provedor configurado; sem key/base URL retornam falha tipada imediata.
abstract class LlmProvider {
  String get id; // openai | anthropic | google | deepseek | ollama | custom
  String get displayName;
  List<ModelInfo> get models;

  /// Health check REAL: testa credencial + alcance do endpoint informado.
  Future<ProviderStatus> healthCheck();

  /// Lista modelos do account/instância no momento (model discovery real).
  Future<List<ModelInfo>> discoverModels();

  /// Completions simples (ghost text). Retorna texto vazio se indisponível,
  /// mas NUNCA texto fabricado — falhas viram VtFailure.
  Future<ToolCompletionOutcome> completeForCompletion(
      {required String modelId,
      required String prefix,
      required String suffix});

  /// Chat/streaming real. Quando o modelo não suporta streaming, a implementação
  /// emite um único DeltaChunk com a resposta real + DoneChunk.
  Stream<StreamChunk> streamChat({
    required String modelId,
    required List<ChatRequestMessage> messages,
    required ChatRequestOptions options,
    required List<Map<String, Object?>> toolSchemas,
    void Function(StreamHandle handle)? onHandle,
  });
}

/// Uso de tokens/custo medidos REALMENTE numa interação com o provider.
class TokenUsage {
  const TokenUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cachedPromptTokens = 0,
  });

  final int promptTokens;
  final int completionTokens;
  final int cachedPromptTokens;

  int get total => promptTokens + completionTokens;

  TokenUsage merge(UsageChunk c) => TokenUsage(
        promptTokens: c.promptTokens > 0 ? c.promptTokens : promptTokens,
        completionTokens:
            c.completionTokens > 0 ? c.completionTokens : completionTokens,
        cachedPromptTokens: cachedPromptTokens,
      );
}

class ToolCompletionOutcome {
  const ToolCompletionOutcome({required this.text, required this.modelId});
  final String text;
  final String modelId;
}

/// Capacidades reais de embedding (dimensões confirmadas por teste ao vivo,
/// nunca presumidas). `null` = ainda não verificado para este endpoint.
class EmbeddingCapabilities {
  const EmbeddingCapabilities({this.dimensions, this.maxBatch = 64});
  final int? dimensions;
  final int maxBatch;
}

/// Contrato opcional de providers que expõem `/embeddings`.
/// Providers sem suporte simplesmente NÃO implementam esta interface —
/// o chamador degrada graciosamente para busca léxica (nunca finge vetor).
abstract class EmbeddingProvider {
  /// Id do modelo de embedding efetivo neste endpoint.
  String get embeddingModelId;

  EmbeddingCapabilities get embeddingCapabilities;

  /// Verificação REAL: faz uma chamada mínima de embedding e confirma as
  /// dimensões retornadas. Falha tipada se o endpoint não suporta embeddings.
  Future<EmbeddingCapabilities> verifyEmbeddings();

  /// Gera embeddings reais para [texts] (ordem preservada na resposta).
  Future<List<List<double>>> embed({
    required List<String> texts,
    String? modelId,
  });
}
