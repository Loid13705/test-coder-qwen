/// Persistência real do estado operacional do agente (spec §Plano estruturado,
/// §Tarefas, §Reflexão, §Esclarecimento, §Contexto, §Histórico, §Aprovação).
///
/// Todas as tools `agent.*` e `todo.list` operam SOBRE ESTE ARMAZENAMENTO —
/// SQLite local via FFI, sem caches em memória fingindo ser fonte de verdade:
/// - `agent_plans`     — plano atual REAL por run (JSON do modelo [AgentPlan]);
/// - `agent_plan_rev`  — cada update grava uma REVISÃO imutável (histórico
///                        completo: nada é sobrescrito, só adicionado);
/// - `agent_tasks`     — tarefas com audit trail (start/complete/fail, notas,
///                        evidências, timestamps reais);
/// - `agent_reflections` — avaliações de resultado contra critérios;
/// - `agent_clarifies`   — perguntas de esclarecimento + respostas;
/// - `agent_summaries`   — resumos de contexto COM citações (fonte obrigatória);
/// - `agent_compactions` — compactações que REFEREM os itens originais
///                        (originais permanecem intactos em `messages`);
/// - `agent_approvals`   — pedidos de aprovação com decisão registrada.
///
/// Escopo: `conversation_id` quando houver conversa ativa; caso contrário a
/// primeira raiz do workspace — o mesmo padrão das tools de memória/checkpoint.
library;

import 'dart:convert';

import '../../domain/errors/vt_failure.dart';
import '../../domain/models/core_models.dart';
import '../native/sqlite_native.dart';

const kAgentStateSchema = '''
CREATE TABLE IF NOT EXISTS agent_plans (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  objective TEXT NOT NULL,
  plan_json TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_plans_conv ON agent_plans(conversation_id, updated_at);

CREATE TABLE IF NOT EXISTS agent_plan_rev (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  plan_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  change_note TEXT NOT NULL DEFAULT '',
  plan_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_plan_rev_plan ON agent_plan_rev(plan_id, revision);

CREATE TABLE IF NOT EXISTS agent_tasks (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  plan_id TEXT,
  step_index INTEGER,
  title TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','running','done','failed')),
  started_at TEXT,
  ended_at TEXT,
  notes TEXT NOT NULL DEFAULT '[]',
  evidence TEXT NOT NULL DEFAULT '[]',
  verify_result TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_tasks_conv ON agent_tasks(conversation_id, status);

CREATE TABLE IF NOT EXISTS agent_reflections (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL,
  verdict TEXT NOT NULL CHECK (verdict IN ('met','partial','unmet')),
  report_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_refl_task ON agent_reflections(task_id);

CREATE TABLE IF NOT EXISTS agent_clarifies (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  question TEXT NOT NULL,
  ambiguities TEXT NOT NULL DEFAULT '[]',
  options TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'awaiting'
    CHECK (status IN ('awaiting','answered')),
  answer TEXT,
  answered_at TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_clarify_conv ON agent_clarifies(conversation_id, created_at);

CREATE TABLE IF NOT EXISTS agent_summaries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id TEXT NOT NULL,
  text TEXT NOT NULL,
  citations TEXT NOT NULL,
  source_count INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_summary_conv ON agent_summaries(conversation_id, created_at);

CREATE TABLE IF NOT EXISTS agent_compactions (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  strategy TEXT NOT NULL,
  summary TEXT NOT NULL,
  original_ids TEXT NOT NULL,
  originals_digest TEXT NOT NULL,
  original_count INTEGER NOT NULL,
  kept_count INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_compact_conv ON agent_compactions(conversation_id, created_at);

CREATE TABLE IF NOT EXISTS agent_approvals (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  tool_id TEXT NOT NULL,
  action TEXT NOT NULL DEFAULT '',
  risk TEXT NOT NULL,
  reason TEXT NOT NULL DEFAULT '',
  preview_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected')),
  decided_by TEXT,
  decided_at TEXT,
  note TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_approval_conv ON agent_approvals(conversation_id, created_at);
''';

VtFailure _notFound(String what) => VtFailure(
      code: VtErrorCode.validationFailed,
      message: '$what não encontrado.',
      recoveryActions: const [
        RecoveryAction(kind: 'list_records', label: 'Listar registros atuais'),
      ],
    );

String? _nullIfEmpty(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

List<Object?> _decodeList(Object? raw) {
  final s = raw as String?;
  if (s == null || s.isEmpty) return const [];
  try {
    final d = jsonDecode(s);
    return d is List ? d : const [];
  } on FormatException {
    return const [];
  }
}

Map<String, Object?> _decodeMap(Object? raw) {
  final s = raw as String?;
  if (s == null || s.isEmpty) return const {};
  try {
    final d = jsonDecode(s);
    return d is Map ? d.cast<String, Object?>() : const {};
  } on FormatException {
    return const {};
  }
}

class AgentTaskRow {
  const AgentTaskRow({
    required this.id,
    required this.conversationId,
    required this.title,
    required this.status,
    required this.notes,
    required this.evidence,
    required this.createdAt,
    required this.updatedAt,
    this.planId,
    this.stepIndex,
    this.startedAt,
    this.endedAt,
    this.verifyResult,
  });

  final String id;
  final String conversationId;
  final String? planId;
  final int? stepIndex;
  final String title;
  final String status; // pending|running|done|failed
  final List<Object?> notes;
  final List<Object?> evidence;
  final String? startedAt;
  final String? endedAt;
  final String? verifyResult;
  final String createdAt;
  final String updatedAt;

  static AgentTaskRow fromRow(Map<String, Object?> r) => AgentTaskRow(
        id: r['id'] as String,
        conversationId: r['conversation_id'] as String,
        planId: _nullIfEmpty(r['plan_id']),
        stepIndex: (r['step_index'] as String?) == null
            ? null
            : int.tryParse(r['step_index'] as String),
        title: r['title'] as String,
        status: r['status'] as String,
        notes: _decodeList(r['notes']),
        evidence: _decodeList(r['evidence']),
        startedAt: _nullIfEmpty(r['started_at']),
        endedAt: _nullIfEmpty(r['ended_at']),
        verifyResult: _nullIfEmpty(r['verify_result']),
        createdAt: r['created_at'] as String,
        updatedAt: r['updated_at'] as String,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'conversationId': conversationId,
        'planId': planId,
        'stepIndex': stepIndex,
        'title': title,
        'status': status,
        'startedAt': startedAt,
        'endedAt': endedAt,
        'notes': notes,
        'evidence': evidence,
        'verifyResult': verifyResult,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

class AgentStateStore {
  AgentStateStore(this.db) {
    db.execute(kAgentStateSchema);
  }

  final SqliteDb db;

  static String _isoNow() => DateTime.now().toUtc().toIso8601String();

  static String newId(String prefix) {
    final now = DateTime.now().toUtc();
    final ts = now.toIso8601String().replaceAll(RegExp(r'[-:.TZ]'), '');
    final rnd = (now.microsecondsSinceEpoch % 0xFFFFFF).toRadixString(16);
    return '$prefix-$ts-$rnd';
  }

  // ------------------------------------------------------------- plans ----

  /// Cria um plano estruturado novo (revision 1) + revisão imutável inicial.
  AgentPlan createPlan({
    required String conversationId,
    required AgentPlan plan,
  }) {
    final now = _isoNow();
    db.execute(
      'INSERT INTO agent_plans (id, conversation_id, objective, plan_json, '
      'revision, created_at, updated_at) VALUES (?,?,?,?,?,?,?)',
      [
        plan.id,
        conversationId,
        plan.objective,
        jsonEncode(plan.toJson()),
        '1',
        now,
        now,
      ],
    );
    _appendPlanRevision(plan, 1, 'plano criado');
    return plan;
  }

  void _appendPlanRevision(AgentPlan plan, int revision, String note) {
    db.execute(
      'INSERT INTO agent_plan_rev (plan_id, revision, change_note, '
      'plan_json, created_at) VALUES (?,?,?,?,?)',
      [plan.id, '$revision', note, jsonEncode(plan.toJson()), _isoNow()],
    );
  }

  AgentPlan? planById(String id) {
    final rows = db.query('SELECT plan_json FROM agent_plans WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    return AgentPlan.fromJson(
        (jsonDecode(rows.first['plan_json'] as String) as Map)
            .cast<String, Object?>());
  }

  /// Plano REAL mais recente da conversa (null se nunca foi criado).
  AgentPlan? latestPlan(String conversationId) {
    final rows = db.query(
      'SELECT plan_json FROM agent_plans WHERE conversation_id=? '
      'ORDER BY updated_at DESC LIMIT 1',
      [conversationId],
    );
    if (rows.isEmpty) return null;
    return AgentPlan.fromJson(
        (jsonDecode(rows.first['plan_json'] as String) as Map)
            .cast<String, Object?>());
  }

  /// Aplica mudanças ao plano persistido e grava a nova REVISÃO imutável.
  /// Retorna o plano resultante (fonte: estado real anterior + delta).
  AgentPlan updatePlan({
    required String planId,
    String? objective,
    List<String>? acceptanceCriteria,
    String? verification,
    String? rollbackPlan,
    Map<int, PlanStepStatus>? stepStatuses,
    Map<int, String>? stepTitles,
    String changeNote = '',
  }) {
    final current = planById(planId);
    if (current == null) throw _notFound('Plano "$planId"');
    final steps = <AgentPlanStep>[
      for (final s in current.steps)
        s.copyWith(
          title: stepTitles?[s.index] ?? s.title,
          status: stepStatuses?[s.index] ?? s.status,
        ),
    ];
    final updated = AgentPlan(
      id: current.id,
      agentRunId: current.agentRunId,
      objective: objective ?? current.objective,
      hypotheses: current.hypotheses,
      affectedFiles: current.affectedFiles,
      requiredTools: current.requiredTools,
      risks: current.risks,
      acceptanceCriteria: acceptanceCriteria ?? current.acceptanceCriteria,
      steps: steps,
      verification: verification ?? current.verification,
      rollbackPlan: rollbackPlan ?? current.rollbackPlan,
      createdAt: current.createdAt,
    );
    final rows = db.query('SELECT revision FROM agent_plans WHERE id=?', [planId]);
    final rev = int.parse(rows.first['revision'] as String) + 1;
    db.execute(
      'UPDATE agent_plans SET objective=?, plan_json=?, revision=?, '
      'updated_at=? WHERE id=?',
      [
        updated.objective,
        jsonEncode(updated.toJson()),
        '$rev',
        _isoNow(),
        planId,
      ],
    );
    _appendPlanRevision(
        updated, rev, changeNote.isEmpty ? 'plano atualizado' : changeNote);
    return updated;
  }

  List<Map<String, Object?>> planRevisions(String planId) => [
        for (final r in db.query(
            'SELECT revision, change_note, created_at, plan_json '
            'FROM agent_plan_rev WHERE plan_id=? ORDER BY revision ASC',
            [planId]))
          {
            'revision': int.tryParse(r['revision'] as String? ?? ''),
            'changeNote': r['change_note'],
            'createdAt': r['created_at'],
            'steps': [
              for (final s
                  in (_decodeMap(r['plan_json'])['steps'] as List? ??
                      const []))
                {
                  'index': (s as Map)['index'],
                  'title': s['title'],
                  'status': s['status'],
                },
            ],
          },
      ];

  // ------------------------------------------------------------- tasks ----

  AgentTaskRow createTask({
    required String conversationId,
    required String title,
    String? planId,
    int? stepIndex,
  }) {
    final id = newId('task');
    final now = _isoNow();
    db.execute(
      'INSERT INTO agent_tasks (id, conversation_id, plan_id, step_index, '
      'title, status, notes, evidence, created_at, updated_at) '
      'VALUES (?,?,?,?,?,?,?,?,?,?)',
      [
        id,
        conversationId,
        planId ?? '',
        stepIndex == null ? '' : '$stepIndex',
        title,
        'pending',
        '[]',
        '[]',
        now,
        now,
      ],
    );
    return taskById(id)!;
  }

  AgentTaskRow? taskById(String id) {
    final rows = db.query('SELECT * FROM agent_tasks WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    return AgentTaskRow.fromRow(rows.first);
  }

  AgentTaskRow requireTask(String id) =>
      taskById(id) ?? (throw _notFound('Tarefa "$id"'));

  List<AgentTaskRow> tasks({String? conversationId, String? status}) {
    final where = <String>[];
    final params = <String>[];
    if (conversationId != null) {
      where.add('conversation_id=?');
      params.add(conversationId);
    }
    if (status != null) {
      where.add('status=?');
      params.add(status);
    }
    final sql = 'SELECT * FROM agent_tasks'
        '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}'
        ' ORDER BY created_at ASC';
    return [for (final r in db.query(sql, params)) AgentTaskRow.fromRow(r)];
  }

  /// Marca a tarefa como rodando: registra timestamp real + nota no trail.
  AgentTaskRow startTask({required String taskId, required String note}) {
    final t = requireTask(taskId);
    if (t.status == 'running') {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Tarefa "$taskId" já está em execução '
            '(started_at=${t.startedAt}). Conclua ou falhe antes de reiniciar.',
      );
    }
    if (t.status == 'done') {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Tarefa "$taskId" já foi concluída; recrie-a para repetir.',
      );
    }
    final now = _isoNow();
    _appendTrail(t, 'start', note);
    db.execute(
      'UPDATE agent_tasks SET status=?, started_at=?, ended_at=NULL, '
      'verify_result=NULL, updated_at=? WHERE id=?',
      ['running', now, now, taskId],
    );
    return taskById(taskId)!;
  }

  /// Conclui a tarefa SOMENTE após verificação: exige resultado da checagem
  /// real e evidencia o encerramento no trail.
  AgentTaskRow completeTask({
    required String taskId,
    required String verifyResult,
    required List<String> evidence,
    required String note,
  }) {
    final t = requireTask(taskId);
    if (t.status != 'running') {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Tarefa "$taskId" não está em execução (status=${t.status}); '
            'agent.task.start deve preceder agent.task.complete.',
      );
    }
    final now = _isoNow();
    _appendTrail(t, 'complete', note, extraEvidence: evidence);
    db.execute(
      'UPDATE agent_tasks SET status=?, ended_at=?, verify_result=?, '
      'updated_at=? WHERE id=?',
      ['done', now, verifyResult, now, taskId],
    );
    return taskById(taskId)!;
  }

  /// Registra falha da tarefa (permite retry honesto via novo start).
  AgentTaskRow failTask({required String taskId, required String note}) {
    final t = requireTask(taskId);
    final now = _isoNow();
    _appendTrail(t, 'fail', note);
    db.execute(
      'UPDATE agent_tasks SET status=?, ended_at=?, updated_at=? WHERE id=?',
      ['failed', now, now, taskId],
    );
    return taskById(taskId)!;
  }

  void _appendTrail(AgentTaskRow t, String event, String note,
      {List<String> extraEvidence = const []}) {
    final entries = [
      ...t.notes,
      {'event': event, 'at': _isoNow(), 'note': note},
    ];
    final ev = [...t.evidence, ...extraEvidence];
    db.execute(
      'UPDATE agent_tasks SET notes=?, evidence=?, updated_at=? WHERE id=?',
      [jsonEncode(entries), jsonEncode(ev), _isoNow(), t.id],
    );
  }

  // ------------------------------------------------------ reflections ----

  void addReflection({
    required String taskId,
    required Map<String, Object?> report,
  }) {
    requireTask(taskId);
    final verdict = report['verdict'] as String? ?? '';
    if (!const ['met', 'partial', 'unmet'].contains(verdict)) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'verdict deve ser met|partial|unmet, recebeu "$verdict".',
      );
    }
    db.execute(
      'INSERT INTO agent_reflections (task_id, verdict, report_json, '
      'created_at) VALUES (?,?,?,?)',
      [taskId, verdict, jsonEncode(report), _isoNow()],
    );
  }

  List<Map<String, Object?>> reflectionsFor(String taskId) => [
        for (final r in db.query(
            'SELECT id, verdict, report_json, created_at FROM agent_reflections '
            'WHERE task_id=? ORDER BY id ASC',
            [taskId]))
          {
            'id': r['id'],
            'verdict': r['verdict'],
            'createdAt': r['created_at'],
            'report': _decodeMap(r['report_json']),
          },
      ];

  // -------------------------------------------------------- clarifies ----

  Map<String, Object?> createClarification({
    required String conversationId,
    required String id,
    required String question,
    required List<String> ambiguities,
    required List<String> options,
  }) {
    db.execute(
      'INSERT INTO agent_clarifies (id, conversation_id, question, '
      'ambiguities, options, status, created_at) VALUES (?,?,?,?,?,?,?)',
      [
        id,
        conversationId,
        question,
        jsonEncode(ambiguities),
        jsonEncode(options),
        'awaiting',
        _isoNow(),
      ],
    );
    return {
      'id': id,
      'question': question,
      'ambiguities': ambiguities,
      'options': options,
      'status': 'awaiting',
    };
  }

  Map<String, Object?>? clarification(String id) {
    final rows = db.query('SELECT * FROM agent_clarifies WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'id': r['id'],
      'question': r['question'],
      'ambiguities': _decodeList(r['ambiguities']),
      'options': _decodeList(r['options']),
      'status': r['status'],
      'answer': _nullIfEmpty(r['answer']),
      'answeredAt': _nullIfEmpty(r['answered_at']),
      'createdAt': r['created_at'],
    };
  }

  Map<String, Object?> answerClarification(String id, String answer) {
    if (clarification(id) == null) {
      throw _notFound('Pedido de esclarecimento "$id"');
    }
    db.execute(
      'UPDATE agent_clarifies SET status=?, answer=?, answered_at=? WHERE id=?',
      ['answered', answer, _isoNow(), id],
    );
    return clarification(id)!;
  }

  // --------------------------------------------------------- summaries ----

  void addSummary({
    required String conversationId,
    required String text,
    required List<Map<String, Object?>> citations,
  }) {
    db.execute(
      'INSERT INTO agent_summaries (conversation_id, text, citations, '
      'source_count, created_at) VALUES (?,?,?,?,?)',
      [
        conversationId,
        text,
        jsonEncode(citations),
        '${citations.length}',
        _isoNow(),
      ],
    );
  }

  List<Map<String, Object?>> summaries(String conversationId,
      {int limit = 5}) =>
      [
        for (final r in db.query(
          'SELECT id, text, citations, source_count, created_at '
          'FROM agent_summaries WHERE conversation_id=? '
          'ORDER BY id DESC LIMIT ?',
          [conversationId, '$limit'],
        ))
          {
            'id': r['id'],
            'text': r['text'],
            'citations': _decodeList(r['citations']),
            'sourceCount': int.tryParse(r['source_count'] as String? ?? '0'),
            'createdAt': r['created_at'],
          },
      ];

  // ------------------------------------------------------- compactions ----

  Map<String, Object?> addCompaction({
    required String conversationId,
    required String id,
    required String strategy,
    required String summary,
    required List<String> originalIds,
    required String originalsDigest,
    required int keptCount,
  }) {
    db.execute(
      'INSERT INTO agent_compactions (id, conversation_id, strategy, summary, '
      'original_ids, originals_digest, original_count, kept_count, created_at) '
      'VALUES (?,?,?,?,?,?,?,?,?)',
      [
        id,
        conversationId,
        strategy,
        summary,
        jsonEncode(originalIds),
        originalsDigest,
        '${originalIds.length}',
        '$keptCount',
        _isoNow(),
      ],
    );
    return {
      'id': id,
      'strategy': strategy,
      'originalCount': originalIds.length,
      'keptCount': keptCount,
      'originalsDigest': originalsDigest,
    };
  }

  List<Map<String, Object?>> compactions(String conversationId) => [
        for (final r in db.query(
            'SELECT id, strategy, summary, original_ids, originals_digest, '
            'original_count, kept_count, created_at FROM agent_compactions '
            'WHERE conversation_id=? ORDER BY created_at ASC',
            [conversationId]))
          {
            'id': r['id'],
            'strategy': r['strategy'],
            'summary': r['summary'],
            'originalIds': _decodeList(r['original_ids']),
            'originalsDigest': r['originals_digest'],
            'originalCount':
                int.tryParse(r['original_count'] as String? ?? '0'),
            'keptCount': int.tryParse(r['kept_count'] as String? ?? '0'),
            'createdAt': r['created_at'],
          },
      ];

  // --------------------------------------------------------- approvals ----

  Map<String, Object?> createApprovalRequest({
    required String conversationId,
    required String id,
    required String toolId,
    required String action,
    required String risk,
    required String reason,
    required Map<String, Object?> preview,
  }) {
    db.execute(
      'INSERT INTO agent_approvals (id, conversation_id, tool_id, action, '
      'risk, reason, preview_json, status, created_at) VALUES (?,?,?,?,?,?,?,?,?)',
      [
        id,
        conversationId,
        toolId,
        action,
        risk,
        reason,
        jsonEncode(preview),
        'pending',
        _isoNow(),
      ],
    );
    return {
      'id': id,
      'toolId': toolId,
      'action': action,
      'risk': risk,
      'reason': reason,
      'preview': preview,
      'status': 'pending',
    };
  }

  Map<String, Object?>? approvalRequest(String id) {
    final rows = db.query('SELECT * FROM agent_approvals WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'id': r['id'],
      'conversationId': r['conversation_id'],
      'toolId': r['tool_id'],
      'action': _nullIfEmpty(r['action']),
      'risk': r['risk'],
      'reason': _nullIfEmpty(r['reason']),
      'preview': _decodeMap(r['preview_json']),
      'status': r['status'],
      'decidedBy': _nullIfEmpty(r['decided_by']),
      'decidedAt': _nullIfEmpty(r['decided_at']),
      'note': _nullIfEmpty(r['note']),
      'createdAt': r['created_at'],
    };
  }

  Map<String, Object?> decideApproval(
      String id, bool approved, String decidedBy, String? note) {
    if (approvalRequest(id) == null) {
      throw _notFound('Pedido de aprovação "$id"');
    }
    db.execute(
      'UPDATE agent_approvals SET status=?, decided_by=?, decided_at=?, '
      'note=? WHERE id=?',
      [
        approved ? 'approved' : 'rejected',
        decidedBy,
        _isoNow(),
        note ?? '',
        id,
      ],
    );
    return approvalRequest(id)!;
  }

  List<Map<String, Object?>> approvalRequests(
          {String? conversationId, String? status}) =>
      [
        for (final r in db.query(
          'SELECT id FROM agent_approvals'
          '${[
            if (conversationId != null) 'conversation_id=?',
            if (status != null) 'status=?',
          ].isEmpty ? '' : ' WHERE ${[
                if (conversationId != null) 'conversation_id=?',
                if (status != null) 'status=?',
              ].join(' AND ')}'}'
          ' ORDER BY created_at ASC',
          [
            if (conversationId != null) conversationId,
            if (status != null) status,
          ],
        ))
          approvalRequest(r['id'] as String)!,
      ];
}
