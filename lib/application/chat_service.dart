/// Camada de aplicação do chat com streaming REAL.
///
/// - Consome `Stream<StreamChunk>` do provider (nunca Future.delayed/typing fake).
/// - `stop()` cancela a requisição HTTP real via StreamHandle e preserva o
///   texto parcial que efetivamente chegou.
/// - Persistência local-first em SQLite via ChatRepository, com paginação
///   cursor-based (Page<T>) — nada de estado apenas em memória fingindo carga.
library;

import 'dart:async';
import 'dart:convert';

import '../domain/errors/vt_failure.dart';
import '../domain/models/pagination.dart';
import '../infrastructure/native/chat_records.dart';
import '../infrastructure/native/sqlite_native.dart';
import '../infrastructure/provider/provider_contract.dart';

enum RunStatus { idle, running, completed, failed, cancelled }

/// Estado observável de uma conversa no composer/UI. Imutável por emissão.
class ConversationState {
  const ConversationState({
    required this.runStatus,
    this.streamingText = '',
    this.pendingToolCalls = const [],
    this.lastUsage,
    this.lastError,
    this.providerLatencyMs,
  });

  final RunStatus runStatus;

  /// Texto parcial REAL recebido até agora (preservado em cancelamento).
  final String streamingText;
  final List<ToolCallStartChunk> pendingToolCalls;
  final TokenUsage? lastUsage;
  final VtFailure? lastError;

  /// Latência medida real (TTFT) entre envio e primeiro delta.
  final int? providerLatencyMs;

  bool get isBusy => runStatus == RunStatus.running;
}

/// Registro de providers configurados. Na inicialização real é populado a
/// partir de settings + secure storage; começa VAZIO (sem provider "conectado"
/// por padrão).
class ProviderRegistry {
  final Map<String, LlmProvider> _byId = {};

  void register(LlmProvider p) => _byId[p.id] = p;
  void unregister(String id) => _byId.remove(id);
  LlmProvider? byId(String id) => _byId[id];
  List<LlmProvider> get all => _byId.values.toList(growable: false);

  LlmProvider require(String id) {
    final p = _byId[id];
    if (p == null) {
      throw VtFailure(
        code: VtErrorCode.providerNotConfigured,
        message: 'Provider "$id" não está registrado/configurado.',
        setupUri: 'techvt://settings/providers/$id',
        recoveryActions: const [
          RecoveryAction(
              kind: 'configure_provider',
              label: 'Adicionar provider em Settings → AI Providers'),
        ],
      );
    }
    return p;
  }

  ModelInfo? findModel(String modelId) {
    for (final p in _byId.values) {
      for (final m in p.models) {
        if (m.id == modelId) return m;
      }
    }
    // fallback: catálogo conhecido mesmo sem provider ativo (para badges),
    // mas NUNCA para enviar requests (require() falha antes disso).
    return kKnownModels.where((m) => m.id == modelId).firstOrNull;
  }
}

/// Serviço de chat: orquestra provider real + persistência local + streaming.
class ChatService {
  ChatService({required SqliteDb db, required this.providers})
      : repo = ChatRepository(db);

  final ChatRepository repo;
  final ProviderRegistry providers;

  final _states = <String, ConversationState>{};
  final _stateCtrl = StreamController<(String, ConversationState)>.broadcast();
  final _activeHandles = <String, StreamHandle>{};

  Stream<(String conversationId, ConversationState state)> get states =>
      _stateCtrl.stream;

  ConversationState stateOf(String conversationId) =>
      _states[conversationId] ??
      const ConversationState(runStatus: RunStatus.idle);

  void _emit(String convId, ConversationState s) {
    _states[convId] = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add((convId, s));
  }

  // ---------- Conversas / mensagens (persistidas localmente) ----------

  String createConversation(
          {required String workspaceId,
          required String title,
          String? parentId}) =>
      repo.createConversation(
          workspaceId: workspaceId, title: title, parentId: parentId);

  List<Map<String, Object?>> listConversations(String workspaceId,
          {int limit = 50}) =>
      repo.listConversations(workspaceId, limit: limit);

  /// Histórico paginado cursor-based (spec: chat 50 msgs/página default).
  Page<MessageRecord> pageMessages(String conversationId,
          {String? beforeId, int pageSize = 50}) =>
      repo.pageMessages(conversationId, beforeId: beforeId, pageSize: pageSize);

  // ---------- Streaming ----------

  /// Envia a mensagem ao provider REAL e faz stream dos chunks. Erro do
  /// provider é erro real (VtFailure tipado) — nunca conteúdo fabricado.
  Future<void> send({
    required String conversationId,
    required String modelId,
    required String userText,
    required List<ChatRequestMessage> context,
    List<Map<String, Object?>> toolSchemas = const [],
    ChatRequestOptions options = const ChatRequestOptions(),
  }) async {
    final existing = _activeHandles[conversationId];
    if (existing != null && !existing.isCancelled) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Já existe um stream ativo nesta conversa. Use stop() antes.',
      );
    }
    final model = providers.findModel(modelId);
    final provider =
        providers.require(model?.providerId ?? _providerIdOf(modelId));

    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    repo.insertMessage(
      id: 'msg_$nowMicros',
      conversationId: conversationId,
      role: 'user',
      blocksJson: jsonEncode([
        {'type': 'text', 'text': userText}
      ]),
      status: 'complete',
      createdAt: nowIso,
    );
    repo.touchConversation(conversationId);
    final assistantId = 'msg_${nowMicros + 1}';

    _emit(
        conversationId, const ConversationState(runStatus: RunStatus.running));

    final textBuf = StringBuffer();
    final toolCalls = <ToolCallStartChunk>[];
    var usage = const TokenUsage();
    final sw = Stopwatch()..start();
    var ttftMs = 0;

    StreamHandle? h;
    final stream = provider.streamChat(
      modelId: modelId,
      messages: context,
      options: options,
      toolSchemas: toolSchemas,
      onHandle: (hh) => h = hh,
    );
    // O handle chega de forma síncrona via callback onHandle; registramos já.
    _activeHandles[conversationId] = h ?? StreamHandle.noop();

    var finishStatus = RunStatus.completed;
    VtFailure? failure;
    try {
      await for (final chunk in stream) {
        switch (chunk) {
          case DeltaChunk(:final text):
            if (ttftMs == 0) ttftMs = sw.elapsedMilliseconds;
            textBuf.write(text);
            _emit(
                conversationId,
                ConversationState(
                  runStatus: RunStatus.running,
                  streamingText: textBuf.toString(),
                  pendingToolCalls: List.of(toolCalls),
                  lastUsage: usage.total > 0 ? usage : null,
                  providerLatencyMs: ttftMs,
                ));
          case ToolCallStartChunk():
            toolCalls.add(chunk);
            _emit(
                conversationId,
                ConversationState(
                  runStatus: RunStatus.running,
                  streamingText: textBuf.toString(),
                  pendingToolCalls: List.of(toolCalls),
                  lastUsage: usage.total > 0 ? usage : null,
                  providerLatencyMs: ttftMs > 0 ? ttftMs : null,
                ));
          case UsageChunk():
            usage = usage.merge(chunk);
          case DoneChunk(:final finishReason):
            finishStatus =
                finishReason == 'cancelled' || (h?.isCancelled ?? false)
                    ? RunStatus.cancelled
                    : RunStatus.completed;
          case ErrorChunk():
            failure = chunk.failure;
            finishStatus = RunStatus.failed;
        }
      }
    } on VtFailure catch (f) {
      failure = f;
      finishStatus = RunStatus.failed;
    } finally {
      _activeHandles.remove(conversationId);
    }

    // Persiste exatamente o que chegou (parcial preservado em cancel/falha).
    final blocks = <Map<String, Object?>>[
      if (textBuf.isNotEmpty) {'type': 'markdown', 'text': textBuf.toString()},
      for (final tc in toolCalls)
        {
          'type': 'tool_call',
          'callId': tc.callId,
          'toolId': tc.toolId,
          'argsJson': tc.argsJson,
        },
      if (failure != null) {'type': 'error', ...failure.toJson()},
    ];
    repo.insertMessage(
      id: assistantId,
      conversationId: conversationId,
      role: 'assistant',
      modelId: modelId,
      mode: 'chat',
      blocksJson: jsonEncode(blocks),
      status: switch (finishStatus) {
        RunStatus.cancelled => 'cancelled_partial',
        RunStatus.failed => 'failed',
        _ => 'complete',
      },
      usageJson: usage.total > 0
          ? jsonEncode({
              'prompt_tokens': usage.promptTokens,
              'completion_tokens': usage.completionTokens,
            })
          : null,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    repo.touchConversation(conversationId);
    _emit(
        conversationId,
        ConversationState(
          runStatus: finishStatus,
          streamingText: textBuf.toString(),
          pendingToolCalls: toolCalls,
          lastUsage: usage.total > 0 ? usage : null,
          lastError: failure,
          providerLatencyMs: ttftMs > 0 ? ttftMs : null,
        ));
  }

  /// STOP REAL: aborta a conexão HTTP; o parcial já emitido fica no estado e
  /// é persistido com status `cancelled_partial`.
  Future<void> stop(String conversationId) async {
    final h = _activeHandles[conversationId];
    if (h == null) return;
    await h.stop();
  }

  String _providerIdOf(String modelId) {
    final m = kKnownModels.where((k) => k.id == modelId).firstOrNull;
    if (m != null) return m.providerId;
    throw VtFailure(
      code: VtErrorCode.providerNotConfigured,
      message: 'Modelo "$modelId" desconhecido e sem provider associado.',
      setupUri: 'techvt://settings/models',
      recoveryActions: const [
        RecoveryAction(kind: 'switch_model', label: 'Trocar modelo'),
        RecoveryAction(
            kind: 'configure_provider', label: 'Configurar provider'),
      ],
    );
  }

  Future<void> dispose() async {
    for (final h in _activeHandles.values) {
      await h.stop();
    }
    _activeHandles.clear();
    await _stateCtrl.close();
  }
}
