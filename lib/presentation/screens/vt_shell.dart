/// Shell principal do techVT (desktop-first, spec §UI):
/// rail de seções + área de conteúdo por [UiSection].
///
/// O gate de boot vive aqui: nada abaixo de [VtShell] lê [vtAppProvider]
/// sem um boot real bem-sucedido. Falha de boot é exibida como VtFailure
/// tipado com ações concretas — nunca uma tela "vazia fingindo sucesso".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/errors/vt_failure.dart';
import '../state/app_state.dart';
import '../theme/vt_theme.dart';
import 'chat_screen.dart';
import 'diagnostics_screen.dart';
import 'memory_screen.dart';
import 'settings_screen.dart';
import 'tools_screen.dart';
import 'workspaces_screen.dart';

class VtShell extends ConsumerStatefulWidget {
  const VtShell({super.key});

  @override
  ConsumerState<VtShell> createState() => _VtShellState();
}

class _VtShellState extends ConsumerState<VtShell> {
  /// Contexto estável da raiz do shell para os dialogs de aprovação.
  BuildContext rootContext() => context;

  @override
  Widget build(BuildContext context) {
    final boot = ref.watch(bootProvider);
    final section = ref.watch(sectionProvider);
    final vt = VtTheme.of(context);

    if (boot is Booting) return const _BootSplash();
    if (boot is BootFailed) {
      return _BootFailedView(
        failure: boot.failure,
        onRetry: () =>
            ref.read(bootProvider.notifier).retry(rootContext),
      );
    }

    // BootSuccess: núcleo real aberto.
    final workspace = ref.watch(focusedWorkspacePathProvider);

    return Scaffold(
      body: Row(
        children: [
          _SideRail(
            section: section,
            onSelect: (s) =>
                ref.read(sectionProvider.notifier).state = s,
            workspaceName: workspace == null
                ? 'sem workspace'
                : workspace
                    .replaceAll(RegExp(r'[\\/]+$'), '')
                    .split(RegExp(r'[\\/]'))
                    .last,
          ),
          VerticalDivider(width: 1, color: vt.sidebar),
          Expanded(
            child: switch (section) {
              UiSection.chat => const ChatScreen(),
              UiSection.workspaces => const WorkspacesScreen(),
              UiSection.tools => const ToolsScreen(),
              UiSection.memory => const MemoryScreen(),
              UiSection.diagnostics => const DiagnosticsScreen(),
              UiSection.settings => const SettingsScreen(),
            },
          ),
        ],
      ),
    );
  }
}

class _SideRail extends StatelessWidget {
  const _SideRail(
      {required this.section,
      required this.onSelect,
      required this.workspaceName});

  final UiSection section;
  final ValueChanged<UiSection> onSelect;
  final String workspaceName;

  static const _items = <(UiSection, IconData, String)>[
    (UiSection.chat, Icons.forum_outlined, 'Chat'),
    (UiSection.workspaces, Icons.folder_outlined, 'Workspaces'),
    (UiSection.tools, Icons.build_outlined, 'Tools'),
    (UiSection.memory, Icons.psychology_outlined, 'Memória'),
    (UiSection.diagnostics, Icons.monitor_heart_outlined, 'Diagnóstico'),
    (UiSection.settings, Icons.settings_outlined, 'Ajustes'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    return Container(
      width: 208,
      color: vt.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: vt.accent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Text('VT',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: theme.colorScheme.onPrimary)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('techVT',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.dividerColor),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (final (sec, icon, label) in _items)
                  _RailItem(
                    icon: icon,
                    label: label,
                    selected: sec == section,
                    onTap: () => onSelect(sec),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.dividerColor),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Icon(Icons.folder_open, size: 14, color: theme.hintColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(workspaceName,
                      style: theme.textTheme.labelSmall,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem(
      {required this.icon,
      required this.label,
      required this.selected,
      required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    return Material(
      color: selected ? vt.accent.withValues(alpha: 0.12) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            children: [
              Icon(icon,
                  size: 17,
                  color: selected ? vt.accent : theme.iconTheme.color),
              const SizedBox(width: 10),
              Text(label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : null,
                      color: selected ? vt.accent : null)),
            ],
          ),
        ),
      ),
    );
  }
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 26, height: 26, child: CircularProgressIndicator()),
            SizedBox(height: 14),
            Text('Abrindo núcleo local (SQLite FFI, sandbox, tools)…',
                style: TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _BootFailedView extends StatelessWidget {
  const _BootFailedView({required this.failure, required this.onRetry});
  final VtFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.dangerous_outline,
                          color: vt.riskCritical, size: 22),
                      const SizedBox(width: 8),
                      Text('O app não abriu — falha real no boot',
                          style: theme.textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SelectableText('${failure.code.wire}: ${failure.message}',
                      style: theme.textTheme.bodyMedium),
                  if (failure.setupUri != null) ...[
                    const SizedBox(height: 6),
                    SelectableText(failure.setupUri!,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                  ],
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Tentar novamente'),
                      ),
                      for (final a in failure.recoveryActions)
                        OutlinedButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.build_circle_outlined),
                          label: Text(a.label),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
