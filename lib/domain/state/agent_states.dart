/// Máquina de estados do agent run e estados de UI obrigatórios (spec).
library;

/// Estados da máquina do agent run (spec §AGENTE).
enum AgentRunState {
  idle('idle'),
  receivingInput('receiving_input'),
  assemblingContext('assembling_context'),
  planning('planning'),
  awaitingApproval('awaiting_approval'),
  executingTool('executing_tool'),
  observingResult('observing_result'),
  verifying('verifying'),
  replanning('replanning'),
  completed('completed'),
  failed('failed'),
  cancelled('cancelled'),
  rolledBack('rolled_back');

  const AgentRunState(this.wire);
  final String wire;

  /// Transições válidas — o runtime rejeita transições inválidas com erro real.
  bool canTransitionTo(AgentRunState next) {
    switch (this) {
      case AgentRunState.idle:
        return next == AgentRunState.receivingInput;
      case AgentRunState.receivingInput:
        return next == AgentRunState.assemblingContext ||
            next == AgentRunState.cancelled ||
            next == AgentRunState.failed;
      case AgentRunState.assemblingContext:
        return next == AgentRunState.planning ||
            next == AgentRunState.cancelled ||
            next == AgentRunState.failed;
      case AgentRunState.planning:
        return next == AgentRunState.awaitingApproval ||
            next == AgentRunState.executingTool || // Propose Only / Safe Auto
            next == AgentRunState.cancelled ||
            next == AgentRunState.failed;
      case AgentRunState.awaitingApproval:
        return next == AgentRunState.executingTool ||
            next == AgentRunState.replanning ||
            next == AgentRunState.cancelled ||
            next == AgentRunState.failed ||
            next == AgentRunState.rolledBack;
      case AgentRunState.executingTool:
        return next == AgentRunState.observingResult ||
            next == AgentRunState.awaitingApproval ||
            next == AgentRunState.cancelled ||
            next == AgentRunState.failed;
      case AgentRunState.observingResult:
        return next == AgentRunState.verifying ||
            next == AgentRunState.executingTool ||
            next == AgentRunState.replanning ||
            next == AgentRunState.completed ||
            next == AgentRunState.failed ||
            next == AgentRunState.cancelled;
      case AgentRunState.verifying:
        return next == AgentRunState.executingTool ||
            next == AgentRunState.replanning ||
            next == AgentRunState.completed ||
            next == AgentRunState.failed ||
            next == AgentRunState.rolledBack;
      case AgentRunState.replanning:
        return next == AgentRunState.planning ||
            next == AgentRunState.awaitingApproval ||
            next == AgentRunState.executingTool ||
            next == AgentRunState.cancelled ||
            next == AgentRunState.failed;
      case AgentRunState.completed:
        return next == AgentRunState.rolledBack || next == AgentRunState.idle;
      case AgentRunState.failed:
        return next == AgentRunState.rolledBack ||
            next == AgentRunState.replanning ||
            next == AgentRunState.idle;
      case AgentRunState.cancelled:
        return next == AgentRunState.rolledBack || next == AgentRunState.idle;
      case AgentRunState.rolledBack:
        return next == AgentRunState.idle;
    }
  }

  bool get isTerminal =>
      this == AgentRunState.completed ||
      this == AgentRunState.failed ||
      this == AgentRunState.cancelled ||
      this == AgentRunState.rolledBack;
}

/// Status real por passo do plano (spec §Plano estruturado).
enum PlanStepStatus {
  pending('pending'),
  approved('approved'),
  running('running'),
  succeeded('succeeded'),
  failed('failed'),
  skipped('skipped'),
  rolledBack('rolled_back');

  const PlanStepStatus(this.wire);
  final String wire;
}
