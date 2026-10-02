/// Tools de operação do agente (spec catálogo: `agent.*` + `todo.list`).
///
/// Cada tool opera sobre estado REAL persistido ([AgentStateStore] em SQLite
/// via FFI) — nada de resposta decorativa:
/// - `agent.plan.create`        — cria plano estruturado (modelo [AgentPlan]);
/// - `agent.plan.update`        — atualiza o plano real, gravando revisão;
/// - `agent.task.start`         — inicia tarefa com audit trail (timestamp,
///                                nota e histórico de eventos imutável);
/// - `agent.task.complete`      — conclui tarefa APÓS verificação (exige o
///                                resultado da checagem + evidências);
/// - `agent.reflect.evaluate`   — avalia resultado contra critérios reais
///                                (evidências verificadas no disco, quando
///                                o critério aponta um arquivo);
/// - `agent.clarify`            — registra pedido de esclarecimento quando a
///                                tarefa é ambígua (status awaiting até o
///                                usuário responder);
/// - `agent.context.summarize`  — resume contexto CITANDO fontes reais
///                                (memórias, mensagens persistidas, arquivos
///                                lidos do workspace, tarefas/plano atuais);
/// - `agent.history.compact`    — compacta histórico criando um resumo que
///                                REFERENCIA os itens originais (com digest
///                                SHA-256 deles); os originais permanecem no
///                                banco, intactos;
/// - `agent.approval.request`   — cria pedido de aprovação persistido, ligado
///                                à política real da tool no registro;
/// - `todo.list`                — lista as tarefas reais (estado do banco),
///                                não uma lista em memória do modelo.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../domain/errors/vt_failure.dart';
import '../../domain/models/core_models.dart';
import '../../domain/state/agent_states.dart';
import '../../application/tool_registry.dart';
import '../../domain/tools/tool_contract.dart';
import '../native/sqlite_native.dart';
import 'agent_state_store.dart';

Future<ToolResult<O>> _guard<O extends ToolOutput>(
    VtTool<dynamic, O> tool, Future<ToolResult<O>> Function() body) async {
  try {
    return await body().timeout(tool.timeout);
  } on TimeoutException {
    return ToolFailureResult<O>(VtFailure.timeout(tool.timeout));
  } on VtFailure catch (f) {
    return ToolFailureResult<O>(f);
  } on FormatException catch (e) {
    return ToolFailureResult<O>(VtFailure(
        code: VtErrorCode.validationFailed, message: e.message));
  }
}

abstract class _AgentTool extends VtTool<MapToolInput, TextOutput> {
  _AgentTool(this.store);
  final AgentStateStore store;

  @override
  ToolCategory get category => ToolCategory.agent;
  @override
  List<String> get capabilities => const ['sqlite'];
  @override
  Duration get timeout => const Duration(seconds: 15);
  @override
  RetryPolicy get retryPolicy => const RetryPolicy();
  @override
  Map<String, Object?> get outputSchema => const {'type': 'object'};
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;

  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async =>
      const HealthOk('agent state store pronto (SQLite)');

  /// Escopo da conversa: id da conversa ativa ou a primeira raiz do
  /// workspace (mesmo padrão das tools de memória/checkpoint).
  String scopeOf(ToolContext ctx, MapToolInput input) {
    final explicit = input.str('conversation_id');
    if (explicit.isNotEmpty) return explicit;
    if (ctx.conversationId != null && ctx.conversationId!.isNotEmpty) {
      return ctx.conversationId!;
    }
    if (ctx.workspaceRoots.isEmpty) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Sem conversa ativa nem workspace aberto para escopar o '
            'registro do agente.',
      );
    }
    return ctx.workspaceRoots.first;
  }

  ToolResult<TextOutput> ok(Object data,
          {Map<String, Object?> usage = const {},
          List<Citation> citations = const []}) =>
      ToolSuccess(
        data: TextOutput(const JsonEncoder.withIndent('  ').convert(data)),
        usage: usage.isEmpty ? null : usage,
        citations: citations,
      );
}

List<String> _strList(Map<String, Object?> values, String key) => [
      for (final e in (values[key] as List? ?? const [])) e.toString(),
    ];

Map<String, Object?>? _mapOrNull(Map<String, Object?> values, String key) {
  final v = values[key];
  return v is Map ? v.cast<String, Object?>() : null;
}

// ------------------------------------------------------------ plan create
class AgentPlanCreateTool extends _AgentTool {
  AgentPlanCreateTool(super.store);

  @override
  String get id => 'agent.plan.create';
  @override
  String get title => 'Criar plano estruturado';
  @override
  String get description =>
      'Cria um plano estruturado REAL (objetivo, hipóteses, arquivos '
      'afetados, tools necessárias, riscos, critérios de aceitação, passos '
      'com dependências, verificação e rollback) e persiste como revisão 1 '
      'no banco local. Retorna o plano com ids gerados.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  bool get isIdempotent => false; // cada chamada cria um plano novo
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['objective', 'steps'],
        'properties': {
          'objective': {'type': 'string'},
          'hypotheses': {'type': 'array', 'items': {'type': 'string'}},
          'affected_files': {'type': 'array', 'items': {'type': 'string'}},
          'required_tools': {'type': 'array', 'items': {'type': 'string'}},
          'risks': {'type': 'array', 'items': {'type': 'string'}},
          'acceptance_criteria': {'type': 'array', 'items': {'type': 'string'}},
          'verification': {'type': 'string'},
          'rollback_plan': {'type': 'string'},
          'conversation_id': {'type': 'string'},
          'steps': {
            'type': 'array',
            'minItems': 1,
            'items': {
              'type': 'object',
              'required': ['title'],
              'properties': {
                'title': {'type': 'string'},
                'depends_on': {'type': 'array', 'items': {'type': 'integer'}},
                'tool_ids': {'type': 'array', 'items': {'type': 'string'}},
                'acceptance_criteria': {
                  'type': 'array',
                  'items': {'type': 'string'}
                },
              },
            },
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final rawSteps = (input.values['steps'] as List? ?? const [])
            .whereType<Map<Object?, Object?>>()
            .toList();
        if (rawSteps.isEmpty) {
          return ToolFailureResult<TextOutput>(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'O plano precisa de pelo menos 1 passo em "steps".',
          ));
        }
        final steps = <AgentPlanStep>[];
        for (var i = 0; i < rawSteps.length; i++) {
          final s = rawSteps[i].cast<String, Object?>();
          final title = (s['title'] as String?)?.trim() ?? '';
          if (title.isEmpty) {
            return ToolFailureResult<TextOutput>(VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Passo $i exige "title" não vazio.',
            ));
          }
          steps.add(AgentPlanStep(
            index: i,
            title: title,
            status: PlanStepStatus.pending,
            dependsOn: [
              for (final d in (s['depends_on'] as List? ?? const []))
                (d as num).toInt()
            ],
            toolIds: (s['tool_ids'] as List? ?? const [])
                .map((e) => e.toString())
                .toList(),
            acceptanceCriteria: (s['acceptance_criteria'] as List? ?? const [])
                .map((e) => e.toString())
                .toList(),
          ));
        }
        // dependências precisam apontar para passos existentes
        for (final st in steps) {
          for (final d in st.dependsOn) {
            if (d < 0 || d >= steps.length || d == st.index) {
              return ToolFailureResult<TextOutput>(VtFailure(
                code: VtErrorCode.validationFailed,
                message: 'Passo ${st.index} depende de "$d", que não é um '
                    'passo válido anterior.',
              ));
            }
          }
        }
        final scope = scopeOf(ctx, input);
        final plan = store.createPlan(
          conversationId: scope,
          plan: AgentPlan(
            id: AgentStateStore.newId('plan'),
            agentRunId: ctx.agentRunId ?? '',
            objective: input.str('objective').trim(),
            hypotheses: _strList(input.values, 'hypotheses'),
            affectedFiles: _strList(input.values, 'affected_files'),
            requiredTools: _strList(input.values, 'required_tools'),
            risks: _strList(input.values, 'risks'),
            acceptanceCriteria:
                _strList(input.values, 'acceptance_criteria'),
            steps: steps,
            verification: input.str('verification'),
            rollbackPlan: input.str('rollback_plan'),
            createdAt: DateTime.now().toUtc(),
          ),
        );
        return ok({
          'status': 'created',
          'scope': scope,
          'revision': 1,
          'plan': plan.toJson(),
        }, usage: {
          'steps': plan.steps.length,
        });
      });
}

// ------------------------------------------------------------ plan update
class AgentPlanUpdateTool extends _AgentTool {
  AgentPlanUpdateTool(super.store);

  @override
  String get id => 'agent.plan.update';
  @override
  String get title => 'Atualizar plano real';
  @override
  String get description =>
      'Atualiza o plano PERSISTIDO (por plan_id, ou o mais recente do escopo '
      'se omitido): status/título de passos, objetivo, critérios, verificação '
      'e rollback. Cada update grava uma nova REVISÃO imutável — o histórico '
      'completo do plano fica consultável.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  bool get isIdempotent => false; // cada update gera uma revisão nova
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'plan_id': {'type': 'string'},
          'conversation_id': {'type': 'string'},
          'objective': {'type': 'string'},
          'acceptance_criteria': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'verification': {'type': 'string'},
          'rollback_plan': {'type': 'string'},
          'change_note': {'type': 'string'},
          'step_updates': {
            'type': 'array',
            'items': {
              'type': 'object',
              'required': ['index', 'status'],
              'properties': {
                'index': {'type': 'integer'},
                'status': {
                  'type': 'string',
                  'enum': [
                    'pending',
                    'approved',
                    'running',
                    'succeeded',
                    'failed',
                    'skipped',
                    'rolled_back'
                  ]
                },
                'title': {'type': 'string'},
              },
            },
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final scope = scopeOf(ctx, input);
        final planId = input.str('plan_id');
        final current =
            planId.isEmpty ? store.latestPlan(scope) : store.planById(planId);
        if (current == null) {
          return ToolFailureResult<TextOutput>(VtFailure(
            code: VtErrorCode.validationFailed,
            message: planId.isEmpty
                ? 'Nenhum plano persistido para este escopo ($scope). '
                    'Chame agent.plan.create primeiro.'
                : 'Plano "$planId" não existe no banco.',
            recoveryActions: const [
              RecoveryAction(
                  kind: 'create_plan', label: 'Criar plano com agent.plan.create'),
            ],
          ));
        }
        final updates = (input.values['step_updates'] as List? ?? const [])
            .whereType<Map<Object?, Object?>>()
            .toList();
        final statuses = <int, PlanStepStatus>{};
        final titles = <int, String>{};
        for (final u in updates) {
          final m = u.cast<String, Object?>();
          final idx = (m['index'] as num?)?.toInt();
          if (idx == null || idx < 0 || idx >= current.steps.length) {
            return ToolFailureResult<TextOutput>(VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'step_updates: índice "$idx" fora do plano '
                  '(0..${current.steps.length - 1}).',
            ));
          }
          final statusWire = m['status'] as String?;
          if (statusWire != null) {
            statuses[idx] = PlanStepStatus.values.firstWhere(
              (s) => s.wire == statusWire,
              orElse: () => throw VtFailure(
                code: VtErrorCode.validationFailed,
                message: 'Status de passo inválido: "$statusWire".',
              ),
            );
          }
          final t = (m['title'] as String?)?.trim();
          if (t != null && t.isNotEmpty) titles[idx] = t;
        }
        final ac = input.values.containsKey('acceptance_criteria')
            ? _strList(input.values, 'acceptance_criteria')
            : null;
        final updated = store.updatePlan(
          planId: current.id,
          objective: (input.values['objective'] as String?)?.trim(),
          acceptanceCriteria: ac,
          verification: input.values['verification'] as String?,
          rollbackPlan: input.values['rollback_plan'] as String?,
          stepStatuses: statuses.isEmpty ? null : statuses,
          stepTitles: titles.isEmpty ? null : titles,
          changeNote: input.str('change_note'),
        );
        final revs = store.planRevisions(updated.id);
        return ok({
          'status': 'updated',
          'plan_id': updated.id,
          'revision': revs.length,
          'steps': [for (final s in updated.steps) s.toJson()],
          'revision_history': [
            for (final r in revs)
              {'revision': r['revision'], 'note': r['change_note']},
          ],
        }, usage: {
          'stepStatusChanges': statuses.length,
        });
      });
}

// ------------------------------------------------------------- task start
class AgentTaskStartTool extends _AgentTool {
  AgentTaskStartTool(super.store);

  @override
  String get id => 'agent.task.start';
  @override
  String get title => 'Iniciar tarefa com audit trail';
  @override
  String get description =>
      'Inicia (ou cria e inicia) uma tarefa registrando AUDIT TRAIL real: '
      'id, timestamp UTC, nota de início e histórico de eventos persistidos '
      'em SQLite. Se "task_id" for omitido, "title" cria a tarefa vinculada '
      'ao passo "step_index" do plano quando informado.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  bool get isIdempotent => false; // iniciar duas vezes = efeito real distinto
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'task_id': {'type': 'string'},
          'title': {'type': 'string'},
          'note': {'type': 'string'},
          'plan_id': {'type': 'string'},
          'step_index': {'type': 'integer'},
          'conversation_id': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final note = input.str('note');
        if (note.isEmpty) {
          return ToolFailureResult<TextOutput>(VtFailure(
            code: VtErrorCode.validationFailed,
            message: '"note" descrevendo o que será feito é obrigatória no '
                'audit trail de agent.task.start.',
          ));
        }
        final scope = scopeOf(ctx, input);
        var taskId = input.str('task_id');
        if (taskId.isEmpty) {
          final title = input.str('title').trim();
          if (title.isEmpty) {
            return ToolFailureResult<TextOutput>(VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Informe "task_id" de uma tarefa existente ou "title" '
                  'para criar uma nova.',
            ));
          }
          final created = store.createTask(
            conversationId: scope,
            title: title,
            planId: input.str('plan_id'),
            stepIndex: input.intOrNull('step_index'),
          );
          taskId = created.id;
        }
        final task = store.startTask(taskId: taskId, note: note);
        return ok({
          'status': 'started',
          'task': task.toJson(),
        }, usage: {
          'trailEvents': task.notes.length,
        });
      });
}

// ---------------------------------------------------------- task complete
class AgentTaskCompleteTool extends _AgentTool {
  AgentTaskCompleteTool(super.store);

  @override
  String get id => 'agent.task.complete';
  @override
  String get title => 'Concluir tarefa após verificação';
  @override
  String get description =>
      'Conclui uma tarefa EM EXECUÇÃO somente com verificação real: exige '
      '"verify_result" (o que foi checado e o resultado), "evidence" '
      '(refs de arquivos/testes/logs) e "note". A conclusão recusa tarefas '
      'não iniciadas e grava tudo no audit trail.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['task_id', 'verify_result', 'note'],
        'properties': {
          'task_id': {'type': 'string'},
          'verify_result': {'type': 'string'},
          'note': {'type': 'string'},
          'evidence': {'type': 'array', 'items': {'type': 'string'}},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final verify = input.str('verify_result').trim();
        if (verify.isEmpty) {
          return ToolFailureResult<TextOutput>(VtFailure(
            code: VtErrorCode.validationFailed,
            message: '"verify_result" não pode ser vazio: informe a checagem '
                'real feita antes de concluir.',
          ));
        }
        final evidence = _strList(input.values, 'evidence');
        // Evidência apontando arquivo inexistente é falha honesta, não aceite.
        for (final e in evidence) {
          if (e.startsWith('/') || e.contains(Platform.pathSeparator)) {
            final f = File(e);
            if (!f.existsSync() && !Directory(e).existsSync()) {
              return ToolFailureResult<TextOutput>(VtFailure(
                code: VtErrorCode.validationFailed,
                message: 'Evidência "$e" não existe no disco — conclusão '
                    'bloqueada até a verificação citar algo real.',
              ));
            }
          }
        }
        final task = store.completeTask(
          taskId: input.str('task_id'),
          verifyResult: verify,
          evidence: evidence,
          note: input.str('note'),
        );
        return ok({
          'status': 'done',
          'task': task.toJson(),
        }, usage: {
          'evidenceCount': evidence.length,
          'trailEvents': task.notes.length,
        });
      });
}

// -------------------------------------------------------- reflect evaluate
class AgentReflectEvaluateTool extends _AgentTool {
  AgentReflectEvaluateTool(super.store);

  @override
  String get id => 'agent.reflect.evaluate';
  @override
  String get title => 'Avaliar resultado contra critérios';
  @override
  String get description =>
      'Avalia o resultado de uma tarefa contra critérios de aceitação REAIS: '
      'critérios do próprio plano/passo são combinados com os passados em '
      '"criteria". Critérios com "check_file" são verificados no disco (via '
      'sandbox) e "expect_contains" comparado byte a byte do arquivo real. '
      'Veredito met|partial|unmet é calculado dos checks efetivos e '
      'persistido junto da tarefa.';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['task_id'],
        'properties': {
          'task_id': {'type': 'string'},
          'result_summary': {'type': 'string'},
          'criteria': {
            'type': 'array',
            'items': {
              'type': 'object',
              'required': ['criterion'],
              'properties': {
                'criterion': {'type': 'string'},
                'check_file': {'type': 'string'},
                'expect_contains': {'type': 'string'},
              },
            },
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final task = store.requireTask(input.str('task_id'));
        final criteriaRaw = (input.values['criteria'] as List? ?? const [])
            .whereType<Map<Object?, Object?>>()
            .toList();

        // critérios herdados do plano real, quando a tarefa está vinculada
        final plan = task.planId == null
            ? null
            : (store.planById(task.planId!) ??
                store.latestPlan(task.conversationId));
        final textCriteria = <String>[
          ..._strList(input.values, 'text_criteria'),
          if (plan != null) ...plan.acceptanceCriteria,
          if (plan != null && task.stepIndex != null)
            for (final s in plan.steps)
              if (s.index == task.stepIndex) ...s.acceptanceCriteria,
        ];

        final checks = <Map<String, Object?>>[];
        for (final c in criteriaRaw) {
          final m = c.cast<String, Object?>();
          final criterion = (m['criterion'] as String? ?? '').trim();
          final checkFile = (m['check_file'] as String?)?.trim();
          final expect = m['expect_contains'] as String?;
          String status;
          String detail;
          if (checkFile == null || checkFile.isEmpty) {
            status = 'manual';
            detail = 'sem checagem automatizada declarada';
          } else {
            try {
              final abs = await ctx.sandbox.resolveReadable(checkFile, ctx);
              final content = await File(abs).readAsString();
              if (expect == null || expect.isEmpty) {
                status = 'met';
                detail = 'arquivo existe (${content.length} bytes lidos)';
              } else if (content.contains(expect)) {
                status = 'met';
                detail = 'conteúdo contém a string esperada';
              } else {
                status = 'unmet';
                detail = 'arquivo lido mas sem a string esperada';
              }
            } on VtFailure catch (f) {
              status = 'unmet';
              detail = f.message;
            } on FileSystemException catch (e) {
              status = 'unmet';
              detail = 'falha ao ler "$checkFile": ${e.osError?.message ?? e.message}';
            }
          }
          checks.add({
            'criterion': criterion,
            'status': status,
            'detail': detail,
            if (checkFile != null && checkFile.isNotEmpty) 'file': checkFile,
          });
        }
        for (final c in textCriteria) {
          checks.add({
            'criterion': c,
            'status': 'manual',
            'detail': 'critério textual do plano — requer julgamento do agente/usuário',
          });
        }

        final automated = checks.where((c) => c['status'] != 'manual').toList();
        final met = automated.where((c) => c['status'] == 'met').length;
        final verdict = automated.isEmpty
            ? 'partial' // só há critérios manuais: nada verificado de fato
            : (met == automated.length
                ? 'met'
                : (met == 0 ? 'unmet' : 'partial'));

        final report = <String, Object?>{
          'task_id': task.id,
          'verdict': verdict,
          'automated_checks': automated.length,
          'automated_met': met,
          'manual_pending': checks.length - automated.length,
          'checks': checks,
          if (input.str('result_summary').isNotEmpty)
            'result_summary': input.str('result_summary'),
        };
        store.addReflection(taskId: task.id, report: report);
        return ok(report, usage: {
          'checks': checks.length,
        }, citations: [
          Citation(sourceType: 'task', sourceRef: 'task://${task.id}', label: task.title),
          for (final c in checks)
            if (c['file'] != null)
              Citation(
                  sourceType: 'file',
                  sourceRef: c['file'] as String,
                  label: c['criterion'] as String),
        ]);
      });
}

// ---------------------------------------------------------------- clarify
class AgentClarifyTool extends _AgentTool {
  AgentClarifyTool(super.store);

  @override
  String get id => 'agent.clarify';
  @override
  String get title => 'Solicitar esclarecimento';
  @override
  String get description =>
      'Registra um pedido de esclarecimento PERSISTIDO quando a tarefa é '
      'ambígua: pergunta, lista de ambiguidades e opções concretas. Retorna '
      'status "awaiting" — o run deve pausar até o usuário responder (a '
      'resposta é registrada na mesma tabela via "answer"). Nunca segue com '
      'suposição silenciosa.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
          'ambiguities': {'type': 'array', 'items': {'type': 'string'}},
          'options': {'type': 'array', 'items': {'type': 'string'}},
          'conversation_id': {'type': 'string'},
          'clarify_id': {'type': 'string', 'description': 'responde a um pedido existente'},
          'answer': {'type': 'string', 'description': 'resposta do usuário (requer clarify_id)'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final clarifyId = input.str('clarify_id');
        if (clarifyId.isNotEmpty) {
          final answer = input.str('answer');
          if (answer.isEmpty) {
            return ToolFailureResult<TextOutput>(VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Para responder um pedido existente, envie "answer".',
            ));
          }
          final rec = store.answerClarification(clarifyId, answer);
          return ok({'status': 'answered', 'clarification': rec});
        }
        final question = input.str('question').trim();
        if (question.isEmpty) {
          return ToolFailureResult<TextOutput>(VtFailure(
            code: VtErrorCode.validationFailed,
            message: '"question" é obrigatória ao abrir um esclarecimento.',
          ));
        }
        final ambiguities = _strList(input.values, 'ambiguities');
        if (ambiguities.isEmpty) {
          return ToolFailureResult<TextOutput>(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Liste em "ambiguities" O QUE exatamente está ambíguo — '
                'esclarecer sem nomear a ambiguidade não ajuda o usuário.',
          ));
        }
        final rec = store.createClarification(
          conversationId: scopeOf(ctx, input),
          id: AgentStateStore.newId('clar'),
          question: question,
          ambiguities: ambiguities,
          options: _strList(input.values, 'options'),
        );
        return ok({
          'status': 'awaiting_user',
          'clarification': rec,
          'instruction': 'Pare o run e aguarde a resposta do usuário antes de continuar.',
        });
      });
}

// ------------------------------------------------------- context summarize
class AgentContextSummarizeTool extends _AgentTool {
  AgentContextSummarizeTool(super.store, {this.messagesDb});

  /// DB de chat (mensagens/conversas reais). Quando omitido usa o mesmo DB
  /// do store — em produção ambos vivem no techvt.sqlite.
  final SqliteDb? messagesDb;

  @override
  String get id => 'agent.context.summarize';
  @override
  String get title => 'Resumir contexto citando fontes';
  @override
  String get description =>
      'Monta um resumo do contexto ATUAL a partir de fontes reais consultadas '
      'agora: mensagens persistidas da conversa, tarefas e plano vigentes, '
      'memórias do workspace e arquivos citados (lidos do disco via sandbox). '
      'Cada linha do resumo carrega citação de fonte; o resumo é persistido '
      'com suas citações. Recusa produzir resumo sem nenhuma fonte.';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'conversation_id': {'type': 'string'},
          'focus': {'type': 'string', 'description': 'recorte do resumo'},
          'include_files': {'type': 'array', 'items': {'type': 'string'}},
          'max_messages': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final scope = scopeOf(ctx, input);
        final focus = input.str('focus');
        final maxMessages = (input.intOrNull('max_messages') ?? 8).clamp(1, 50);
        final lines = <String>[];
        final citations = <Map<String, Object?>>[];
        final dartCitations = <Citation>[];

        void cite(String type, String ref, String label, String line) {
          lines.add('- $line');
          citations.add({
            'sourceType': type, 'sourceRef': ref, 'label': label,
          });
          dartCitations.add(Citation(
              sourceType: type, sourceRef: ref, label: label));
        }

        // 1) mensagens reais da conversa (persistidas no SQLite de chat)
        final mdb = messagesDb ?? store.db;
        try {
          final msgs = mdb.query(
            'SELECT id, role, blocks_json, created_at FROM messages '
            'WHERE conversation_id=? ORDER BY created_at DESC LIMIT ?',
            [scope, '$maxMessages'],
          );
          for (final m in msgs.reversed) {
            final blocks = (jsonDecode(m['blocks_json'] as String? ?? '[]')
                    as List)
                .whereType<Map<Object?, Object?>>()
                .toList();
            final text = blocks
                .map((b) => (b['text'] ?? b['content'] ?? '').toString())
                .firstWhere((t) => t.trim().isNotEmpty, orElse: () => '')
                .trim();
            if (text.isEmpty) continue;
            final snippet =
                text.length > 140 ? '${text.substring(0, 140)}…' : text;
            cite('message', 'msg://${m['id']}', '${m['role']}: $snippet',
                '${m['role']}: $snippet');
          }
        } on SqliteException {
          // tabela de mensagens ainda não criada neste DB: segue sem essa fonte
        }

        // 2) plano e tarefas reais do escopo
        final plan = store.latestPlan(scope);
        if (plan != null) {
          final done = plan.steps.where((s) => s.status.wire == 'succeeded').length;
          cite('plan', 'plan://${plan.id}', plan.objective,
              'plano "${plan.objective}" — ${done}/${plan.steps.length} passos '
                  'sucedidos (revisões registradas)');
        }
        final tasks = store.tasks(conversationId: scope);
        if (tasks.isNotEmpty) {
          final running = tasks.where((t) => t.status == 'running').toList();
          final doneT = tasks.where((t) => t.status == 'done').toList();
          cite('task', 'task://${running.isNotEmpty ? running.first.id : tasks.last.id}',
              '${tasks.length} tarefas',
              'tarefas: ${tasks.length} no total, ${doneT.length} concluídas, '
                  '${running.length} em execução'
              '${running.isNotEmpty ? ' (${running.map((t) => t.title).join(', ')})' : ''}');
        }

        // 3) memórias do workspace (fonte memory:// real)
        final ws = ctx.workspaceRoots.isEmpty ? null : ctx.workspaceRoots.first;
        if (ws != null) {
          final mems = store.db.query(
            'SELECT id, title, kind FROM memories WHERE workspace_id=? '
            'ORDER BY weight DESC LIMIT 3',
            [ws],
          );
          for (final m in mems) {
            cite('memory', 'memory://${m['id']}', m['title'] as String,
                'memória (${m['kind']}): ${m['title']}');
          }
        }

        // 4) arquivos pedidos — lidos DE FATO via sandbox (hash como prova)
        for (final path in _strList(input.values, 'include_files')) {
          try {
            final abs = await ctx.sandbox.resolveReadable(path, ctx);
            final bytes = await File(abs).readAsBytes();
            final sha = sha256.convert(bytes).toString();
            cite('file', abs, path,
                'arquivo "$path": ${bytes.length} bytes, sha256=${sha.substring(0, 16)}…');
          } on VtFailure catch (f) {
            lines.add('- arquivo "$path" indisponível: ${f.message}');
          } on FileSystemException catch (e) {
            lines.add('- arquivo "$path" indisponível: ${e.message}');
          }
        }

        if (lines.isEmpty) {
          return ToolFailureResult<TextOutput>(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Sem nenhuma fonte real para resumir neste escopo '
                '($scope): sem mensagens, plano, tarefas, memórias ou '
                'arquivos acessíveis. Resumo sem fonte não é produzido.',
          ));
        }
        final header = focus.isEmpty
            ? 'Resumo do contexto ($scope):'
            : 'Resumo do contexto ($scope) — foco: $focus:';
        final text = ([header, ...lines]).join('\n');
        store.addSummary(
            conversationId: scope, text: text, citations: citations);
        return ok({
          'status': 'summarized',
          'summary': text,
          'sources': citations.length,
        }, usage: {
          'lines': lines.length,
          'sources': citations.length,
        }, citations: dartCitations);
      });
}

// -------------------------------------------------------- history compact
class AgentHistoryCompactTool extends _AgentTool {
  AgentHistoryCompactTool(super.store, {this.messagesDb});

  final SqliteDb? messagesDb;

  @override
  String get id => 'agent.history.compact';
  @override
  String get title => 'Compactar histórico preservando originais';
  @override
  String get description =>
      'Compacta o histórico de uma conversa criando um REGISTRO DE COMPACTAÇÃO '
      'que referencia os ids originais das mensagens e seu digest SHA-256 — '
      'os originais NUNCA são apagados nem alterados (continam em `messages`). '
      '"strategy": keep_recent (mantém as N mais recentes verbatim e resume o '
      'resto) | digest (resume tudo em um bloco). Retorna o resumo canônico '
      'para o próximo assemble de contexto.';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'conversation_id': {'type': 'string'},
          'strategy': {
            'type': 'string',
            'enum': ['keep_recent', 'digest'],
          },
          'keep_last': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final scope = scopeOf(ctx, input);
        final strategy =
            input.values['strategy'] as String? ?? 'keep_recent';
        final keepLast = (input.intOrNull('keep_last') ?? 4).clamp(0, 100);

        final mdb = messagesDb ?? store.db;
        List<Map<String, Object?>> rows;
        try {
          rows = mdb.query(
            'SELECT id, role, blocks_json, created_at FROM messages '
            'WHERE conversation_id=? ORDER BY created_at ASC',
            [scope],
          );
        } on SqliteException {
          rows = const [];
        }
        if (rows.isEmpty) {
          return ToolFailureResult<TextOutput>(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Nenhuma mensagem persistida para "$scope" — não há '
                'histórico real a compactar.',
          ));
        }

        final split = strategy == 'keep_recent' && rows.length > keepLast
            ? rows.length - keepLast
            : (strategy == 'keep_recent' ? rows.length : 0);
        final compacted = rows.sublist(0, split);
        final kept = rows.sublist(split);

        final digest = sha256
            .convert(utf8.encode(compacted.map((r) => r['id']).join('|')))
            .toString();

        final bullets = <String>[];
        for (final r in compacted) {
          final blocks =
              (jsonDecode(r['blocks_json'] as String? ?? '[]') as List)
                  .whereType<Map<Object?, Object?>>()
                  .toList();
          final text = blocks
              .map((b) => (b['text'] ?? b['content'] ?? '').toString())
              .firstWhere((t) => t.trim().isNotEmpty, orElse: () => '')
              .trim()
              .replaceAll('\n', ' ');
          final snippet =
              text.length > 120 ? '${text.substring(0, 120)}…' : text;
          bullets.add('[${r['created_at']}] ${r['role']}: $snippet');
        }
        final summaryText = bullets.isEmpty
            ? '(nada a compactar — histórico integral mantido)'
            : 'Histórico compactado (${compacted.length} itens, digest '
                'sha256=$digest):\n${bullets.map((b) => '- $b').join('\n')}';

        final rec = store.addCompaction(
          conversationId: scope,
          id: AgentStateStore.newId('cmp'),
          strategy: strategy,
          summary: summaryText,
          originalIds: [for (final r in compacted) r['id'] as String],
          originalsDigest: digest,
          keptCount: kept.length,
        );

        // prova de preservação: originais continuam contáveis no banco
        final stillThere = mdb.query(
          'SELECT COUNT(*) AS c FROM messages WHERE conversation_id=?',
          [scope],
        );

        return ok({
          'status': 'compacted',
          'compaction': rec,
          'kept_verbatim': [for (final r in kept) r['id']],
          'originals_preserved_count': int.tryParse(
              (stillThere.first['c'] as String?) ?? '${rows.length}'),
        }, usage: {
          'originals': rows.length,
          'compacted': compacted.length,
          'kept': kept.length,
        }, citations: [
          for (final r in compacted)
            Citation(
                sourceType: 'message',
                sourceRef: 'msg://${r['id']}',
                label: 'original preservado'),
        ]);
      });
}

// -------------------------------------------------------- approval request
class AgentApprovalRequestTool extends _AgentTool {
  AgentApprovalRequestTool(super.store, {this.registry});

  /// Registro de tools real — usado para amarrar o pedido à política/risco
  /// efetivos da tool alvo (quando "tool_id" existe no catálogo).
  final ToolRegistry? registry;

  @override
  String get id => 'agent.approval.request';
  @override
  String get title => 'Criar pedido de aprovação';
  @override
  String get description =>
      'Cria um pedido de aprovação PERSISTIDO (status pending) para uma ação '
      'concreta: tool alvo, risco, motivo e preview do input. Se a tool '
      'existir no registro, o risco/policy reais dela são anexados. '
      'Approve/reject acontece pela UI de aprovação (ApprovalGateway) ou por '
      '"decision" nesta tool, sempre registrando quem decidiu e quando.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'tool_id': {'type': 'string'},
          'action': {'type': 'string'},
          'reason': {'type': 'string'},
          'preview': {'type': 'object'},
          'conversation_id': {'type': 'string'},
          'approval_id': {'type': 'string', 'description': 'decide um pedido existente'},
          'decision': {'type': 'string', 'enum': ['approve', 'reject']},
          'decided_by': {'type': 'string'},
          'note': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final approvalId = input.str('approval_id');
        if (approvalId.isNotEmpty) {
          final decision = input.str('decision');
          if (decision != 'approve' && decision != 'reject') {
            return ToolFailureResult<TextOutput>(VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Para decidir um pedido existente, envie "decision" '
                  '= approve|reject.',
            ));
          }
          final by = input.str('decided_by');
          if (by.isEmpty) {
            return ToolFailureResult<TextOutput>(VtFailure(
              code: VtErrorCode.validationFailed,
              message: '"decided_by" é obrigatório: toda decisão precisa de '
                  'autor identificável no registro.',
            ));
          }
          final rec = store.decideApproval(
              approvalId, decision == 'approve', by, input.str('note'));
          return ok({'status': rec['status'], 'approval': rec});
        }

        final toolId = input.str('tool_id').trim();
        final action = input.str('action').trim();
        if (toolId.isEmpty && action.isEmpty) {
          return ToolFailureResult<TextOutput>(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Informe "tool_id" e/ou "action" — pedido de aprovação '
                'genérico sem alvo não bloqueia nada.',
          ));
        }
        final reason = input.str('reason').trim();
        if (reason.isEmpty) {
          return ToolFailureResult<TextOutput>(VtFailure(
            code: VtErrorCode.validationFailed,
            message: '"reason" explicando o risco é obrigatório para o revisor.',
          ));
        }

        // risco/policy REAIS da tool, se existir no catálogo
        String riskWire = 'local_write';
        String? policyWire;
        final reg = registry;
        if (toolId.isNotEmpty && reg != null) {
          final tool = reg.byId(toolId);
          if (tool != null) {
            riskWire = tool.risk.wire;
            policyWire = tool.defaultApproval.name;
          } else {
            return ToolFailureResult<TextOutput>(VtFailure(
              code: VtErrorCode.notImplemented,
              message: 'Tool "$toolId" não está registrada — aprove uma ação '
                  'real ou registre a tool primeiro.',
            ));
          }
        }

        final rec = store.createApprovalRequest(
          conversationId: scopeOf(ctx, input),
          id: AgentStateStore.newId('appr'),
          toolId: toolId,
          action: action,
          risk: riskWire,
          reason: reason,
          preview: _mapOrNull(input.values, 'preview') ?? const {},
        );
        return ok({
          'status': 'pending',
          'approval': rec,
          if (policyWire != null) 'tool_policy': policyWire,
          'next_step': 'Apresente o preview ao usuário; registre a decisão '
              'com approval_id + decision + decided_by.',
        });
      });
}

// ---------------------------------------------------------------- todo list
class TodoListTool extends _AgentTool {
  TodoListTool(super.store);

  @override
  String get id => 'todo.list';
  @override
  String get title => 'Listar tarefas';
  @override
  String get description =>
      'Lista as TAREFAS REAIS do estado do agente (SQLite): id, título, '
      'status (pending|running|done|failed), vínculo com plano/passo, '
      'timestamps e últimas notas do audit trail. Filtro opcional por '
      'status; escopo por conversa/workspace.';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'status': {
            'type': 'string',
            'enum': ['pending', 'running', 'done', 'failed'],
          },
          'conversation_id': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final scope = scopeOf(ctx, input);
        final statusFilter = input.values['status'] as String?;
        final all = store.tasks(conversationId: scope);
        final shown = statusFilter == null
            ? all
            : all.where((t) => t.status == statusFilter).toList();
        final counts = <String, int>{};
        for (final t in all) {
          counts[t.status] = (counts[t.status] ?? 0) + 1;
        }
        return ok({
          'scope': scope,
          'total': all.length,
          'counts': counts,
          'tasks': [
            for (final t in shown)
              {
                'id': t.id,
                'title': t.title,
                'status': t.status,
                'planId': t.planId,
                'stepIndex': t.stepIndex,
                'startedAt': t.startedAt,
                'endedAt': t.endedAt,
                'lastNote': t.notes.isEmpty
                    ? null
                    : (t.notes.last as Map)['note'],
              },
          ],
        }, usage: {'returned': shown.length});
      });
}
