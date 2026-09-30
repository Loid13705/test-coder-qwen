/// Provider REAL da Anthropic Messages API (https://api.anthropic.com/v1).
///
/// Streaming SSE nativo (`content_block_delta` etc.), tool_use em blocos e
/// system prompt separado — mapeamento fiel do formato Anthropic, não uma
/// reimplementação "fake". Sem API key → falha tipada imediata. Cancelamento
/// aborta a conexão HTTP real.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/errors/redaction.dart';
import '../../domain/errors/vt_failure.dart';
import 'openai_compatible_provider.dart' show ProviderConfig;
import 'provider_contract.dart';

class AnthropicProvider implements LlmProvider {
  AnthropicProvider(this.config,
      {SecretRedactor redactor = const SecretRedactor()})
      : _redactor = redactor;

  final ProviderConfig config; // baseUrl ex.: https://api.anthropic.com/v1
  final SecretRedactor _redactor;
  HttpClient? _client;

  static const _anthropicVersion = '2023-06-01';

  @override
  String get id => config.id;
  @override
  String get displayName => config.displayName;

  @override
  List<ModelInfo> get models => kKnownModels
      .where((m) => m.providerId == 'anthropic')
      .where((m) => config.modelIds.isEmpty || config.modelIds.contains(m.id))
      .toList();

  HttpClient get _http =>
      _client ??= HttpClient()..connectionTimeout = const Duration(seconds: 15);

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'x-api-key': config.apiKey,
        'anthropic-version': _anthropicVersion,
        ...config.headers,
      };

  Uri _uri(String path) =>
      Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/$path');

  VtFailure? _preflight() {
    if (config.baseUrl.trim().isEmpty) {
      return VtFailure.providerNotConfigured(config.id);
    }
    if (config.apiKey.trim().isEmpty) return VtFailure.apiKeyMissing(config.id);
    return null;
  }

  VtFailure _failureForStatus(int status, String body) {
    final safeBody =
        _redactor.redact(body.length > 600 ? body.substring(0, 600) : body);
    return switch (status) {
      401 || 403 => VtFailure(
          code: VtErrorCode.apiKeyMissing,
          message: 'API key recusada pela Anthropic (HTTP $status): $safeBody',
          setupUri: 'techvt://settings/providers/anthropic/key',
          recoveryActions: const [
            RecoveryAction(kind: 'add_api_key', label: 'Atualizar API key')
          ],
        ),
      429 => VtFailure.rateLimited('anthropic'),
      >= 500 => VtFailure(
          code: VtErrorCode.networkUnavailable,
          message: 'Anthropic retornou HTTP $status: $safeBody',
          retryable: true,
          recoveryActions: const [
            RecoveryAction(kind: 'retry', label: 'Tentar novamente')
          ],
        ),
      _ => VtFailure(
          code: VtErrorCode.internalError,
          message: 'Anthropic retornou HTTP $status: $safeBody',
        ),
    };
  }

  Future<(int, String)> _get(String path) async {
    final req = await _http.getUrl(_uri(path)).timeout(config.timeout);
    for (final h in _headers.entries) {
      req.headers.set(h.key, h.value);
    }
    final res = await req.close().timeout(config.timeout);
    final text = await res.transform(utf8.decoder).join();
    return (res.statusCode, text);
  }

  @override
  Future<ProviderStatus> healthCheck() async {
    final pre = _preflight();
    if (pre != null) return ProviderStatus.unconfigured;
    try {
      final (status, _) = await _get('models');
      if (status == 200) return ProviderStatus.ok;
      if (status == 429) return ProviderStatus.rateLimited;
      return ProviderStatus.error;
    } on SocketException {
      return ProviderStatus.offline;
    } on TimeoutException {
      return ProviderStatus.error;
    }
  }

  @override
  Future<List<ModelInfo>> discoverModels() async {
    final pre = _preflight();
    if (pre != null) throw pre;
    try {
      final (status, body) = await _get('models');
      if (status != 200) throw _failureForStatus(status, body);
      final decoded = (jsonDecode(body) as Map).cast<String, Object?>();
      final data = (decoded['data'] as List? ?? const [])
          .map((e) => (e as Map).cast<String, Object?>());
      final remoteIds = data.map((e) => e['id'] as String?).whereType<String>();
      return [
        for (final known in kKnownModels)
          if (known.providerId == 'anthropic' && remoteIds.contains(known.id))
            known,
        for (final rid in remoteIds)
          if (!kKnownModels.any((m) => m.id == rid))
            ModelInfo(
              id: rid,
              providerId: 'anthropic',
              displayName: rid,
              contextWindow: 8000,
              capabilities: const ModelCapabilities(streaming: true),
              enabled: false,
            ),
      ];
    } on SocketException {
      throw VtFailure.networkUnavailable();
    } on TimeoutException {
      throw VtFailure.timeout(config.timeout);
    }
  }

  /// Converte mensagens do contrato para o formato Anthropic:
  /// system sai separado; tool results viram tool_result no content user.
  ({String system, List<Map<String, Object?>> messages}) _convert(
      List<ChatRequestMessage> msgs) {
    final system = StringBuffer();
    final out = <Map<String, Object?>>[];
    for (final m in msgs) {
      switch (m.role) {
        case 'system':
          if (system.isNotEmpty) system.write('\n\n');
          system.write(m.content);
        case 'tool':
          out.add({
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'content': m.content}
            ]
          });
        default:
          out.add({'role': m.role, 'content': m.content});
      }
    }
    return (system: system.toString(), messages: out);
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
      final req = await _http.postUrl(_uri('messages')).timeout(config.timeout);
      for (final h in _headers.entries) {
        req.headers.set(h.key, h.value);
      }
      req.write(jsonEncode({
        'model': modelId,
        'max_tokens': 128,
        'temperature': 0,
        'stream': false,
        'system':
            'Continue o código exatamente após o cursor. Responda apenas com o texto de continuação, sem explicações.',
        'messages': [
          {'role': 'user', 'content': 'PREFIX:\n$prefix\nSUFFIX:\n$suffix'}
        ],
      }));
      final res = await req.close().timeout(config.timeout);
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw _failureForStatus(res.statusCode, body);
      final decoded = (jsonDecode(body) as Map).cast<String, Object?>();
      final blocks = decoded['content'] as List? ?? const [];
      final text = blocks
          .map((b) => (b as Map)['text'] as String?)
          .whereType<String>()
          .join();
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

  Future<void> _pump(
    String modelId,
    List<ChatRequestMessage> messages,
    ChatRequestOptions options,
    List<Map<String, Object?>> toolSchemas,
    void Function(StreamChunk) emit,
    void Function(HttpClientResponse) onResponse,
  ) async {
    final pre = _preflight();
    if (pre != null) throw pre;
    final model = kKnownModels
        .where((m) => m.id == modelId && m.providerId == 'anthropic')
        .firstOrNull;
    if (toolSchemas.isNotEmpty && model != null && !model.capabilities.tools) {
      throw VtFailure.modelDoesNotSupportTools(modelId);
    }
    final converted = _convert(messages);
    if (converted.messages.isEmpty) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Mensagens vazias: Anthropic exige ao menos um turno user.',
      );
    }
    final body = <String, Object?>{
      'model': modelId,
      'max_tokens': options.maxTokens ?? 4096,
      'stream': true,
      'system': converted.system,
      'messages': converted.messages,
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

    HttpClientResponse res;
    try {
      final req = await _http.postUrl(_uri('messages')).timeout(config.timeout);
      for (final h in _headers.entries) {
        req.headers.set(h.key, h.value);
      }
      req.write(jsonEncode(body));
      res = await req.close().timeout(config.timeout);
    } on SocketException catch (e) {
      throw VtFailure.networkUnavailable(' ${e.osError?.message ?? ''}');
    } on TimeoutException {
      throw VtFailure.timeout(config.timeout);
    }
    onResponse(res);
    if (res.statusCode != 200) {
      final err = await res.transform(utf8.decoder).join();
      throw _failureForStatus(res.statusCode, err);
    }

    // Acumuladores por bloco (tool_use chega em input_json_delta parcial).
    final blockTypes = <int, String>{};
    final blockIds = <int, String>{};
    final blockNames = <int, String>{};
    final blockJson = <int, StringBuffer>{};

    try {
      await for (final line
          in res.transform(utf8.decoder).transform(const LineSplitter())) {
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
            final blk = (ev['content_block'] as Map?)?.cast<String, Object?>();
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
                break; // exposto apenas se habilitado em settings (não simulado)
            }
          case 'content_block_stop':
            final idx = (ev['index'] as num?)?.toInt() ?? 0;
            if (blockTypes[idx] == 'tool_use') {
              emit(ToolCallStartChunk(
                callId: blockIds[idx]?.isNotEmpty == true
                    ? blockIds[idx]!
                    : 'call_${DateTime.now().microsecondsSinceEpoch}',
                toolId: blockNames[idx] ?? '',
                argsJson: blockJson[idx]?.toString() ?? '{}',
              ));
            }
          case 'message_delta':
            final usage = (ev['usage'] as Map?)?.cast<String, Object?>();
            if (usage != null) {
              emit(UsageChunk(
                promptTokens: (usage['input_tokens'] as num?)?.toInt() ?? 0,
                completionTokens:
                    (usage['output_tokens'] as num?)?.toInt() ?? 0,
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
                  'Erro de streaming Anthropic: ${err?['type']}: ${err?['message']}',
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
  }

  Future<void> dispose() async {
    _client?.close(force: true);
    _client = null;
  }
}
