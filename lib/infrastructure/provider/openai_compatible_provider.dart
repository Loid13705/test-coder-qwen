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

/// Wire protocol suportado pelo [OpenAiCompatibleProvider].
enum OpenAiCompatWire {
  /// `/chat/completions` clássico (OpenAI, DeepSeek, Groq, Mistral, Ollama
  /// via `/v1`, LM Studio, qualquer endpoint compatível).
  chatCompletions,

  /// `/completions` legado para modelos de completion pura que não expõem
  /// chat completions (ex.: `gpt-3.5-base`, alguns adapters locais).
  textCompletions,

  /// `/messages` da Anthropic Messages API — usado por gateways/proxies
  /// Anthropic-compatíveis. Habilita o envelope SSE nativo
  /// (`content_block_delta` etc.) em vez de `choices[].delta`.
  anthropicMessages,
}

/// Presets de configuração dos provedores conhecidos. A UI de Settings usa
/// isto para popular baseUrl padrão + wire protocol esperado; o usuário pode
/// sobrescrever tudo (endpoints proxy/custom).
class ProviderPreset {
  const ProviderPreset(this.id, this.displayName, this.defaultBaseUrl,
      [this.wire = OpenAiCompatWire.chatCompletions]);
  final String id;
  final String displayName;
  final String defaultBaseUrl;
  final OpenAiCompatWire wire;
}

const kProviderPresets = <ProviderPreset>[
  ProviderPreset('openai', 'OpenAI', 'https://api.openai.com/v1'),
  ProviderPreset(
      'anthropic', 'Anthropic', 'https://api.anthropic.com/v1',
      OpenAiCompatWire.anthropicMessages),
  ProviderPreset('deepseek', 'DeepSeek', 'https://api.deepseek.com/v1'),
  ProviderPreset('ollama', 'Ollama (local)', 'http://localhost:11434/v1'),
  ProviderPreset('lmstudio', 'LM Studio (local)', 'http://localhost:1234/v1'),
  ProviderPreset('groq', 'Groq', 'https://api.groq.com/openai/v1'),
  ProviderPreset('mistral', 'Mistral', 'https://api.mistral.ai/v1'),
  ProviderPreset('custom', 'Custom (OpenAI-compatível)', ''),
];

/// Detecção prática de wire pelo host do endpoint — usada só como DEFAULT no
/// form de Settings; a escolha final é sempre confirmada/sobrescrita pelo
/// usuário (nunca presumir silenciosamente).
OpenAiCompatWire? detectWireFromHost(String baseUrl) {
  final host = Uri.tryParse(baseUrl)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return null;
  if (host == 'api.anthropic.com' || host.endsWith('.anthropic.com')) {
    return OpenAiCompatWire.anthropicMessages;
  }
  if (host.endsWith('openai.com') ||
      host.endsWith('deepseek.com') ||
      host.endsWith('groq.com') ||
      host.endsWith('mistral.ai') ||
      host == 'localhost' ||
      host == '127.0.0.1') {
    return OpenAiCompatWire.chatCompletions;
  }
  return null; // desconhecido → UI pergunta
}

class OpenAiCompatibleProvider implements LlmProvider {
  OpenAiCompatibleProvider(this.config,
      {SecretRedactor redactor = const SecretRedactor(),
      this.wire = OpenAiCompatWire.chatCompletions})
      : _redactor = redactor;

  final ProviderConfig config;
  final OpenAiCompatWire wire;
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
  /// 1. catálogo conhecido por id; quando o MESMO id existe em outro
  ///    provedor do catálogo (ex.: `gpt-4o-mini` num endpoint custom/
  ///    OpenAI-compatível), as capacidades declaradas publicamente daquele
  ///    provedor são um floor — mas NUNCA sem confirmação: só valem se o
  ///    modelo estiver declarado em `modelIds` (confirmação explícita do
  ///    usuário) ou se houver capability override. Caso contrário entra
  ///    conservador (streaming apenas);
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
    // Mesmo id de catálogo sob outro provedor (custom/deepseek/ollama
    // apontando p/ endpoint OpenAI-compatível): usa as capacidades como
    // floor SOMENTE com confirmação do usuário (modelIds ou override).
    final cross = kKnownModels.where((m) => m.id == modelId).firstOrNull;
    if (cross != null) {
      final confirmed = config.modelIds.contains(modelId) ||
          config.capabilityOverrides.containsKey(modelId);
      return _applyOverride(ModelInfo(
        id: modelId,
        providerId: id,
        displayName: cross.displayName,
        contextWindow: cross.contextWindow,
        capabilities: confirmed ? cross.capabilities : const ModelCapabilities(streaming: true),
        pricing: cross.pricing,
        source: config.isLocal ? ModelSource.local : ModelSource.remote,
      ));
    }
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
    // HttpClient não expõe encoding cru; o corpo é lido como
    // Stream<List<int>> (bytes) e decodado por utf8ChunksIncremental/_sseLines.
    return _client ??= HttpClient()..connectionTimeout = const Duration(seconds: 15);
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
        ..._wireHeaders,
        ...config.headers,
      };

  Uri _uri(String path) =>
      Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/$path');

  /// Caminho do endpoint de geração conforme o wire protocol.
  String get _generatePath => switch (wire) {
        OpenAiCompatWire.chatCompletions => 'chat/completions',
        OpenAiCompatWire.textCompletions => 'completions',
        OpenAiCompatWire.anthropicMessages => 'messages',
      };

  /// Header `x-api-key` exigido pelo wire Anthropic (gateways/proxies).
  Map<String, String> get _wireHeaders => wire ==
          OpenAiCompatWire.anthropicMessages
      ? {
          if (config.apiKey.isNotEmpty) 'x-api-key': config.apiKey,
          'anthropic-version': '2023-06-01',
        }
      : const {};

  Future<(int status, String body)> _sendJson(
      String path, Map<String, Object?> body) async {
    final req = await _http.postUrl(_uri(path)).timeout(config.timeout);
    for (final h in _authHeaders.entries) {
      req.headers.set(h.key, h.value);
    }
    req.write(jsonEncode(body));
    final res = await req.close().timeout(config.timeout);
    final text = await _decodeUtf8Lenient(res);
    return (res.statusCode, text);
  }

  /// Decodificação UTF-8 tolerante: servidores reais podem fechar a conexão
  /// no meio de um multi-byte (cancelamento/truncamento) — nunca deixar o
  /// `allowMalformed: false` padrão derrubar a stream inteira.
  Future<String> _decodeUtf8Lenient(Stream<List<int>> bytes) async {
    final sb = StringBuffer();
    await for (final part in utf8ChunksIncremental(bytes)) {
      sb.write(part);
    }
    return sb.toString();
  }

  /// Fonte de linhas SSE com decodificação UTF-8 INCREMENTAL e tolerante.
  ///
  /// `dart:convert` tem duas armadilhas reais aqui:
  /// 1. `Utf8Decoder(allowMalformed: true)` só é leniente em `convert(flush)`
  ///    final — em modo chunked (`addSlice`) ele ainda lança
  ///    `FormatException("Missing extension byte")` quando um chunk termina
  ///    no meio de uma sequência multi-byte (acontece em streams HTTP
  ///    reais, pois os chunks TCP não respeitam fronteiras de código).
  /// 2. `LineSplitter` faz o mesmo buffer interno sem controle.
  /// Por isso o parsing é manual: acumulamos bytes pendentes e só decodificamos
  /// o prefixo completo; linha parcial fica no buffer até o próximo chunk.
  Stream<String> _utf8Chunks(Stream<List<int>> bytes) =>
      utf8ChunksIncremental(bytes);

  Stream<String> _sseLines(Stream<List<int>> bytes) async* {
    final buf = StringBuffer();
    await for (final part in _utf8Chunks(bytes)) {
      buf.write(part);
      final s = buf.toString();
      var start = 0;
      while (true) {
        final nl = s.indexOf('\n', start);
        if (nl < 0) break;
        var line = s.substring(start, nl);
        if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
        yield line;
        start = nl + 1;
      }
      if (start > 0) {
        final rest = s.substring(start);
        buf.clear();
        buf.write(rest);
      }
    }
    final tail = buf.toString();
    if (tail.isNotEmpty) yield tail;
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
    final text = await _decodeUtf8Lenient(res);
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
      // Match por id (endpoint OpenAI-compatível pode reportar modelos de
      // outro provedor, ex.: custom → gpt-4o-mini); o ModelInfo é reancorado
      // no provedor real para _resolveModel encontrar a resolução direta.
      return [
        for (final known in kKnownModels)
          if (list.contains(known.id))
            known.providerId == id
                ? known
                : ModelInfo(
                    id: known.id,
                    providerId: id,
                    displayName: known.displayName,
                    contextWindow: known.contextWindow,
                    capabilities: known.capabilities,
                    pricing: known.pricing,
                    source: config.isLocal
                        ? ModelSource.local
                        : ModelSource.remote,
                  ),
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
    const ghostPrompt = 'Continue o código exatamente após o cursor. '
        'Responda apenas com o texto de continuação, sem explicações.';
    try {
      final Map<String, Object?> decoded;
      switch (wire) {
        case OpenAiCompatWire.anthropicMessages:
          final (status, body) = await _sendJson(_generatePath, {
            'model': modelId,
            'max_tokens': 128,
            'temperature': 0,
            'stream': false,
            'system': ghostPrompt,
            'messages': [
              {'role': 'user', 'content': 'PREFIX:\n$prefix\nSUFFIX:\n$suffix'},
            ],
          });
          if (status != 200) throw _failureForStatus(status, body);
          decoded = (jsonDecode(body) as Map).cast<String, Object?>();
          final blocks = decoded['content'] as List? ?? const [];
          final text = blocks
              .map((b) => (b as Map)['text'] as String?)
              .whereType<String>()
              .join();
          return ToolCompletionOutcome(text: text, modelId: modelId);
        case OpenAiCompatWire.textCompletions:
          final (status, body) = await _sendJson(_generatePath, {
            'model': modelId,
            'max_tokens': 128,
            'temperature': 0,
            'prompt': '$ghostPrompt\n\nPREFIX:\n$prefix\nSUFFIX:\n$suffix',
          });
          if (status != 200) throw _failureForStatus(status, body);
          decoded = (jsonDecode(body) as Map).cast<String, Object?>();
          final choices = decoded['choices'] as List? ?? const [];
          final text = choices.isEmpty
              ? ''
              : ((choices.first as Map)['text'] as String? ?? '');
          return ToolCompletionOutcome(text: text, modelId: modelId);
        case OpenAiCompatWire.chatCompletions:
          final (status, body) = await _sendJson(_generatePath, {
            'model': modelId,
            'max_tokens': 128,
            'temperature': 0,
            'messages': [
              {'role': 'system', 'content': ghostPrompt},
              {'role': 'user', 'content': 'PREFIX:\n$prefix\nSUFFIX:\n$suffix'},
            ],
          });
          if (status != 200) throw _failureForStatus(status, body);
          decoded = (jsonDecode(body) as Map).cast<String, Object?>();
          final choices = decoded['choices'] as List? ?? const [];
          final text = choices.isEmpty
              ? ''
              : (((choices.first as Map)['message'] as Map?)?['content']
                      as String? ??
                  '');
          return ToolCompletionOutcome(text: text, modelId: modelId);
      }
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
    // Controller SEM callback/onListen: começar a bombear só na escuta evita
    // corrida entre `onHandle` síncrono e a primeira linha SSE. A stream é
    // single-subscription, então o primeiro `listen` dispara o pump.
    final out = StreamController<StreamChunk>();
    var cancelled = false;
    var closed = false;
    var pumping = false;
    HttpClientResponse? liveRes;

    void safeAdd(StreamChunk c) {
      if (cancelled || closed || out.isClosed) return;
      out.add(c);
    }

    Future<void> closeOnce() async {
      if (closed) return;
      closed = true;
      await out.close();
    }

    Future<void> doCancel() async {
      if (cancelled) return;
      cancelled = true;
      // Abort REAL da conexão: o servidor percebe o fechamento do socket.
      try {
        final sock = await liveRes?.detachSocket().timeout(
            const Duration(milliseconds: 200),
            onTimeout: () => NullSocketPlaceholder());
        sock?.destroy();
      } catch (_) {
        // Body já em uso / stream já fechado — destroy via subscription chega
        // ao servidor de qualquer forma (encerrar a stream aborta a leitura).
      }
      await closeOnce();
    }

    Future<void> startPump() async {
      if (pumping || cancelled || closed) return;
      pumping = true;
      try {
        await _pump(modelId, messages, options, toolSchemas, safeAdd,
            (r) => liveRes = r);
      } on VtFailure catch (f) {
        safeAdd(ErrorChunk(f));
      } catch (e) {
        safeAdd(ErrorChunk(
            VtFailure(code: VtErrorCode.internalError, message: '$e')));
      } finally {
        await closeOnce();
      }
    }

    out.onListen = () => unawaited(startPump());
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
    final Map<String, Object?> reqBody;
    switch (wire) {
      case OpenAiCompatWire.anthropicMessages:
        // Proxy/gateway Anthropic-compatível: envelope Messages API real
        // (system separado, tools com input_schema, stop_sequences).
        final system = StringBuffer();
        final msgs = <Map<String, Object?>>[];
        for (final m in messages) {
          switch (m.role) {
            case 'system':
              if (system.isNotEmpty) system.write('\n\n');
              system.write(m.content);
            case 'tool':
              msgs.add({
                'role': 'user',
                'content': [
                  {'type': 'tool_result', 'content': m.content}
                ]
              });
            default:
              msgs.add({'role': m.role, 'content': m.content});
          }
        }
        if (msgs.isEmpty) {
          throw VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Mensagens vazias: wire Anthropic exige ao menos um turno user.',
          );
        }
        reqBody = <String, Object?>{
          'model': modelId,
          'max_tokens': options.maxTokens ?? 4096,
          'stream': supportsStreaming,
          'system': system.toString(),
          'messages': msgs,
          if (options.temperature != null) 'temperature': options.temperature,
          if (options.topP != null) 'top_p': options.topP,
          if (options.stopSequences.isNotEmpty)
            'stop_sequences': options.stopSequences,
          if (toolSchemas.isNotEmpty)
            'tools': [
              for (final t in toolSchemas)
                {
                  'name': t['name'],
                  if (t['description'] != null) 'description': t['description'],
                  'input_schema': t['parameters'] ??
                      {'type': 'object', 'properties': <String, Object?>{}},
                }
            ],
        };
      case OpenAiCompatWire.textCompletions:
        reqBody = <String, Object?>{
          'model': modelId,
          'prompt': [
            for (final m in messages) '${m.role.toUpperCase()}: ${m.content}',
            'ASSISTANT:',
          ].join('\n\n'),
          if (options.temperature != null) 'temperature': options.temperature,
          if (options.topP != null) 'top_p': options.topP,
          if (options.maxTokens != null) 'max_tokens': options.maxTokens,
          if (options.stopSequences.isNotEmpty) 'stop': options.stopSequences,
          if (options.seed != null) 'seed': options.seed,
          'stream': supportsStreaming,
        };
      case OpenAiCompatWire.chatCompletions:
        reqBody = <String, Object?>{
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
    }

    HttpClientResponse res;
    try {
      final req =
          await _http.postUrl(_uri(_generatePath)).timeout(config.timeout);
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
      final body = await _decodeUtf8Lenient(res);
      throw _failureForStatus(res.statusCode, body);
    }
    if (!supportsStreaming) {
      // Resposta única REAL (sem streaming): um Delta + Done.
      final body = await _decodeUtf8Lenient(res);
      final decoded = (jsonDecode(body) as Map).cast<String, Object?>();
      if (wire == OpenAiCompatWire.anthropicMessages) {
        final u = (decoded['usage'] as Map?)?.cast<String, Object?>();
        if (u != null) {
          emit(UsageChunk(
            promptTokens: (u['input_tokens'] as num?)?.toInt() ?? 0,
            completionTokens: (u['output_tokens'] as num?)?.toInt() ?? 0,
          ));
        }
        final blocks = decoded['content'] as List? ?? const [];
        final text = blocks
            .map((b) => (b as Map)['text'] as String?)
            .whereType<String>()
            .join();
        if (text.isNotEmpty) emit(DeltaChunk(text));
        emit(DoneChunk(decoded['stop_reason'] as String? ?? 'stop'));
        return;
      }
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
        final content = wire == OpenAiCompatWire.textCompletions
            ? (c0['text'] as String? ?? '')
            : ((c0['message'] as Map?)?['content'] as String? ?? '');
        if (content.isNotEmpty) emit(DeltaChunk(content));
        emit(DoneChunk(c0['finish_reason'] as String? ?? 'stop'));
      } else {
        emit(const DoneChunk('stop'));
      }
      return;
    }

    // Wire Anthropic nativo (proxy/gateway): envelope SSE de eventos tipados
    // (content_block_delta etc.), com os mesmos acumuladores do provider
    // Anthropic real — nunca o parser OpenAI sobre payload Anthropic.
    if (wire == OpenAiCompatWire.anthropicMessages) {
      final blockTypes = <int, String>{};
      final blockIds = <int, String>{};
      final blockNames = <int, String>{};
      final blockJson = <int, StringBuffer>{};
      try {
        await for (final line in _sseLines(res)) {
          if (!line.startsWith('data:')) continue;
          final payload = line.substring(5).trim();
          if (payload.isEmpty) continue;
          Map<String, Object?> ev;
          try {
            ev = (jsonDecode(payload) as Map).cast<String, Object?>();
          } on FormatException {
            continue; // SSE parcial/corrompido — ignora linha (real)
          }
          switch (ev['type'] as String?) {
            case 'content_block_start':
              final idx = (ev['index'] as num?)?.toInt() ?? 0;
              final blk =
                  (ev['content_block'] as Map?)?.cast<String, Object?>();
              blockTypes[idx] = blk?['type'] as String? ?? 'text';
              if (blockTypes[idx] == 'tool_use') {
                blockIds[idx] = blk?['id'] as String? ?? '';
                blockNames[idx] = blk?['name'] as String? ?? '';
                blockJson[idx] = StringBuffer();
              }
            case 'content_block_delta':
              final d = (ev['delta'] as Map?)?.cast<String, Object?>();
              switch (d?['type'] as String?) {
                case 'text_delta':
                  final t = d!['text'] as String?;
                  if (t != null && t.isNotEmpty) emit(DeltaChunk(t));
                case 'input_json_delta':
                  final idx = (ev['index'] as num?)?.toInt() ?? 0;
                  blockJson[idx]?.write(d!['partial_json'] as String? ?? '');
                case 'thinking_delta':
                  break;
              }
            case 'content_block_stop':
              final idx = (ev['index'] as num?)?.toInt() ?? 0;
              if (blockTypes[idx] == 'tool_use') {
                emit(ToolCallStartChunk(
                  callId: blockIds[idx]?.isNotEmpty == true
                      ? blockIds[idx]!
                      : 'call_${DateTime.now().microsecondsSinceEpoch}',
                  toolId: _normalizeToolId(
                      blockNames[idx] ?? '', sentToolNames),
                  argsJson: blockJson[idx]?.toString() ?? '{}',
                ));
              }
            case 'message_delta':
              final u = (ev['usage'] as Map?)?.cast<String, Object?>();
              if (u != null) {
                emit(UsageChunk(
                  promptTokens: (u['input_tokens'] as num?)?.toInt() ?? 0,
                  completionTokens: (u['output_tokens'] as num?)?.toInt() ?? 0,
                ));
              }
            case 'message_stop':
              emit(const DoneChunk('stop'));
              return;
            case 'error':
              final err = (ev['error'] as Map?)?.cast<String, Object?>();
              throw VtFailure(
                code: VtErrorCode.internalError,
                message:
                    'Erro de streaming no gateway Anthropic: ${err?['type']}: ${err?['message']}',
                retryable: true,
              );
          }
        }
        emit(const DoneChunk('stop'));
      } on SocketException catch (e) {
        throw VtFailure(
            code: VtErrorCode.networkUnavailable,
            message: 'Conexão de streaming interrompida: ${e.message}',
            retryable: true);
      }
      return;
    }

    final toolCallAccum = <int, _PartialToolCall>{};
    var sawFinish = false;
    String? finishReason;
    try {
      await for (final line in _sseLines(res)) {
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
        // Wire `/completions` legado: o texto incremental vem em `text`,
        // não em `delta.content`. finish_reason/usage seguem o mesmo fluxo.
        if (wire == OpenAiCompatWire.textCompletions) {
          final t = c0['text'] as String?;
          if (t != null && t.isNotEmpty) emit(DeltaChunk(t));
          final fin = c0['finish_reason'] as String?;
          if (fin != null) {
            sawFinish = true;
            finishReason = fin;
          }
          continue;
        }
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
          // OpenAI-compat REAL: o chunk de usage chega DEPOIS do
          // finish_reason (última linha antes de [DONE]). Continua lendo
          // até [DONE]/fim para não perder tokens — DoneChunk é emitido no
          // flush abaixo, exatamente uma vez.
          sawFinish = true;
          finishReason = finish;
          continue;
        }
      }
      // stream chegou em [DONE] ou fim de conexão: emite os pendências
      // (tool_calls acumulados e DoneChunk) caso o finish_reason tenha sido
      // visto mas a leitura continuou para capturar usage.
      if (!sawFinish) {
        for (final acc in toolCallAccum.values) {
          if (acc.name.isNotEmpty) {
            emit(ToolCallStartChunk(
                callId: acc.id ?? 'call_${DateTime.now().microsecondsSinceEpoch}',
                toolId: _normalizeToolId(acc.name, sentToolNames),
                argsJson: acc.args));
          }
        }
      }
      if (sawFinish) {
        emit(DoneChunk(finishReason!));
      }
      else {
        emit(const DoneChunk('stop'));
      }
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

/// Placeholder para `detachSocket()` que não completou a tempo (cancelamento):
/// `destroy()` é no-op. Evita bloquear o cancelamento esperando o socket.
class NullSocketPlaceholder implements Socket {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Decodificador UTF-8 INCREMENTAL e tolerante compartilhado pelos providers.
///
/// `dart:convert` lança `FormatException("Missing extension byte")` em modo
/// chunked quando um chunk HTTP termina no meio de uma sequência multi-byte
/// (os chunks TCP não respeitam fronteiras de código). Aqui acumulamos os
/// bytes pendentes e só decodificamos o prefixo completo; a cauda truncada
/// (servidor fechou no meio do caractere, ex.: cancelamento) é decodificada
/// lenientemente no flush final — nunca derruba a stream inteira.
Stream<String> utf8ChunksIncremental(Stream<List<int>> bytes) async* {
  var pending = <int>[];
  await for (final chunk in bytes) {
    pending.addAll(chunk);
    final consumed = completeUtf8PrefixLength(pending);
    if (consumed == 0) continue;
    final complete = pending.sublist(0, consumed);
    pending = pending.sublist(consumed);
    yield utf8.decode(complete, allowMalformed: true);
  }
  if (pending.isNotEmpty) {
    yield utf8.decode(pending, allowMalformed: true);
  }
}

/// Comprimento do prefixo de [b] que forma sequências UTF-8 completas;
/// qualquer sufixo de 1..3 bytes de cabeçalho incompleto fica de fora.
int completeUtf8PrefixLength(List<int> b) {
  final n = b.length;
  if (n == 0) return 0;
  // Examina os últimos 4 bytes para achar início de sequência incompleta.
  for (var back = 1; back <= 4 && back <= n; back++) {
    final i = n - back;
    final byte = b[i];
    if ((byte & 0x80) == 0) return n; // ASCII completo no fim
    if ((byte & 0xE0) == 0xC0) {
      // cabeçalho de 2 bytes: faltam 1 continuação?
      return back >= 2 ? n : i;
    }
    if ((byte & 0xF0) == 0xE0) {
      return back >= 3 ? n : i;
    }
    if ((byte & 0xF8) == 0xF0) {
      return back >= 4 ? n : i;
    }
    // byte de continuação (10xxxxxx): continua retrocedendo para o cabeçalho
  }
  return n;
}
