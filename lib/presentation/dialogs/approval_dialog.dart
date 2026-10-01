/// Diálogo real de aprovação de tools (spec §APROVAÇÃO).
///
/// Implementa [ApprovalGateway]: enquanto o diálogo estiver aberto, o tool
/// loop espera. Sem resposta (fechar janela) = REJEITADO — nunca aprovado
/// por default.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../application/approval.dart';
import '../../domain/tools/tool_contract.dart';
import '../theme/vt_theme.dart';

Color riskColor(BuildContext context, RiskLevel risk) {
  final c = VtTheme.of(context);
  return switch (risk) {
    RiskLevel.readOnly || RiskLevel.networkRead => c.riskLow,
    RiskLevel.localWrite || RiskLevel.execute => c.riskMedium,
    RiskLevel.externalWrite || RiskLevel.destructive => c.riskHigh,
    RiskLevel.secret || RiskLevel.privileged => c.riskCritical,
  };
}

String riskLabel(RiskLevel risk) => switch (risk) {
      RiskLevel.readOnly => 'somente leitura',
      RiskLevel.networkRead => 'leitura de rede',
      RiskLevel.localWrite => 'escrita local',
      RiskLevel.execute => 'execução',
      RiskLevel.externalWrite => 'escrita externa',
      RiskLevel.destructive => 'destrutiva',
      RiskLevel.secret => 'segredo',
      RiskLevel.privileged => 'privilegiada',
    };

Future<ApprovalDecision?> showApprovalDialog(
        BuildContext context, ApprovalRequest req) =>
    showDialog<ApprovalDecision>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ApprovalDialog(request: req),
    );

class ApprovalDialog extends StatefulWidget {
  const ApprovalDialog({super.key, required this.request});
  final ApprovalRequest request;

  @override
  State<ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<ApprovalDialog> {
  final _reason = TextEditingController();
  bool _confirmDestructive = false;

  bool get _needsTypedConfirm =>
      widget.request.risk == RiskLevel.destructive ||
      widget.request.risk == RiskLevel.privileged;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _decide(ApprovalOutcome outcome) {
    Navigator.of(context).pop(ApprovalDecision(outcome,
        reason: _reason.text.isEmpty ? null : _reason.text));
  }

  @override
  Widget build(BuildContext context) {
    final req = widget.request;
    final theme = Theme.of(context);
    final rc = riskColor(context, req.risk);
    final preview = const JsonEncoder.withIndent('  ').convert(req.preview);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: rc),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Aprovação necessária: ${req.title}',
                style: theme.textTheme.titleMedium),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(spacing: 8, children: [
                _chip('tool: ${req.toolId}', theme),
                _chip('risco: ${riskLabel(req.risk)}', theme, color: rc),
              ]),
              const SizedBox(height: 12),
              Text('O que será executado:',
                  style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: VtTheme.of(context).codeBackground,
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  preview.length > 4000
                      ? '${preview.substring(0, 4000)}\n… (truncado)'
                      : preview,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12),
                  maxLines: 24,
                ),
              ),
              if (_needsTypedConfirm) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: _confirmDestructive,
                  onChanged: (v) =>
                      setState(() => _confirmDestructive = v ?? false),
                  title: Text(
                    'Esta operação é ${riskLabel(req.risk)} e pode não ter '
                    'reversão. Confirmo que entendo.',
                    style: theme.textTheme.bodySmall,
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: _reason,
                decoration: const InputDecoration(
                  labelText: 'Motivo (opcional, vai para o audit log)',
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _decide(ApprovalOutcome.rejected),
          child: const Text('Rejeitar'),
        ),
        FilledButton.icon(
          onPressed: _needsTypedConfirm && !_confirmDestructive
              ? null
              : () => _decide(ApprovalOutcome.approved),
          icon: const Icon(Icons.check),
          label: const Text('Aprovar e executar'),
        ),
      ],
    );
  }

  Widget _chip(String label, ThemeData theme, {Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: (color ?? theme.colorScheme.surfaceContainerHighest)
              .withValues(alpha: 0.25),
          border: Border.all(color: color ?? theme.dividerColor),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: theme.textTheme.labelSmall?.copyWith(color: color)),
      );
}
