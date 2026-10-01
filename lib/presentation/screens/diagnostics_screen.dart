/// Tela de Diagnóstico — renderiza o [healthReportProvider]: checagens REAIS
/// (banco, workspaces, providers via healthCheck HTTP, registro de tools).
/// Nunca esconde falha: cada erro aparece com código wire e ação de recovery.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_state.dart';
import '../theme/vt_theme.dart';

class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final report = ref.watch(healthReportProvider);

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
                    Text('Diagnóstico', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      'Checagens executadas nesta sessão contra os componentes '
                      'reais do app.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _SummaryBadges(
                    vt: vt, report: report.valueOrNull),
              ),
              const SizedBox(width: 10),
              IconButton(
                tooltip: 'Re-executar checagens',
                icon: const Icon(Icons.refresh),
                onPressed: () => ref.invalidate(healthReportProvider),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.dividerColor),
        Expanded(
          child: switch (report) {
            AsyncData(:final value) => _ReportList(report: value),
            AsyncError(:final error, :final stackTrace) => _RunFailure(
                title: 'As checagens de saúde não puderam rodar',
                detail: '$error\n$stackTrace',
              ),
            AsyncLoading() => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              ),
            _ => const SizedBox.shrink(),
          },
        ),
      ],
    );
  }
}

class _SummaryBadges extends StatelessWidget {
  const _SummaryBadges({required this.vt, required this.report});
  final VtColors vt;
  final HealthReport? report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    if (r == null) return const SizedBox.shrink();
    final okCount = r.entries.length - r.errors - r.warnings;
    return Wrap(
      spacing: 6,
      children: [
        _Badge(label: '$okCount ok', color: vt.riskLow),
        if (r.warnings > 0)
          _Badge(label: '${r.warnings} avisos', color: vt.riskMedium),
        if (r.errors > 0)
          _Badge(label: '${r.errors} erros', color: vt.riskCritical),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

class _ReportList extends StatelessWidget {
  const _ReportList({required this.report});
  final HealthReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    // Erros primeiro — diagnóstico útil mostra o que dói antes do resto.
    final sorted = [...report.entries]
      ..sort((a, b) => _rank(a.status).compareTo(_rank(b.status)));
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: sorted.length,
      itemBuilder: (context, i) {
        final e = sorted[i];
        final (color, icon) = switch (e.status) {
          'ok' => (vt.riskLow, Icons.check_circle_outline),
          'warn' => (vt.riskMedium, Icons.warning_amber_rounded),
          _ => (vt.riskCritical, Icons.error_outline),
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.name,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(e.detail, style: theme.textTheme.bodySmall),
                    if (e.setupUri != null && e.status != 'ok')
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: SelectableText(e.setupUri!,
                            style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: Colors.grey)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  int _rank(String status) => switch (status) {
        'error' => 0,
        'warn' => 1,
        _ => 2,
      };
}

class _RunFailure extends StatelessWidget {
  const _RunFailure({required this.title, required this.detail});
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.error_outline, color: vt.riskCritical),
                  const SizedBox(width: 8),
                  Text(title, style: theme.textTheme.titleSmall),
                ],
              ),
              const SizedBox(height: 10),
              SingleChildScrollView(
                child: SelectableText(
                  detail.trim(),
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
