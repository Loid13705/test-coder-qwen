/// Provider real compatível com OpenAI Chat Completions (SSE streaming).
///
/// Usado por: openai, deepseek, ollama (http://localhost:11434/v1), custom.
/// Sem API key/base URL configurados → falha tipada imediata (nunca conexão
/// fingida). Cancelamento aborta a requisição HTTP real.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/errors/redaction.dart';
import '../../domain/errors/vt_failure.dart';
import 'provider_contract.dart';

/// Override explícito de capacidades vindo de Settings → Models
/// ("capability override" da spec). Campos `null` = sem override (usa o
/// catálogo); `false` também é um override válido (desabilitar capacidade).
class CapabilityOverride {
  const CapabilityOverride({
    this.tools,
    this.vision,
    this.streaming,
    this.jsonMode,
    this.contextWindow,
  });

  final bool? tools;
  final bool? vision;
  final bool? streaming;
  final bool? jsonMode;
  final int? contextWindow;

  ModelCapabilities apply(ModelCapabilities base) => ModelCapabilities(
        tools: tools ?? base.tools,
        vision: vision ?? base.vision,
        streaming: streaming ?? base.streaming,
        jsonMode: jsonMode ?? base.jsonMode,
        longContext: contextWindow != null && contextWindow! >= 100000
            ? true
            : base.longContext,
        fast: base.fast,
        cheap: base.cheap,
      );
}

class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    this.apiKey = '',
    this.headers = const {},
    this.timeout = const Duration(seconds: 60),
    this.modelIds = const [],
    this.capabilityOverrides = const {},
  });

  final String id;
  final String displayName;
  final String baseUrl; // ex.: https://api.openai.com/v1
  final String apiKey; // vem do secure storage; nunca persistido em claro
  final Map<String, String> headers;
  final Duration timeout;
  final List<String> modelIds;

  /// Overrides por modelo (ex.: confirmar via teste real que um modelo local
  /// suporta tools). Sem override, capacidades desconhecidas NUNCA são
  /// presumidas.
  final Map<String, CapabilityOverride> capabilityOverrides;

  /// Servidor local (ollama, lmstudio, testes de integração com loopback real):
  /// não exige API key. Detecta pelo host do URI, não por substring solta.
  bool get isLocal {
    final host = Uri.tryParse(baseUrl)?.host.toLowerCase() ?? '';
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '0.0.0.0';
  }
}

class OpenAiCompatibleProvider implements LlmProvider {
  OpenAiCompatibleProvider(this.config,
      {SecretRedactor redactor = const SecretRedactor()})
      : _redactor = redactor;

  final ProviderConfig config;
  final SecretRedactor _redactor;
  HttpClient? _client;

  @override
  String get id => config.id;
  @override
  String get displayName => config.displayName;

  @override
  List<ModelInfo> get models => kKnownModels
      .where((m) => m.providerId == config.id)
      .where((m) => config.modelIds.isEmpty || config.modelIds.contains(m.id))
      .map(_applyOverride)
      .toList();

  /// Aplica capability override do usuário (Settings → Models) a um ModelInfo.
  ModelInfo _applyOverride(ModelInfo m) {
    final ov = config.capabilityOverrides[m.id];
    if (ov == null) return m;
    return ModelInfo(
      id: m.id,
      providerId: m.providerId,
      displayName: m.displayName,
      contextWindow: ov.contextWindow ?? m.contextWindow,
      capabilities: ov.apply(m.capabilities),
      pricing: m.pricing,
      source: m.source,
      enabled: true, // override explícito conta como confirmação do usuário
    );
  }

  /// Resolução REAL de capacidades para o modelo pedido:
  /// 1. catálogo conhecido por (providerId, modelId) + overrides;
  /// 2. ids locais derivados de catálogo (ex.: `llama3.1:8b-instruct-q5`);
  /// 3. modelo declarado em `modelIds` mas sem metadata → capacidades
  ///    conservadoras (streaming apenas), NUNCA presume tools/vision;
  /// 4. completamente desconhecido → null (o chamador decide; tools são
  ///    bloqueadas por padrão seguro).
  ModelInfo? _resolveModel(String modelId) {
    final direct = kKnownModels
        .where((m) => m.providerId == id && m.id == modelId)
        .firstOrNull;
    if (direct != null) return _applyOverride(direct);
    final base = kKnownModels
        .where((m) =>
            m.providerId == id &&
            m.source == ModelSource.local &&
            modelId.startsWith('${m.id}-'))
        .firstOrNull;
    if (base != null) {
      return ModelInfo(
        id: modelId,
        providerId: id,
        displayName: modelId,
        contextWindow: base.contextWindow,
        capabilities: const ModelCapabilities(streaming: true),
        source: ModelSource.local,
      );
    }
    if (config.modelIds.contains(modelId)) {
      return ModelInfo(
        id: modelId,
        providerId: id,
        displayName: modelId,
        contextWindow: 4096,
        capabilities: const ModelCapabilities(streaming: true),
        source: config.isLocal ? ModelSource.local : ModelSource.remote,
      );
    }
    return null;
  }

  HttpClient get _http {
    return _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
  }

  VtFailure? _preflight() {
    if (config.baseUrl.trim().isEmpty) {
      return VtFailure(
        code: VtErrorCode.providerNotConfigured,
        message: 'Provider "${config.id}" sem base URL configurada.',
        setupUri: 'techvt://settings/providers/${config.id}',
        recoveryActions: const [
          RecoveryAction(
              kind: 'configure_provider',
              label: 'Definir base URL em Settings → AI Providers'),
        ],
      );
    }
    if (config.apiKey.trim().isEmpty && !config.isLocal) {
      return VtFailure.apiKeyMissing(config.id);
    }
    return null;
  }

  Map<String, String> get _authHeaders => {
        'content-type': 'application/json',
        if (config.apiKey.isNotEmpty)
          'authorization': 'Bearer ${config.apiKey}',
        ...config.headers,
      };

  Uri _uri(String path) =>
      Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/$path');

  Future<(int status, String body)> _sendJson(
      String path, Map<String, Object?> body) async {
    final req = await _http.postUrl(_uri(path)).timeout(config.timeout);
    for (final h in _authHeaders.entries) {
      req.headers.set(h.key, h.value);
    }
    req.write(jsonEncode(body));
    final res = await req.close().timeout(config.timeout);
    final text = await res.transform(utf8.decoder).join();
    return (res.statusCode, text);
  }

  VtFailure _failureForStatus(int status, String body) {
    final safeBody =
        _redactor.redact(body.length > 600 ? body.substring(0, 600) : body);
    return switch (status) {
      401 || 403 => VtFailure(
          code: VtErrorCode.apiKeyMissing,
          message: 'Credencial recusada por "$id" (HTTP $status): $safeBody',
          setupUri: 'techvt://settings/providers/$id/key',
          recoveryActions: const [
            RecoveryAction(kind: 'add_api_key', label: 'Atualizar API key')
          ],
        ),
      429 => VtFailure.rateLimited(id),
      >= 500 => VtFailure(
          code: VtErrorCode.networkUnavailable,
          message: 'Provider "$id" retornou HTTP $status: $safeBody',
          retryable: true,
          recoveryActions: const [
            RecoveryAction(kind: 'retry', label: 'Tentar novamente')
          ],
        ),
      _ => VtFailure(
          code: VtErrorCode.internalError,
          message: 'Provider "$id" retornou HTTP $status: $safeBody',
        ),
    };
  }

  @override
  Future<ProviderStatus> healthCheck() async {
    final pre = _preflight();
    if (pre != null) {
      return pre.code == VtErrorCode.apiKeyMissing
          ? ProviderStatus.unconfigured
          : ProviderStatus.unconfigured;
    }
    try {
      final (status, _) = await _sendJsonHealth();
      if (status == 200) return ProviderStatus.ok;
      if (status == 429) return ProviderStatus.rateLimited;
      if (status == 401 || status == 403) return ProviderStatus.error;
      return ProviderStatus.error;
    } on SocketException {
      // modelo local não está rodando — estado real offline
      return config.isLocal ? ProviderStatus.offline : ProviderStatus.error;
    } on TimeoutException {
      return ProviderStatus.error;
    }
  }

  Future<(int, String)> _sendJsonHealth() async {
    final req = await _http.getUrl(_uri('models')).timeout(config.timeout);
    for (final h in _authHeaders.entries) {
      req.headers.set(h.key, h.value);
    }
    final res = await req.close().timeout(config.timeout);
    final text = await res.transform(utf8.decoder).join();
    return (res.statusCode, text);
  }

  @override
  Future<List<ModelInfo>> discoverModels() async {
    final pre = _preflight();
    if (pre != null) throw pre;
    try {
      final (status, body) = await _sendJsonHealth();
      if (status != 200) throw _failureForStatus(status, body);
      final decoded = (jsonDecode(body) as Map).cast<String, Object?>();
      final list = (decoded['data'] as List? ?? const [])
          .map((e) => (e as Map).cast<String, Object?>())
          .map((e) => e['id'] as String?)
          .whereType<String>()
          .toSet();
      // Cruza ids reais da conta com catálogo de capacidades conhecido.
      return [
        for (final known in kKnownModels)
          if (known.providerId == id && list.contains(known.id)) known,
        // Ids reais sem metadata conhecida entram desabilitados para tools —
        // capacidades desconhecidas NUNCA são presumidas.
        for (final unknownId
            in list.difference(kKnownModels.map((m) => m.id).toSet()))
          ModelInfo(
            id: unknownId,
            providerId: id,
            displayName: unknownId,
            contextWindow: 4096,
            capabilities: const ModelCapabilities(),
            source: config.isLocal ? ModelSource.local : ModelSource.remote,
            enabled: false,
          ),
      ];
    } on SocketException {
      throw VtFailure.networkUnavailable(' (endpoint inalcançável)');
    } on TimeoutException {
      throw VtFailure.timeout(config.timeout);
    }
  }

  @override
  Future<ToolCompletionOutcome> completeForCompletion({
    required String modelId,
    required String prefix,
    required String suffix,
  }) async {
    final pre = _preflight();
    if (pre != null) throw pre;
    try {
      final (status, body) = await _sendJson('chat/completions', {
        'model': modelId,
        'max_tokens': 128,
        'temperature': 0,
        'messages': [
          {
            'role': 'system',
            'content':
                'Continue o código exatamente após o cursor. Responda apenas com o texto de continuação, sem explicações.'
          },
          {'role': 'user', 'content': 'PREFIX:\n$prefix\nSUFFIX:\n$suffix'},
        ],
      });
      if (status != 200) throw _failureForStatus(status, body);
      final decoded = (jsonDecode(body) as Map).cast<String, Object?>();
      final choices = decoded['choices'] as List? ?? const [];
      final text = choices.isEmpty
          ? ''
          : (((choices.first as Map)['message'] as Map?)?['content']
                  as String? ??
              '');
      return ToolCompletionOutcome(text: text, modelId: modelId);
    } on VtFailure {
      rethrow;
    } on SocketException {
      throw VtFailure.networkUnavailable();
    } on TimeoutException {
      throw VtFailure.timeout(config.timeout);
    }
  }

  @override
  Stream<StreamChunk> streamChat({
    required String modelId,
    required List<ChatRequestMessage> messages,
    required ChatRequestOptions options,
    required List<Map<String, Object?>> toolSchemas,
    void Function(StreamHandle handle)? onHandle,
  }) {
    late final StreamController<StreamChunk> out;
    var cancelled = false;
    HttpClientResponse? liveRes;

    Future<void> doCancel() async {
      cancelled = true;
      // Abort REAL da conexão: o servidor percebe o fechamento do socket.
      final sock = await liveRes?.detachSocket();
      sock?.destroy();
      out.add(const DoneChunk('cancelled'));
      await out.close();
    }

    out = StreamController<StreamChunk>();
    out.onListen = () async {
      try {
        await _pump(modelId, messages, options, toolSchemas, (c) {
          if (!cancelled) out.add(c);
        }, (r) => liveRes = r);
      } on VtFailure catch (f) {
        if (!cancelled) out.add(ErrorChunk(f));
      } catch (e) {
        if (!cancelled) {
          out.add(ErrorChunk(
              VtFailure(code: VtErrorCode.internalError, message: '$e')));
        }
      } finally {
        if (!out.isClosed) await out.close();
      }
    };
    out.onCancel = doCancel;
    if (onHandle != null) {
      onHandle(StreamHandle(doCancel));
    }
    return out.stream;
  }

  /// Executa a requisição SSE real e emite chunks via [emit]. Lança [VtFailure]
  /// tipada para erros (nunca fabrica conteúdo).
  /// Normaliza o nome de tool vindo do provedor para um id estável do registry.
  /// Provedores OpenAI-compatíveis não aceitam `.` em nomes de função, então
  /// modelos locais/remotos frequentemente devolvem `fs_read_text` quando a
  /// schema foi enviada como `fs.read_text`. Match exato tem prioridade;
  /// fallback por underscore só vale contra os nomes REALMENTE enviados no
  /// request — nunca inventa ids.
  String _normalizeToolId(String rawName, Set<String> sentNames) {
    if (sentNames.contains(rawName)) return rawName;
    final underscored = rawName.replaceAll('_', '.');
    if (sentNames.contains(underscored)) return underscored;
    for (final n in sentNames) {
      if (n.replaceAll('.', '_') == rawName) return n;
    }
    return rawName;
  }

  Future<void> _pump(
    String modelId,
    List<ChatRequestMessage> messages,
    ChatRequestOptions options,
    List<Map<String, Object?>> toolSchemas,
    void Function(StreamChunk) emit,
    void Function(HttpClientResponse) onResponse,
  ) async {
    final sentToolNames = {
      for (final t in toolSchemas)
        if (t['name'] is String) t['name'] as String,
    };
    final pre = _preflight();
    if (pre != null) throw pre;
    final model = _resolveModel(modelId);
    if (toolSchemas.isNotEmpty && (model == null || !model.capabilities.tools)) {
      throw VtFailure.modelDoesNotSupportTools(modelId);
    }
    final supportsStreaming = model?.capabilities.streaming ?? true;
    final reqBody = <String, Object?>{
      'model': modelId,
      'messages': [
        for (final m in messages) {'role': m.role, 'content': m.content},
      ],
      if (options.temperature != null) 'temperature': options.temperature,
      if (options.topP != null) 'top_p': options.topP,
      if (options.maxTokens != null) 'max_tokens': options.maxTokens,
      if (options.stopSequences.isNotEmpty) 'stop': options.stopSequences,
      if (options.seed != null) 'seed': options.seed,
      if (options.jsonMode) 'response_format': {'type': 'json_object'},
      if (toolSchemas.isNotEmpty)
        'tools': [
          for (final t in toolSchemas) {'type': 'function', 'function': t}
        ],
      'stream': supportsStreaming,
      if (supportsStreaming) 'stream_options': {'include_usage': true},
    };

    HttpClientResponse res;
    try {
      final req =
          await _http.postUrl(_uri('chat/completions')).timeout(config.timeout);
      for (final h in _authHeaders.entries) {
        req.headers.set(h.key, h.value);
      }
      req.write(jsonEncode(reqBody));
      res = await req.close().timeout(config.timeout);
    } on SocketException catch (e) {
      throw VtFailure.networkUnavailable(' ${e.osError?.message ?? ''}');
    } on TimeoutException {
      throw VtFailure.timeout(config.timeout);
    }
    onResponse(res);
    if (res.statusCode != 200) {
      final body = await res.transform(utf8.decoder).join();
      throw _failureForStatus(res.statusCode, body);
    }
    if (!supportsStreaming) {
      // Resposta única REAL (sem streaming): um Delta + Done.
      final body = await res.transform(utf8.decoder).join();
      final decoded = (jsonDecode(body) as Map).cast<String, Object?>();
      final usage = (decoded['usage'] as Map?)?.cast<String, Object?>();
      if (usage != null) {
        emit(UsageChunk(
          promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
          completionTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
        ));
      }
      final choices = decoded['choices'] as List? ?? const [];
      if (choices.isNotEmpty) {
        final c0 = (choices.first as Map).cast<String, Object?>();
        final content = ((c0['message'] as Map?)?['content'] as String?) ?? '';
        if (content.isNotEmpty) emit(DeltaChunk(content));
        emit(DoneChunk(c0['finish_reason'] as String? ?? 'stop'));
      } else {
        emit(const DoneChunk('stop'));
      }
      return;
    }

    final toolCallAccum = <int, _PartialToolCall>{};
    try {
      await for (final line
          in res.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload == '[DONE]') break;
        Map<String, Object?> chunk;
        try {
          chunk = (jsonDecode(payload) as Map).cast<String, Object?>();
        } on FormatException {
          continue; // linha parcial/corrompida do SSE — ignora (real)
        }
        final usage = chunk['usage'];
        if (usage is Map) {
          emit(UsageChunk(
            promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
            completionTokens:
                (usage['completion_tokens'] as num?)?.toInt() ?? 0,
          ));
        }
        final choices = chunk['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final c0 = (choices.first as Map).cast<String, Object?>();
        final delta = (c0['delta'] as Map?)?.cast<String, Object?>();
        final content = delta?['content'] as String?;
        if (content != null && content.isNotEmpty) emit(DeltaChunk(content));
        final tcs = delta?['tool_calls'] as List?;
        if (tcs != null) {
          for (final tc in tcs) {
            final m = (tc as Map).cast<String, Object?>();
            final idx = (m['index'] as num?)?.toInt() ?? 0;
            final fn = (m['function'] as Map?)?.cast<String, Object?>();
            final acc =
                toolCallAccum.putIfAbsent(idx, () => _PartialToolCall());
            if (m['id'] != null) acc.id = m['id'] as String;
            if (fn?['name'] != null) acc.name += fn!['name'] as String;
            if (fn?['arguments'] != null) {
              acc.args += fn!['arguments'] as String;
            }
          }
        }
        final finish = c0['finish_reason'] as String?;
        if (finish != null) {
          for (final acc in toolCallAccum.values) {
            if (acc.name.isNotEmpty) {
              emit(ToolCallStartChunk(
                  callId:
                      acc.id ?? 'call_${DateTime.now().microsecondsSinceEpoch}',
                  toolId: _normalizeToolId(acc.name, sentToolNames),
                  argsJson: acc.args));
            }
          }
          emit(DoneChunk(finish));
          return;
        }
      }
      // stream terminou sem finish_reason explícito
      for (final acc in toolCallAccum.values) {
        if (acc.name.isNotEmpty) {
          emit(ToolCallStartChunk(
              callId: acc.id ?? 'call_${DateTime.now().microsecondsSinceEpoch}',
              toolId: _normalizeToolId(acc.name, sentToolNames),
              argsJson: acc.args));
        }
      }
      emit(const DoneChunk('stop'));
    } on SocketException catch (e) {
      // erro de stream é erro real
      throw VtFailure(
          code: VtErrorCode.networkUnavailable,
          message: 'Conexão de streaming interrompida: ${e.message}',
          retryable: true);
    }
  }

  Future<void> dispose() async {
    _client?.close(force: true);
    _client = null;
  }
}

class _PartialToolCall {
  String? id;
  String name = '';
  String args = '';
}
