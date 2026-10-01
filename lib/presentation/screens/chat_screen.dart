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

  /// Auto-scroll inteligente: cola no fundo durante o streaming, MAS se o
  /// usuário rolou para cima para reler, para de empurrá-lo (a posição dele
  /// é respeitada até ele voltar ao fundo ou enviar nova mensagem).
  bool _pinnedToBottom = true;

  void _stickToBottom() {
    if (!_pinnedToBottom) return;
    // Depois do frame, garante que a timeline acompanha o streaming.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _onScrollMetrics(ScrollMetrics m) {
    // 80px de tolerância: arredondamento de layout não "desgruda" por acaso.
    _pinnedToBottom = m.pixels >= m.maxScrollExtent - 80;
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
          child: NotificationListener<UserScrollNotification>(
            onNotification: (n) {
              // Scroll ativo do usuário (dedo/roda) reavalia o "pino" no
              // fundo; jumpTo programático não dispara UserScrollNotification.
              _onScrollMetrics(n.metrics);
              return false;
            },
            child: _RunBanner(
              live: live,
              maxIterations:
                  ref.read(chatServiceProvider).maxToolIterations,
              child: convId == null
                  ? const _EmptyChat()
                  : _Timeline(convId: convId, scroll: _scroll, live: live),
            ),
          ),
        ),
        const Divider(height: 1),
        const _Composer(),
      ],
    );
  }
}

/// Indicador discreto do estado REAL do run (running/ferramenta ativa),
/// fixado no topo da timeline — visível mesmo com o histórico longo.
class _RunBanner extends StatelessWidget {
  const _RunBanner(
      {required this.live, required this.maxIterations, required this.child});
  final ConversationState live;
  final int maxIterations;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final vt = VtTheme.of(context);
    final activeTools = live.pendingToolCalls.where((tc) {
      final s = live.toolOutcomes[tc.callId];
      return s == ToolCallStatus.executing || s == ToolCallStatus.approved;
    }).length;

    String? label;
    if (live.isBusy) {
      label = activeTools > 0
          ? 'executando $activeTools ferramenta(s) · rodada '
              '${live.toolIteration + 1}/$maxIterations'
          : live.streamingText.isNotEmpty
              ? 'gerando resposta…'
              : 'aguardando provider…';
    } else if (live.runStatus == RunStatus.cancelled) {
      label = 'run cancelado — parcial preservado';
    } else if (live.runStatus == RunStatus.failed) {
      label = 'run falhou';
    }
    if (label == null) return child;
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          color: vt.codeBackground.withOpacity(0.6),
          child: Row(
            children: [
              if (live.isBusy)
                SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: vt.accent))
              else
                Icon(live.runStatus == RunStatus.failed
                    ? Icons.error_outline
                    : Icons.info_outline, size: 12, color: vt.riskMedium),
              const SizedBox(width: 8),
              Text(label, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
        Expanded(child: child),
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          // Falha real de leitura do histórico: mensagem + retry — nunca
          // timeline vazia fingindo sucesso.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 28, color: vt.riskCritical),
              const SizedBox(height: 8),
              Text('Falha ao carregar histórico',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('$e',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Tentar novamente'),
                onPressed: () => ref.invalidate(messagesPageProvider(convId)),
              ),
            ],
          ),
        ),
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
              call: tc,
              status: live.toolOutcomes[tc.callId],
              resultText: live.toolResults[tc.callId],
              durationMs: live.toolDurationsMs[tc.callId],
            ),
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

  /// Timestamp REAL persistido (ISO-8601 UTC) → "HH:mm" local. Nada é
  /// estimado: parse falhou, simplesmente não mostra hora.
  static String? _clock(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return null;
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final isUser = record.role == 'user';
    final body = MessageBlocksView(blocks: record.blocks);
    final time = _clock(record.createdAt);
    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: body,
                ),
                if (time != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 4),
                    child: Text(time,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: Theme.of(context).hintColor)),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return _AssistantBubble(
      child: body,
      time: time,
      header: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (record.modelId != null)
            Text(record.modelId!,
                style: TextStyle(
                    fontSize: 10, color: Theme.of(context).hintColor)),
          if (record.status != 'complete') ...[
            if (record.modelId != null) const SizedBox(width: 8),
            Text(record.status,
                style: TextStyle(
                    fontSize: 10, color: VtTheme.of(context).riskMedium)),
          ],
        ],
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble(
      {required this.child, this.header, this.trailing, this.time});
  final Widget child;
  final Widget? header;
  final Widget? trailing;
  final String? time;

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
                  if (time != null) ...[
                    const SizedBox(width: 6),
                    Text(time!,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.hintColor)),
                  ],
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
  const _LiveToolCallCard({
    required this.call,
    required this.status,
    this.resultText,
    this.durationMs,
  });
  final ToolCallStartChunk call;
  final ToolCallStatus? status;

  /// Resultado REAL já observado desta execução (chegou do executor via
  /// ConversationState.toolResults) — antes disso só entrada + spinner.
  final String? resultText;
  final int? durationMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Mesma linguagem visual do card persistido (toolCallVisual é a fonte
    // única de ícone/cor/label dos seis ToolCallStatus).
    final (icon, color, label) =
        toolCallVisual(context, status, status != null);
    // Args parciais chegam em pedaços pelo stream: mostra cru até virar JSON
    // válido (indentado) — nunca esconde o que chegou nem inventa closing.
    final prettyArgs = () {
      try {
        return const JsonEncoder.withIndent('  ')
            .convert(jsonDecode(call.argsJson));
      } catch (_) {
        return call.argsJson;
      }
    }();
    final hasResult = (resultText ?? '').isNotEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.6)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              status == ToolCallStatus.executing
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: color))
                  : Icon(icon, size: 15, color: color),
              const SizedBox(width: 8),
              // toolId arbitrário (do provider) — Flexible+ellipsis para não
              // estourar o card em janelas estreitas.
              Flexible(
                child: Text(call.toolId,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12)),
              ),
              if (durationMs != null) ...[
                const SizedBox(width: 8),
                Text('${durationMs}ms',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.hintColor)),
              ],
              const SizedBox(width: 8),
              Text(status == null ? 'aguardando stream…' : label,
                  style: theme.textTheme.labelSmall?.copyWith(color: color)),
            ],
          ),
          // args parcialmente transmitidos são observáveis sob demanda —
          // essencial p/ auditar o que o modelo realmente pediu.
          if (prettyArgs.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(
              prettyArgs,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontFamily: 'monospace', fontSize: 10.5),
            ),
          ],
          if (hasResult) ...[
            const SizedBox(height: 4),
            Text('resultado (real)',
                style: theme.textTheme.labelSmall?.copyWith(color: color)),
            SelectableText(
              resultText!,
              maxLines: 12,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5),
            ),
          ],
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
