/// Executor de tool calls vindos do streaming do modelo (spec §AGENTE:
/// executing_tool → observing_result com aprovação, sandbox, timeout e retry).
///
/// - parseInput/execute delegam à implementação REAL da tool (dart:io/git).
/// - Timeout usa `tool.timeout` real; retry respeita `RetryPolicy` apenas para
///   falhas `retryable` e tools idempotentes.
/// - Toda execução é auditada em SQLite (tool_audit) — nada de log "de mentira".
library;

import 'dart:async';
import 'dart:convert';

import '../domain/errors/vt_failure.dart';
import '../domain/tools/tool_contract.dart';
import '../infrastructure/native/sqlite_native.dart';
import 'approval.dart';
import 'tool_registry.dart';

const kToolAuditSchema = '''
CREATE TABLE IF NOT EXISTS tool_audit (
  id TEXT PRIMARY KEY,
  ts TEXT NOT NULL,
  conversation_id TEXT,
  call_id TEXT,
  tool_id TEXT NOT NULL,
  input_json TEXT NOT NULL,
  outcome TEXT NOT NULL,
  error_code TEXT,
  duration_ms INTEGER NOT NULL,
  attempts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tool_audit_conv ON tool_audit(conversation_id, ts);
''';

/// Migração aditiva real: coluna de custo USD estimado por execução de tool.
/// Tabelas antigas ganham a coluna; nada é destruído.
const kToolAuditCostMigration =
    'ALTER TABLE tool_audit ADD COLUMN cost_usd REAL';

/// Timeout global default por passo quando `stepTimeoutSeconds` não está
/// configurado — igual ao contrato histórico do executor (nenhum limite).
const kDefaultStepTimeout = Duration(minutes: 5);

enum ToolCallOutcomeKind { succeeded, failed, blocked }

class ToolCallOutcome {
  const ToolCallOutcome({
    required this.callId,
    required this.toolId,
    required this.kind,
    required this.resultText,
    required this.durationMs,
    required this.attempts,
    this.auditId,
    this.failure,
    this.costUsd,
  });
  final String callId;
  final String toolId;
  final ToolCallOutcomeKind kind;

  /// Conteúdo devolvido ao modelo no próximo turno (role: tool).
  final String resultText;
  final int durationMs;
  final int attempts;
  final String? auditId;
  final VtFailure? failure;

  /// Custo USD estimado desta execução de tool (rate table da provider se
  /// houver; null quando a tool não reporta custo real).
  final double? costUsd;

  bool get ok => kind == ToolCallOutcomeKind.succeeded;
}

class ToolExecutor {
  ToolExecutor({
    required this.registry,
    required this.context,
    required this.db,
    this.approvalGateway,
    this.settings,
    this.postureResolver,
    this.stepTimeout = kDefaultStepTimeout,
    this.costEstimator,
  }) {
    db.execute(kToolAuditSchema);
    // Migração aditiva idempotente: bancos antigos ganham cost_usd; em
    // bancos novos o ALTER falha ("duplicate column") e é ignorado de
    // propósito — nunca dropamos nada.
    try {
      db.execute(kToolAuditCostMigration);
    } catch (_) {/* coluna já existe */}
  }

  final ToolRegistry registry;
  final ToolContext context;
  final SqliteDb db;
  final ApprovalGateway? approvalGateway;

  /// Settings reais (limites por passo / timeout global via settings.json).
  final SettingsGateway? settings;

  /// Postura de aprovação do composer resolvida POR EXECUÇÃO (não congelada
  /// no boot): manual | autoSafe | autoAll | null = política do contrato.
  final ComposerApprovalChoice? Function()? postureResolver;

  /// Timeout default por passo; `stepTimeoutSeconds` em settings.json tem
  /// precedência sobre este valor quando configurado.
  Duration stepTimeout;

  /// Estimativa de custo USD por execução de tool (preço real quando a
  /// provider conhece o modelo; null = sem custo conhecido, nunca chutado).
  final double? Function(VtTool<ToolInput, ToolOutput> tool,
      ToolCallOutcomeKind kind, int durationMs)? costEstimator;

  /// Timeout efetivo de um passo: settings `stepTimeoutSeconds` > campo.
  Duration effectiveStepTimeout() {
    final s = settings?.get('stepTimeoutSeconds');
    final secs = s is num
        ? s.toInt()
        : (s is String ? int.tryParse(s.trim()) : null);
    if (secs != null && secs >= 1) return Duration(seconds: secs);
    return stepTimeout;
  }

  /// Executa um tool call acumulado do stream. Nunca lança para erro de
  /// domínio: tudo vira [ToolCallOutcome] tipado + registro de auditoria.
  Future<ToolCallOutcome> run({
    required String callId,
    required String toolId,
    required String argsJson,
    String? conversationId,
  }) async {
    final started = DateTime.now();
    final sw = Stopwatch()..start();

    Map<String, Object?> input;
    try {
      input =
          (jsonDecode(argsJson.isEmpty ? '{}' : argsJson) as Map).cast<String, Object?>();
    } on FormatException catch (e) {
      return _audit(
        callId: callId,
        toolId: toolId,
        inputJson: argsJson,
        conversationId: conversationId,
        outcome: 'blocked',
        errorCode: VtErrorCode.validationFailed.wire,
        resultText: 'Input inválido (JSON malformado): ${e.message}',
        failure: VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Args de "$toolId" não são JSON válido.'),
        sw: sw,
        started: started,
        attempts: 0,
      );
    }

    final tool = registry.byId(toolId);
    if (tool == null) {
      final f = VtFailure(
        code: VtErrorCode.notImplemented,
        message: 'Tool "$toolId" não está registrada neste build.',
        recoveryActions: const [
          RecoveryAction(kind: 'list_tools', label: 'Ver catálogo de tools'),
        ],
      );
      return _audit(
        callId: callId,
        toolId: toolId,
        inputJson: jsonEncode(input),
        conversationId: conversationId,
        outcome: 'blocked',
        errorCode: f.code.wire,
        resultText: f.message,
        failure: f,
        sw: sw,
        started: started,
        attempts: 0,
      );
    }

    // Health check REAL antes de executar (binário/sidecar/key presentes?).
    final health = await tool.health(context);
    if (health is! HealthOk) {
      final (code, msg) = switch (health) {
        HealthMissingBinary(:final binary) => (
            VtErrorCode.binaryMissing,
            'Binário "$binary" ausente — instale ou configure o caminho.'
          ),
        HealthMissingSidecar(:final sidecar) => (
            VtErrorCode.sidecarNotRunning,
            'Sidecar "$sidecar" não está rodando.'
          ),
        HealthUnconfigured(:final what) => (
            VtErrorCode.providerNotConfigured,
            'Tool não configurada: $what'
          ),
        HealthDegraded(:final reason) => (
            VtErrorCode.internalError,
            'Tool degradada: $reason'
          ),
        _ => (VtErrorCode.internalError, 'Health check falhou.'),
      };
      final f = VtFailure(code: code, message: msg);
      return _audit(
        callId: callId,
        toolId: toolId,
        inputJson: jsonEncode(input),
        conversationId: conversationId,
        outcome: 'blocked',
        errorCode: f.code.wire,
        resultText: f.message,
        failure: f,
        sw: sw,
        started: started,
        attempts: 0,
      );
    }

    // Aprovação conforme política default da tool + postura global do
    // composer (resolvida AGORA, por execução — mudar em Ajustes/composer
    // vale para o próximo tool call sem reiniciar nada).
    final blocked = await evaluateApproval(
      tool: tool,
      input: input,
      gateway: approvalGateway,
      conversationId: conversationId,
      posture: postureResolver?.call(),
    );
    if (blocked != null) {
      return _audit(
        callId: callId,
        toolId: toolId,
        inputJson: jsonEncode(input),
        conversationId: conversationId,
        outcome: 'blocked',
        errorCode: blocked.code.wire,
        resultText: blocked.message,
        failure: blocked,
        sw: sw,
        started: started,
        attempts: 0,
      );
    }

    // parseInput fora do retry loop: erro de schema não se resolve sozinho.
    final ToolInput parsed;
    try {
      parsed = await tool.parseInput(input);
    } on VtFailure catch (f) {
      return _audit(
        callId: callId,
        toolId: toolId,
        inputJson: jsonEncode(input),
        conversationId: conversationId,
        outcome: 'failed',
        errorCode: f.code.wire,
        resultText: f.message,
        failure: f,
        sw: sw,
        started: started,
        attempts: 1,
      );
    }

    final maxAttempts = tool.retryPolicy.maxAttempts < 1
        ? 1
        : (tool.isIdempotent ? tool.retryPolicy.maxAttempts : 1);
    // Timeout efetivo do passo: o menor entre o timeout declarado pela tool
    // e o limite global `stepTimeoutSeconds` de settings.json — assim o
    // limite configurado em Ajustes é aplicado DE VERDADE, sem quebrar
    // tools que já pedem timeout menor.
    final stepTo = effectiveStepTimeout();
    final attemptTimeout =
        tool.timeout < stepTo ? tool.timeout : stepTo;
    VtFailure? lastFailure;
    String? lastText;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      var failed = false;
      try {
        final res = await tool.execute(context, parsed).timeout(attemptTimeout);
        switch (res) {
          case ToolSuccess(:final data):
            return _audit(
              callId: callId,
              toolId: toolId,
              inputJson: jsonEncode(input),
              conversationId: conversationId,
              outcome: 'succeeded',
              errorCode: null,
              resultText: _renderResult(data),
              failure: null,
              sw: sw,
              started: started,
              attempts: attempt,
            );
          case ToolFailureResult(:final failure):
            lastFailure = failure;
            lastText = failure.message;
            failed = !failure.retryable || !tool.isIdempotent;
        }
      } on TimeoutException {
        lastFailure = VtFailure.timeout(tool.timeout);
        lastText = lastFailure.message;
      } on VtFailure catch (f) {
        lastFailure = f;
        lastText = f.message;
        failed = !f.retryable || !tool.isIdempotent;
      }
      if (failed) break;
      if (attempt < maxAttempts) {
        await Future<void>.delayed(tool.retryPolicy.backoff * attempt);
      }
    }

    return _audit(
      callId: callId,
      toolId: toolId,
      inputJson: jsonEncode(input),
      conversationId: conversationId,
      outcome: 'failed',
      errorCode: (lastFailure ??
              VtFailure(code: VtErrorCode.internalError, message: 'Falha sem tipo.'))
          .code
          .wire,
      resultText: lastText ?? 'Tool falhou sem mensagem.',
      failure: lastFailure,
      sw: sw,
      started: started,
      attempts: maxAttempts,
    );
  }

  static String _renderResult(ToolOutput data) {
    if (data is TextOutput) {
      final meta = data.metadata;
      if (meta.isEmpty) return data.text;
      return '${data.text}\n[metadata] ${jsonEncode(meta)}';
    }
    return jsonEncode(data.toJson());
  }

  ToolCallOutcome _audit({
    required String callId,
    required String toolId,
    required String inputJson,
    required String? conversationId,
    required String outcome,
    required String? errorCode,
    required String resultText,
    required VtFailure? failure,
    required Stopwatch sw,
    required DateTime started,
    required int attempts,
  }) {
    final auditId = 'audit_${started.microsecondsSinceEpoch}_$callId';
    // Parametrizado de verdade: nada de interpolar JSON/texto na SQL.
    db.execute(
      'INSERT INTO tool_audit (id, ts, conversation_id, call_id, tool_id,'
      ' input_json, outcome, error_code, duration_ms, attempts)'
      " VALUES (?,?,?,?,?,?,?,COALESCE(?,''),?,?)",
      [
        auditId,
        started.toUtc().toIso8601String(),
        conversationId ?? '',
        callId,
        toolId,
        inputJson,
        outcome,
        errorCode ?? '',
        '${sw.elapsedMilliseconds}',
        '$attempts',
      ],
    );
    return ToolCallOutcome(
      callId: callId,
      toolId: toolId,
      kind: switch (outcome) {
        'succeeded' => ToolCallOutcomeKind.succeeded,
        'blocked' => ToolCallOutcomeKind.blocked,
        _ => ToolCallOutcomeKind.failed,
      },
      resultText: resultText,
      durationMs: sw.elapsedMilliseconds,
      attempts: attempts,
      auditId: auditId,
      failure: failure,
    );
  }

  /// Auditoria persistida por conversa (UI "o que o agente fez").
  List<Map<String, Object?>> auditForConversation(String conversationId,
          {int limit = 100}) =>
      db.query(
          'SELECT id, ts, call_id, tool_id, input_json, outcome, error_code,'
          ' duration_ms, attempts FROM tool_audit'
          ' WHERE conversation_id=? ORDER BY ts DESC LIMIT $limit',
          [conversationId]);
}
