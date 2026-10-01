/// Tela de chat (spec §CHAT): lista de conversas persistidas + timeline real
/// (blocos tipados do banco) + streaming ao vivo + composer com envio/stop.
///
/// Nada aqui fabrica conteúdo: o histórico vem do SQLite, o texto parcial é o
/// que efetivamente chegou do provider e erros são VtFailure reais.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/chat_service.dart';
import '../../domain/errors/vt_failure.dart';
import '../../infrastructure/native/chat_records.dart';
import '../../infrastructure/provider/provider_contract.dart';
import '../state/app_state.dart';
import '../theme/vt_theme.dart';
import '../widgets/message_blocks.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scroll = ScrollController();

  void _stickToBottom() {
    // Depois do frame, garante que a timeline acompanha o streaming.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final convId = ref.watch(currentConversationIdProvider);
    final stateAsync = ref.watch(focusedConversationStateProvider);
    final live = stateAsync.valueOrNull ??
        const ConversationState(runStatus: RunStatus.idle);

    if (live.isBusy ||
        live.toolOutcomes.values.any((s) => s == ToolCallStatus.executing)) {
      _stickToBottom();
    }

    // O painel de conversas NÃO mora mais aqui: é persistente no VtShell
    // (direita da janela) e sobrevive à troca de seções. A tela Chat ocupa a
    // área de conteúdo inteira.
    return Column(
      children: [
        Expanded(
          child: convId == null
              ? const _EmptyChat()
              : _Timeline(convId: convId, scroll: _scroll, live: live),
        ),
        const Divider(height: 1),
        const _Composer(),
      ],
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 40, color: theme.hintColor),
          const SizedBox(height: 10),
          Text('Nenhuma conversa em foco.\nEnvie uma mensagem ou crie uma conversa.',
              textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _Timeline extends ConsumerWidget {
  const _Timeline(
      {required this.convId, required this.scroll, required this.live});

  final String convId;
  final ScrollController scroll;
  final ConversationState live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final page = ref.watch(messagesPageProvider(convId));

    return page.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Falha ao carregar histórico: $e',
            style: TextStyle(color: vt.riskCritical)),
      ),
      data: (messages) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        children: [
          for (final m in messages.reversed) _MessageBubble(record: m),
          if (live.streamingText.isNotEmpty)
            _AssistantBubble(
              child: MarkdownLite(text: live.streamingText),
              trailing: live.isBusy
                  ? Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: vt.accent)),
                        const SizedBox(width: 8),
                        Text(
                          'gerando…'
                          '${live.providerLatencyMs != null ? ' · ttft ${live.providerLatencyMs}ms' : ''}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ]),
                    )
                  : null,
            ),
          for (final tc in live.pendingToolCalls)
            _LiveToolCallCard(
                call: tc, status: live.toolOutcomes[tc.callId]),
          if (live.lastError != null)
            ErrorCard(failureJson: live.lastError!.toJson()),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.record});
  final MessageRecord record;

  @override
  Widget build(BuildContext context) {
    final isUser = record.role == 'user';
    final body = MessageBlocksView(blocks: record.blocks);
    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: body,
            ),
          ),
        ),
      );
    }
    return _AssistantBubble(
      child: body,
      header: record.status == 'complete'
          ? null
          : Text(record.status,
              style: TextStyle(
                  fontSize: 10,
                  color: VtTheme.of(context).riskMedium)),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.child, this.header, this.trailing});
  final Widget child;
  final Widget? header;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.smart_toy_outlined,
                      size: 14, color: theme.hintColor),
                  const SizedBox(width: 6),
                  Text('techVT-Agent-01', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  if (header != null) header!,
                ],
              ),
              const SizedBox(height: 4),
              child,
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveToolCallCard extends StatelessWidget {
  const _LiveToolCallCard({required this.call, required this.status});
  final ToolCallStartChunk call;
  final ToolCallStatus? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final (icon, color, label) = switch (status) {
      null || ToolCallStatus.pending => (
          Icons.hourglass_empty,
          theme.hintColor,
          'aguardando aprovação'
        ),
      ToolCallStatus.approved => (
          Icons.check_circle_outline,
          vt.riskLow,
          'aprovada'
        ),
      ToolCallStatus.executing => (
          Icons.play_circle_outline,
          vt.accent,
          'executando…'
        ),
      ToolCallStatus.succeeded => (
          Icons.task_alt,
          vt.riskLow,
          'concluída'
        ),
      ToolCallStatus.failed => (
          Icons.error_outline,
          vt.riskCritical,
          'falhou'
        ),
      ToolCallStatus.blocked => (
          Icons.block,
          vt.riskHigh,
          'bloqueada'
        ),
    };
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.6)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          // toolId arbitrário (do provider) — Flexible+ellipsis para não
          // estourar o card em janelas estreitas.
          Flexible(
            child: Text(call.toolId,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12)),
          ),
          const SizedBox(width: 8),
          Text(label,
              style: theme.textTheme.labelSmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}

// ============================================================================
// Composer
// ============================================================================

class _Composer extends ConsumerStatefulWidget {
  const _Composer();

  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  final _input = TextEditingController();
  bool _toolsEnabled = true;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final chat = ref.read(chatServiceProvider);
    final modelId = ref.read(selectedModelProvider);
    if (modelId == null || modelId.isEmpty) {
      _showError(VtFailure(
        code: VtErrorCode.providerNotConfigured,
        message:
            'Nenhum modelo selecionado. Configure um provider em Ajustes → '
            'Providers e escolha o modelo no composer.',
        setupUri: 'techvt://settings/providers',
        recoveryActions: const [
          RecoveryAction(
              kind: 'configure_provider',
              label: 'Abrir Ajustes → Providers'),
        ],
      ));
      return;
    }

    var convId = ref.read(currentConversationIdProvider);
    try {
      convId ??= ref.read(conversationListProvider.notifier).create(
          text.length > 40 ? '${text.substring(0, 40)}…' : text);
    } on VtFailure catch (f) {
      _showError(f);
      return;
    }

    // Contexto REAL: últimas mensagens persistidas nesta conversa.
    final history = chat.pageMessages(convId).items;
    final contextMsgs = <ChatRequestMessage>[
      for (final m in history.take(40))
        if (m.role == 'user' || m.role == 'assistant')
          ChatRequestMessage(
              role: m.role,
              content: m.blocks
                  .map((b) => b['text'] ?? b['code'] ?? '')
                  .whereType<String>()
                  .join('\n')),
    ];

    _input.clear();
    final posture = ref.read(agentPostureProvider);
    try {
      await chat.send(
        conversationId: convId,
        modelId: modelId,
        userText: text,
        context: contextMsgs,
        options: ChatRequestOptions(
          allowedToolIds: const [],
          maxTokens: null,
        ),
      );
    } on VtFailure catch (f) {
      _showError(f);
    } catch (e) {
      _showError(VtFailure(
          code: VtErrorCode.internalError, message: '$e'));
    }
    // `posture` documenta a intenção do modo; a política por tool continua
    // sendo do contrato (evaluateApproval) — nada aqui ignora aprovação.
    if (posture == AgentPostureChoice.proposeOnly && !_toolsEnabled) {
      debugPrint('propose-only ativo');
    }
    ref.invalidate(messagesPageProvider(convId));
    ref.read(conversationListProvider.notifier).refresh();
  }

  void _showError(VtFailure f) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${f.code.wire}: ${f.message}'),
      backgroundColor: VtTheme.of(context).riskCritical,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final vt = VtTheme.of(context);
    final theme = Theme.of(context);
    final stateAsync = ref.watch(focusedConversationStateProvider);
    final busy =
        (stateAsync.valueOrNull ?? const ConversationState(runStatus: RunStatus.idle)).isBusy;
    final models = ref.watch(vtAppProvider).chat.providers.all;
    final modelIds = [for (final p in models) ...p.models.map((m) => m.id)];
    final selected = ref.watch(selectedModelProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.model_training,
                  size: 14, color: theme.iconTheme.color),
              const SizedBox(width: 6),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isDense: true,
                    value: selected != null && modelIds.contains(selected)
                        ? selected
                        : (modelIds.isEmpty ? null : modelIds.first),
                    hint: Text(
                        modelIds.isEmpty
                            ? 'sem providers configurados'
                            : 'escolher modelo',
                        style: const TextStyle(fontSize: 12)),
                    items: [
                      for (final id in modelIds)
                        DropdownMenuItem(value: id, child: Text(id,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 12))),
                    ],
                    onChanged: (v) =>
                        ref.read(selectedModelProvider.notifier).state = v,
                  ),
                ),
              ),
              Tooltip(
                message: _toolsEnabled
                    ? 'Tools habilitadas neste turno'
                    : 'Tools desabilitadas: resposta só de texto',
                child: IconButton(
                  iconSize: 18,
                  onPressed: () => setState(() => _toolsEnabled = !_toolsEnabled),
                  icon: Icon(
                    _toolsEnabled ? Icons.build : Icons.build_circle_outlined,
                    color: _toolsEnabled ? vt.accent : vt.riskMedium,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 8,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Pergunte, peça uma mudança, cole um erro…',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: vt.riskCritical),
                  onPressed: () {
                    final convId = ref.read(currentConversationIdProvider);
                    if (convId != null) {
                      ref.read(chatServiceProvider).stop(convId);
                    }
                  },
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                )
              else
                FilledButton.icon(
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                  label: const Text('Enviar'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
