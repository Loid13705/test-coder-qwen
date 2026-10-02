/// Painel lateral direito de conversas — PERSISTENTE entre seções (spec §CHAT).
///
/// Vive no [VtShell], não dentro da tela Chat: trocar para Editor/Tools/Memória
/// não destrói a lista nem o scroll. Tudo aqui é REAL: as linhas vêm do
/// SQLite via `conversationListProvider`, e cada ação (pin, tag, renomear,
/// fork, arquivar, excluir com confirmação, restaurar, purgar) grava de volta
/// no banco — sem estado decorativo.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infrastructure/native/chat_records.dart'
    show kGlobalConversationWorkspace;
import '../state/app_state.dart';
import '../theme/vt_theme.dart';

class ConversationsPanel extends ConsumerStatefulWidget {
  const ConversationsPanel({super.key, this.width = 280});

  /// Largura preferida; o shell aplica clamp conforme a janela.
  final double width;

  @override
  ConsumerState<ConversationsPanel> createState() => ConversationsPanelState();
}

class ConversationsPanelState extends ConsumerState<ConversationsPanel> {
  final _scroll = ScrollController();
  bool collapsed = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void setCollapsed(bool v) => setState(() => collapsed = v);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    if (collapsed) {
      // Modo colapsado: barra fina com ações de cabeçalho + lista acessível
      // por tooltip/seleção (o estado das conversas continua vivo no
      // provider — nada aqui é decorativo).
      final items = ref.watch(conversationListProvider).items;
      final current = ref.watch(currentConversationIdProvider);
      return SizedBox(
        width: 40,
        child: Column(
          children: [
            IconButton(
              iconSize: 18,
              tooltip: 'Mostrar conversas',
              onPressed: () => setCollapsed(false),
              icon: Icon(Icons.menu_open, color: vt.accent),
            ),
            IconButton(
              iconSize: 16,
              tooltip: 'Nova conversa',
              onPressed: () => _runGuarded(() => ref
                  .read(conversationListProvider.notifier)
                  .create('Nova conversa')),
              icon: const Icon(Icons.add_comment_outlined),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: items.length > 30 ? 30 : items.length,
                itemBuilder: (context, i) {
                  final row = items[i];
                  final id = row['id'] as String;
                  return IconButton(
                    iconSize: 15,
                    isSelected: id == current,
                    tooltip: '${row['title'] ?? ''}',
                    onPressed: () => ref
                        .read(currentConversationIdProvider.notifier)
                        .state = id,
                    icon: Icon(
                      _isPinned(row)
                          ? Icons.push_pin
                          : Icons.chat_bubble_outline,
                      size: 15,
                      color: id == current ? vt.accent : theme.hintColor,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
    }

    final data = ref.watch(conversationListProvider);
    final current = ref.watch(currentConversationIdProvider);
    final notifier = ref.read(conversationListProvider.notifier);

    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 2, 4),
            child: Row(
              children: [
                Expanded(
                    child:
                        Text('Conversas', style: theme.textTheme.labelLarge)),
                IconButton(
                  iconSize: 16,
                  tooltip: 'Nova conversa',
                  onPressed: () =>
                      _runGuarded(() => notifier.create('Nova conversa')),
                  icon: const Icon(Icons.add_comment_outlined),
                ),
                IconButton(
                  iconSize: 16,
                  tooltip: 'Esconder painel',
                  onPressed: () => setCollapsed(true),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: SegmentedButton<ConversationScope>(
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 11),
              ),
              segments: const [
                ButtonSegment(
                    value: ConversationScope.currentWorkspace,
                    label: Text('Workspace')),
                ButtonSegment(
                    value: ConversationScope.global, label: Text('Global')),
                ButtonSegment(
                    value: ConversationScope.all, label: Text('Todas')),
              ],
              selected: {data.scope},
              onSelectionChanged: (s) =>
                  ref.read(conversationScopeProvider.notifier).state = s.first,
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
            child: Row(
              children: [
                Icon(Icons.filter_alt_outlined,
                    size: 14, color: theme.hintColor),
                const SizedBox(width: 6),
                DropdownButton<ConversationListFilter>(
                  key: ValueKey(data.filter),
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  borderRadius: BorderRadius.circular(6),
                  value: data.filter,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurface),
                  items: const [
                    DropdownMenuItem(
                        value: ConversationListFilter.active,
                        child: Text('Ativas')),
                    DropdownMenuItem(
                        value: ConversationListFilter.archived,
                        child: Text('Arquivadas')),
                    DropdownMenuItem(
                        value: ConversationListFilter.trash,
                        child: Text('Lixeira')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      ref.read(conversationFilterProvider.notifier).state =
                          ConversationFilterHolder(filter: v);
                    }
                  },
                ),
                const Spacer(),
                IconButton(
                  iconSize: 15,
                  tooltip: 'Recarregar lista',
                  onPressed: () =>
                      ref.read(conversationListProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: data.items.isEmpty
                ? Column(
                    children: [
                      const SizedBox(height: 60),
                      Icon(
                        switch (data.filter) {
                          ConversationListFilter.trash => Icons.delete_outline,
                          ConversationListFilter.archived =>
                            Icons.archive_outlined,
                          ConversationListFilter.active => Icons.forum_outlined,
                        },
                        size: 32,
                        color: theme.hintColor,
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: _EmptyHint(data: data),
                      ),
                    ],
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: data.items.length,
                    itemBuilder: (context, i) {
                      final row = data.items[i];
                      final id = row['id'] as String;
                      return _ConversationTile(
                        key: ValueKey('${data.filter.name}:$id'),
                        row: row,
                        filter: data.filter,
                        selected: id == current,
                        onSelect: () => ref
                            .read(currentConversationIdProvider.notifier)
                            .state = id,
                        notifier: notifier,
                      );
                    },
                  ),
          ),
          Divider(height: 1, color: theme.dividerColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Text(
              switch (data.scope) {
                ConversationScope.global =>
                  kGlobalConversationWorkspace.replaceAll('*', ''),
                ConversationScope.all => 'todos os workspaces',
                ConversationScope.currentWorkspace => data.workspaceId == null
                    ? 'nenhum workspace'
                    : _basename(data.workspaceId!),
              },
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
            ),
          ),
        ],
      ),
    );
  }

  String _basename(String p) {
    final n = p.replaceAll(RegExp(r'[\\/]+$'), '');
    final i = n.lastIndexOf(RegExp(r'[\\/]'));
    return i >= 0 ? n.substring(i + 1) : n;
  }

  static bool _isPinned(Map<String, Object?> row) =>
      row['pinned'] == 1 || row['pinned'] == true;

  void _runGuarded(String Function() action) {
    try {
      action();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$e'),
        backgroundColor: VtTheme.of(context).riskCritical,
      ));
    }
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.data});
  final ConversationListData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final msg = switch (data.filter) {
      ConversationListFilter.archived => 'Nada arquivado.',
      ConversationListFilter.trash => 'Lixeira vazia.',
      ConversationListFilter.active => data.workspaceId == null
          ? 'Abra um workspace em Workspaces para começar.'
          : 'Sem conversas ainda.',
    };
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(msg, style: theme.textTheme.bodySmall),
    );
  }
}

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({
    super.key,
    required this.row,
    required this.filter,
    required this.selected,
    required this.onSelect,
    required this.notifier,
  });

  final Map<String, Object?> row;
  final ConversationListFilter filter;
  final bool selected;
  final VoidCallback onSelect;
  final ConversationListNotifier notifier;

  String get _id => row['id'] as String;
  String get _title => '${row['title'] ?? '(sem título)'}';

  List<String> get _tags {
    final raw = row['tags'];
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final l = jsonDecode(raw);
      if (l is List) return [for (final e in l) '$e'];
    } on FormatException {
      // linha corrompida na coluna tags: mostra sem tags, mas NUNCA quebra a
      // lista inteira por causa de uma linha.
    }
    return const [];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final pinned = row['pinned'] == 1 || row['pinned'] == true;
    final folder = '${row['folder'] ?? ''}';
    final wsName = row['workspace_id'] == kGlobalConversationWorkspace
        ? 'global'
        : (row['workspace_id'] as String?)?.split(RegExp(r'[\\/]')).last ?? '';
    final when = filter == ConversationListFilter.trash
        ? '${row['deleted_at'] ?? row['updated_at'] ?? ''}'
        : filter == ConversationListFilter.archived
            ? '${row['archived_at'] ?? row['updated_at'] ?? ''}'
            : '${row['updated_at'] ?? ''}';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition, ref),
      child: ListTile(
        dense: true,
        selected: selected,
        leading: Icon(
          switch (filter) {
            ConversationListFilter.archived => Icons.archive_outlined,
            ConversationListFilter.trash => Icons.delete_outline,
            ConversationListFilter.active =>
              pinned ? Icons.push_pin : Icons.chat_bubble_outline,
          },
          size: 15,
          color: pinned && filter == ConversationListFilter.active
              ? vt.accent
              : theme.iconTheme.color,
        ),
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (folder.isNotEmpty) '/$folder',
            if (_tags.isNotEmpty) _tags.map((t) => '#$t').join(' '),
            if (filter == ConversationListFilter.active && wsName.isNotEmpty)
              wsName,
            when,
          ].where((s) => s.isNotEmpty).join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall,
        ),
        onTap: onSelect,
        trailing: PopupMenuButton<String>(
          iconSize: 16,
          tooltip: 'Ações da conversa',
          onSelected: (v) => _handle(context, ref, v),
          itemBuilder: (_) => _menuItems(),
        ),
      ),
    );
  }

  List<PopupMenuEntry<String>> _menuItems() {
    if (filter == ConversationListFilter.trash) {
      return const [
        PopupMenuItem(value: 'restore', child: Text('Restaurar')),
        PopupMenuItem(value: 'purge', child: Text('Apagar definitivamente…')),
      ];
    }
    return [
      PopupMenuItem(
          value: 'pin',
          child: Text(row['pinned'] == 1 ? 'Desafixar' : 'Fixar no topo')),
      const PopupMenuItem(value: 'rename', child: Text('Renomear')),
      const PopupMenuItem(value: 'tags', child: Text('Editar tags')),
      const PopupMenuItem(value: 'folder', child: Text('Mover para pasta')),
      if (filter == ConversationListFilter.active)
        const PopupMenuItem(value: 'fork', child: Text('Bifurcar (fork)')),
      if (filter == ConversationListFilter.active)
        const PopupMenuItem(value: 'archive', child: Text('Arquivar'))
      else
        const PopupMenuItem(value: 'unarchive', child: Text('Desarquivar')),
      const PopupMenuItem(value: 'delete', child: Text('Excluir…')),
    ];
  }

  void _showMenu(BuildContext context, Offset pos, WidgetRef ref) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: _menuItems(),
    ).then((v) {
      if (v != null) _handle(context, ref, v);
    });
  }

  Future<void> _handle(
      BuildContext context, WidgetRef ref, String action) async {
    final messenger = ScaffoldMessenger.of(context);
    final vt = VtTheme.of(context);
    void fail(Object e) => messenger.showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: vt.riskCritical));

    try {
      switch (action) {
        case 'pin':
          notifier.setPinned(_id, !(row['pinned'] == 1));
        case 'rename':
          final t = await _promptText(context, 'Renomear conversa', _title);
          if (t != null && t.trim().isNotEmpty) notifier.rename(_id, t.trim());
        case 'tags':
          final t = await _promptText(
              context, 'Tags (separadas por vírgula)', _tags.join(', '));
          if (t != null) {
            notifier.setTags(_id, [
              for (final x in t.split(','))
                if (x.trim().isNotEmpty) x.trim()
            ]);
          }
        case 'folder':
          final f =
              await _promptText(context, 'Pasta', '${row['folder'] ?? ''}');
          if (f != null) notifier.setFolder(_id, f.trim());
        case 'fork':
          notifier.fork(_id, '$_title (fork)');
        case 'archive':
          notifier.archive(_id);
        case 'unarchive':
          notifier.restore(_id);
        case 'delete':
          final ok = await _confirm(context, 'Excluir conversa',
              '“$_title” vai para a lixeira e pode ser restaurada depois.',
              confirmLabel: 'Excluir');
          if (ok) notifier.softDelete(_id);
        case 'restore':
          notifier.restore(_id);
        case 'purge':
          final ok = await _confirm(
              context,
              'Apagar DEFINITIVAMENTE',
              '“$_title” e todas as suas mensagens serão apagadas do banco. '
                  'Isto não tem volta.',
              confirmLabel: 'Apagar tudo',
              destructive: true);
          if (ok) notifier.purge(_id);
      }
    } catch (e) {
      fail(e);
    }
  }

  Future<bool> _confirm(BuildContext context, String title, String message,
      {required String confirmLabel, bool destructive = false}) async {
    final vt = VtTheme.of(context);
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: vt.riskCritical)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  Future<String?> _promptText(
      BuildContext context, String label, String initial) async {
    final ctrl = TextEditingController(text: initial);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label, style: const TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            onSubmitted: (s) => Navigator.pop(ctx, s),
            decoration: InputDecoration(labelText: label),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('OK')),
        ],
      ),
    );
    ctrl.dispose();
    return v;
  }
}
