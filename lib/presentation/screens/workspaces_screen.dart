/// Tela de Workspaces — lista REAL (raízes da sessão + recentWorkspaces do
/// settings.json), com foco, remoção e adição por caminho digitado ou picker.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/errors/vt_failure.dart';
import '../state/app_state.dart';
import '../theme/vt_theme.dart';

class WorkspacesScreen extends ConsumerWidget {
  const WorkspacesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final workspaces = ref.watch(workspaceListProvider);
    final focused = ref.watch(focusedWorkspacePathProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ScreenHeader(
          title: 'Workspaces',
          subtitle: 'Raízes acessíveis ao sandbox. Tools só operam aqui dentro.',
          actions: [
            FilledButton.icon(
              onPressed: () => _showAddDialog(context, ref),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Adicionar pasta'),
            ),
          ],
        ),
        Divider(height: 1, color: theme.dividerColor),
        Expanded(
          child: workspaces.isEmpty
              ? const _EmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: workspaces.length,
                  itemBuilder: (context, i) {
                    final ws = workspaces[i];
                    return _WorkspaceRow(
                      info: ws,
                      focused: ws.path == focused,
                      onFocus: () {
                        ref.read(currentWorkspacePathProvider.notifier).state =
                            ws.path;
                        // Trocar workspace troca o contexto de conversas.
                        ref.read(currentConversationIdProvider.notifier).state =
                            null;
                      },
                      onRemove: () async {
                        await ref
                            .read(workspaceListProvider.notifier)
                            .remove(ws.path);
                        if (ref.read(currentWorkspacePathProvider) ==
                            ws.path) {
                          ref
                              .read(currentWorkspacePathProvider.notifier)
                              .state = null;
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Adicionar workspace'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Caminho absoluto da pasta',
                  helperText:
                      'Ex.: /home/usuario/projetos/meu_app ou C:\\\\projetos\\\\meu_app',
                ),
                onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Escolher…'),
                onPressed: () async {
                  // Sem file_picker neste build: fallback honesto — pede o
                  // caminho digitado (o botão abre o diálogo de ajuda).
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                    content: Text(
                      'Neste build digite o caminho acima. O picker nativo '
                      'ativa junto com a dependência file_picker (ver '
                      'flutter_deps_commented.yaml).',
                    ),
                  ));
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Adicionar'),
          ),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    try {
      await ref.read(workspaceListProvider.notifier).add(path);
      ref.read(currentWorkspacePathProvider.notifier).state = path;
    } on VtFailure catch (f) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${f.code.wire}: ${f.message}'),
      ));
    }
  }
}

class _ScreenHeader extends StatelessWidget {
  const _ScreenHeader(
      {required this.title, required this.subtitle, this.actions = const []});
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor)),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class _WorkspaceRow extends StatelessWidget {
  const _WorkspaceRow(
      {required this.info,
      required this.focused,
      required this.onFocus,
      required this.onRemove});

  final WorkspaceInfo info;
  final bool focused;
  final VoidCallback onFocus;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    return Material(
      color: focused ? vt.accent.withValues(alpha: 0.08) : Colors.transparent,
      child: InkWell(
        onTap: onFocus,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              Icon(
                info.exists ? Icons.folder_outlined : Icons.folder_off_outlined,
                size: 18,
                color: info.exists ? theme.iconTheme.color : vt.riskCritical,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(info.name,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 8),
                        if (info.isGitRepo)
                          _Chip(
                              label: 'git', color: vt.riskLow, dense: true),
                        if (!info.exists)
                          _Chip(
                              label: 'ausente',
                              color: vt.riskCritical,
                              dense: true),
                        if (focused)
                          _Chip(label: 'em foco', color: vt.accent, dense: true),
                      ],
                    ),
                    const SizedBox(height: 2),
                    SelectableText(info.path,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: Colors.grey)),
                    if (info.lastOpenedAt != null)
                      Text(
                          'última modificação: '
                          '${info.lastOpenedAt!.toLocal().toString().substring(0, 19)}',
                          style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remover da lista',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: onRemove,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(
      {required this.label, required this.color, this.dense = false});
  final String label;
  final Color color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(right: dense ? 6 : 0),
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 6 : 8, vertical: dense ? 1 : 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(label,
          style: TextStyle(fontSize: dense ? 10 : 11, color: color)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_special_outlined,
              size: 40, color: theme.hintColor),
          const SizedBox(height: 10),
          Text('Nenhum workspace aberto.', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            'Adicione uma pasta para liberar as tools de arquivo/git no sandbox.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}
