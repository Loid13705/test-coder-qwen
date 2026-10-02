/// Política de aprovação de tools (spec §APROVAÇÃO).
///
/// A decisão é REAL: sem gateway configurado, toda tool não-auto falha com
/// `approval_required` tipado — nunca "aprova por padrão" silenciosamente.
library;

import '../domain/errors/vt_failure.dart';
import '../domain/tools/tool_contract.dart';

enum ApprovalOutcome { approved, rejected }

class ApprovalRequest {
  const ApprovalRequest({
    required this.requestId,
    required this.toolId,
    required this.title,
    required this.risk,
    required this.preview,
    this.conversationId,
  });
  final String requestId;
  final String toolId;
  final String title;
  final RiskLevel risk;

  /// Resumo do que será feito (input da tool serializado) para a UI de review.
  final Map<String, Object?> preview;
  final String? conversationId;
}

class ApprovalDecision {
  const ApprovalDecision(this.outcome, {this.reason});
  final ApprovalOutcome outcome;
  final String? reason;

  bool get isApproved => outcome == ApprovalOutcome.approved;
}

/// Gateway de aprovação implementado pela camada de UI (dialog de review).
abstract class ApprovalGateway {
  Future<ApprovalDecision> request(ApprovalRequest req);
}

/// Posturas de aprovação selecionáveis no composer (camada UI → executor).
/// Diferente de [ApprovalPolicyMode] (política default POR TOOL, do contrato):
/// aqui é a intenção global do usuário sobre QUEM decide aprovar.
enum ComposerApprovalChoice {
  manual('Manual', 'Toda tool não-auto abre diálogo de aprovação para você.'),
  autoSafe(
      'Auto safe',
      'Read-only executa direto; escrita/execução/destrutivas pedem '
          'aprovação.'),
  autoAll('Auto all',
      'Executa sem perguntar — exceto explícita/tipada (push, delete '
          'permanente, secrets), que o contrato sempre preserva.');

  const ComposerApprovalChoice(this.label, this.description);
  final String label;
  final String description;
}

/// Decide se [tool] precisa de aprovação e, precisando, consulta o gateway.
/// Retorna null quando pode executar; retorna VtFailure quando bloqueada.
///
/// [posture] vem do seletor de aprovação do composer (null = política pura do
/// contrato):
/// - manual: qualquer tool não-auto pede aprovação (comportamento default);
/// - autoSafe: tools read-only/auto executam direto; o resto pede aprovação;
/// - autoAll: pula o diálogo apenas para políticas revisáveis (reviewEach /
///   auto); `explicitApproval` e `typedConfirmation` NUNCA são ignorados.
Future<VtFailure?> evaluateApproval({
  required VtTool<ToolInput, ToolOutput> tool,
  required Map<String, Object?> input,
  required ApprovalGateway? gateway,
  String? conversationId,
  ComposerApprovalChoice? posture,
}) async {
  final isReadOnly = tool.risk == RiskLevel.readOnly;
  switch (posture) {
    case ComposerApprovalChoice.autoSafe:
      if (isReadOnly ||
          tool.defaultApproval == ApprovalPolicyMode.auto) {
        return null;
      }
    case ComposerApprovalChoice.autoAll:
      // Limite inegociável: aprovação explícita/tipada do contrato permanece.
      if (tool.defaultApproval == ApprovalPolicyMode.auto ||
          tool.defaultApproval == ApprovalPolicyMode.reviewEach) {
        return null;
      }
    case ComposerApprovalChoice.manual:
    case null:
      break; // segue a política default da tool.
  }
  if (tool.defaultApproval == ApprovalPolicyMode.auto) return null;

  // Sem gateway real NÃO há como aprovar: falha tipada com ação de recovery,
  // em vez de executar escondido ou fingir consentimento.
  if (gateway == null) {
    return VtFailure(
      code: VtErrorCode.approvalRequired,
      message:
          'Tool "${tool.id}" exige aprovação (${tool.defaultApproval.name}, '
          'risco ${tool.risk.wire}) mas não há UI de aprovação conectada.',
      recoveryActions: const [
        RecoveryAction(
            kind: 'enable_approval_ui',
            label: 'Abrir o painel de aprovação e reenviar'),
      ],
    );
  }

  final req = ApprovalRequest(
    requestId: 'appr_${DateTime.now().microsecondsSinceEpoch}',
    toolId: tool.id,
    title: tool.title,
    risk: tool.risk,
    preview: input,
    conversationId: conversationId,
  );
  final decision = await gateway.request(req);
  if (decision.isApproved) return null;
  return VtFailure(
    code: VtErrorCode.userRejected,
    message: 'Aprovação negada para "${tool.id}".'
        '${decision.reason != null ? ' Motivo: ${decision.reason}' : ''}',
  );
}
