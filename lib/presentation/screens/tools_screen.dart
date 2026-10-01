/// Tela de Tools — catálogo REAL do ToolRegistry (cada ferramenta registrada
/// de verdade no boot), com risco, política de aprovação e health check.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/tools/tool_contract.dart';
import '../state/app_state.dart';
import '../theme/vt_theme.dart';

/// Provider do ToolContext usado pelos health checks da tela — construído com
/// os objetos REAIS do app aberto (sandbox, settings, raízes da sessão).
final _toolHealthContextProvider = Provider<ToolContext>(
  (ref) => ToolContext(
    workspaceRoots: ref.watch(vtAppProvider).workspaceRoots,
    sandbox: ref.watch(vtAppProvider).sandbox,
    settings: ref.watch(settingsProvider),
  ),
);

class ToolsScreen extends ConsumerStatefulWidget {
  const ToolsScreen({super.key});

  @override
  ConsumerState<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends ConsumerState<ToolsScreen> {
  String _filter = '';
  ToolCategory? _categoryFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tools = ref.watch(toolRegistryProvider).all
      ..sort((a, b) => a.id.compareTo(b.id));

    final shown = tools.where((t) {
      if (_categoryFilter != null && t.category != _categoryFilter) {
        return false;
      }
      if (_filter.isEmpty) return true;
      final q = _filter.toLowerCase();
      return t.id.toLowerCase().contains(q) ||
          t.title.toLowerCase().contains(q) ||
          t.description.toLowerCase().contains(q);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Ferramentas', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${tools.length} ferramentas reais registradas nesta '
                      'sessão. Risco e aprovação vêm do contrato de cada tool.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 240,
                child: TextField(
                  onChanged: (v) => setState(() => _filter = v),
                  decoration: const InputDecoration(
                    hintText: 'Buscar tool…',
                    prefixIcon: Icon(Icons.search, size: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              _CategoryChip(
                label: 'todas',
                selected: _categoryFilter == null,
                onTap: () => setState(() => _categoryFilter = null),
              ),
              for (final c in ToolCategory.values)
                _CategoryChip(
                  label: c.name,
                  selected: _categoryFilter == c,
                  onTap: () => setState(() => _categoryFilter = c),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Divider(height: 1, color: theme.dividerColor),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text('Nenhuma tool casa com o filtro.',
                      style: theme.textTheme.bodyMedium))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: shown.length,
                  itemBuilder: (context, i) =>
                      _ToolTile(tool: shown[i]),
                ),
        ),
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.tool});
  final VtTool<ToolInput, ToolOutput> tool;

  Color _riskColor(VtColors vt) => switch (tool.risk) {
        RiskLevel.readOnly || RiskLevel.networkRead => vt.riskLow,
        RiskLevel.localWrite || RiskLevel.execute => vt.riskMedium,
        RiskLevel.externalWrite || RiskLevel.destructive => vt.riskHigh,
        RiskLevel.secret || RiskLevel.privileged => vt.riskCritical,
      };

  String _approvalLabel(ApprovalPolicyMode m) => switch (m) {
        ApprovalPolicyMode.auto => 'auto',
        ApprovalPolicyMode.reviewEach => 'aprova a cada uso',
        ApprovalPolicyMode.explicitApproval => 'aprovação explícita',
        ApprovalPolicyMode.typedConfirmation => 'confirmação tipada',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final risk = _riskColor(vt);
    final needsApproval = tool.defaultApproval != ApprovalPolicyMode.auto;

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(color: risk, shape: BoxShape.circle),
          ),
          Expanded(
            child: Text(tool.title,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          if (needsApproval)
            Icon(Icons.lock_outline, size: 14, color: theme.hintColor),
          const SizedBox(width: 8),
          _Tag(label: tool.risk.wire, color: risk),
          const SizedBox(width: 6),
          _Tag(
            label: _approvalLabel(tool.defaultApproval),
            color: needsApproval ? vt.riskMedium : vt.riskLow,
          ),
        ],
      ),
      subtitle: Text(tool.id,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tool.description, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _Tag(label: 'categoria: ${tool.category.name}',
                      color: theme.hintColor),
                  _Tag(label: tool.isIdempotent ? 'idempotente' : 'com efeito',
                      color: tool.isIdempotent ? vt.riskLow : vt.riskMedium),
                  _Tag(label: 'timeout ${tool.timeout.inSeconds}s',
                      color: theme.hintColor),
                  _Tag(
                      label:
                          'retry ${tool.retryPolicy.maxAttempts}x',
                      color: theme.hintColor),
                  for (final cap in tool.capabilities)
                    _Tag(label: 'cap: $cap', color: vt.accent),
                ],
              ),
              const SizedBox(height: 10),
              Text('Health check',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              _ToolHealthView(tool: tool),
            ],
          ),
        ),
      ],
    );
  }
}

/// Executa o health check REAL da tool (uma vez por expansão) usando o
/// ToolContext montado sobre sandbox/settings/raízes do app aberto.
class _ToolHealthView extends ConsumerStatefulWidget {
  const _ToolHealthView({required this.tool});
  final VtTool<ToolInput, ToolOutput> tool;

  @override
  ConsumerState<_ToolHealthView> createState() => _ToolHealthViewState();
}

class _ToolHealthViewState extends ConsumerState<_ToolHealthView> {
  late Future<ToolHealth?> _future = _run();

  Future<ToolHealth?> _run() async {
    try {
      final ctx = ref.read(_toolHealthContextProvider);
      return await widget.tool.health(ctx);
    } catch (_) {
      // Health check é best-effort na UI; falha aqui vira "sem dados",
      // nunca um status inventado.
      return null;
    }
  }

  @override
  void didUpdateWidget(covariant _ToolHealthView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tool != widget.tool) {
      _future = _run();
    }
  }

  IconData _icon(ToolHealth h) => switch (h) {
        HealthOk() => Icons.check_circle_outline,
        HealthMissingBinary() || HealthMissingSidecar() =>
          Icons.cancel_outlined,
        HealthUnconfigured() => Icons.settings_ethernet_outlined,
        HealthDegraded() => Icons.warning_amber_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    return FutureBuilder<ToolHealth?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final h = snap.data;
        if (h == null) {
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('health indisponível nesta sessão',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor)),
          );
        }
        final (label, color) = switch (h) {
          HealthOk(:final detail?) => ('operacional — $detail', vt.riskLow),
          HealthOk() => ('operacional', vt.riskLow),
          HealthMissingBinary(:final binary) => (
              'binário ausente: $binary',
              vt.riskCritical
            ),
          HealthMissingSidecar(:final sidecar) => (
              'sidecar ausente: $sidecar',
              vt.riskCritical
            ),
          HealthUnconfigured(:final what) => (
              'não configurado: $what',
              vt.riskMedium
            ),
          HealthDegraded(:final reason) => ('degradado: $reason', vt.riskHigh),
        };
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(_icon(h), size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label,
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: color)),
              ),
              IconButton(
                tooltip: 'Re-executar health check',
                icon: const Icon(Icons.refresh, size: 14),
                onPressed: () => setState(() => _future = _run()),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}
