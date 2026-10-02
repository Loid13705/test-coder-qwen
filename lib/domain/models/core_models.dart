/// Modelos de dados principais da spec (§MODELOS DE DADOS PRINCIPAIS).
library;

import '../state/agent_states.dart';

class Workspace {
  const Workspace({
    required this.id,
    required this.name,
    required this.rootPath,
    this.folderPaths = const [],
    this.trusted = false,
    required this.createdAt,
    this.lastOpenedAt,
  });

  final String id;
  final String name;
  final String rootPath;
  final List<String> folderPaths; // multi-root
  final bool trusted;
  final DateTime createdAt;
  final DateTime? lastOpenedAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'rootPath': rootPath,
        'folderPaths': folderPaths,
        'trusted': trusted,
        'createdAt': createdAt.toIso8601String(),
        'lastOpenedAt': lastOpenedAt?.toIso8601String(),
      };

  factory Workspace.fromJson(Map<String, Object?> j) => Workspace(
        id: j['id'] as String,
        name: j['name'] as String,
        rootPath: j['rootPath'] as String,
        folderPaths: (j['folderPaths'] as List?)?.cast<String>() ?? const [],
        trusted: j['trusted'] as bool? ?? false,
        createdAt: DateTime.parse(j['createdAt'] as String),
        lastOpenedAt: (j['lastOpenedAt'] as String?) != null
            ? DateTime.parse(j['lastOpenedAt'] as String)
            : null,
      );
}

enum ConversationStatus { active, archived, deleted }

class Conversation {
  const Conversation({
    required this.id,
    required this.workspaceId,
    required this.title,
    this.parentId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.tags = const [],
    this.folder,
  });

  final String id;
  final String workspaceId; // '' = conversa global
  final String title;
  final String? parentId; // branches/forks de conversa
  final ConversationStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool pinned;
  final List<String> tags;
  final String? folder;

  Conversation copyWith({
    String? title,
    ConversationStatus? status,
    DateTime? updatedAt,
    bool? pinned,
    List<String>? tags,
    String? folder,
  }) =>
      Conversation(
        id: id,
        workspaceId: workspaceId,
        title: title ?? this.title,
        parentId: parentId,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        pinned: pinned ?? this.pinned,
        tags: tags ?? this.tags,
        folder: folder ?? this.folder,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'workspaceId': workspaceId,
        'title': title,
        'parentId': parentId,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'pinned': pinned,
        'tags': tags,
        'folder': folder,
      };

  factory Conversation.fromJson(Map<String, Object?> j) => Conversation(
        id: j['id'] as String,
        workspaceId: j['workspaceId'] as String? ?? '',
        title: j['title'] as String,
        parentId: j['parentId'] as String?,
        status: ConversationStatus.values
            .byName(j['status'] as String? ?? 'active'),
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        pinned: j['pinned'] as bool? ?? false,
        tags: (j['tags'] as List?)?.cast<String>() ?? const [],
        folder: j['folder'] as String?,
      );
}

enum MessageRole { user, assistant, system, tool }

enum MessageStatus {
  draft,
  streaming,
  completed,
  cancelledPartial, // mensagem cancelada preserva parcial real
  failed,
}

/// Uso de tokens/custo medido realmente do provider (spec §OBSERVABILIDADE).
class TokenUsage {
  const TokenUsage({
    required this.promptTokens,
    required this.completionTokens,
    this.costUsd,
    this.priceKnown = false,
  });

  final int promptTokens;
  final int completionTokens;

  /// Só preenchido quando a cost table do modelo tem preço real conhecido.
  final double? costUsd;
  final bool priceKnown;

  int get totalTokens => promptTokens + completionTokens;

  Map<String, Object?> toJson() => {
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'costUsd': costUsd,
        'priceKnown': priceKnown,
      };

  factory TokenUsage.fromJson(Map<String, Object?> j) => TokenUsage(
        promptTokens: j['promptTokens'] as int? ?? 0,
        completionTokens: j['completionTokens'] as int? ?? 0,
        costUsd: (j['costUsd'] as num?)?.toDouble(),
        priceKnown: j['priceKnown'] as bool? ?? false,
      );
}

/// Bloco tipado de mensagem (spec §CHAT — blocos tipados).
/// Conteúdo é sempre real: texto vindo do provider, diff vindo de tool,
/// tool call vinda do runtime, erro vindo de uma falha tipada.
sealed class MessageBlock {
  const MessageBlock();
  Map<String, Object?> toJson();
  String get kind;
}

class TextBlock extends MessageBlock {
  const TextBlock(this.text);
  final String text;
  @override
  String get kind => 'text';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'text': text};
  static TextBlock fromJson(Map<String, Object?> j) =>
      TextBlock(j['text'] as String? ?? '');
}

class CodeBlock extends MessageBlock {
  const CodeBlock({required this.language, required this.code, this.fileName});
  final String language;
  final String code;
  final String? fileName;
  @override
  String get kind => 'code';
  @override
  Map<String, Object?> toJson() =>
      {'kind': kind, 'language': language, 'code': code, 'fileName': fileName};
  static CodeBlock fromJson(Map<String, Object?> j) => CodeBlock(
      language: j['language'] as String? ?? 'text',
      code: j['code'] as String? ?? '',
      fileName: j['fileName'] as String?);
}

class DiffBlock extends MessageBlock {
  const DiffBlock({
    required this.filePath,
    required this.unifiedDiff,
    required this.additions,
    required this.deletions,
    this.applied = false,
  });
  final String filePath;
  final String unifiedDiff;
  final int additions;
  final int deletions;
  final bool applied;
  @override
  String get kind => 'diff';
  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'filePath': filePath,
        'unifiedDiff': unifiedDiff,
        'additions': additions,
        'deletions': deletions,
        'applied': applied,
      };
  static DiffBlock fromJson(Map<String, Object?> j) => DiffBlock(
        filePath: j['filePath'] as String? ?? '',
        unifiedDiff: j['unifiedDiff'] as String? ?? '',
        additions: j['additions'] as int? ?? 0,
        deletions: j['deletions'] as int? ?? 0,
        applied: j['applied'] as bool? ?? false,
      );
}

class ToolCallBlock extends MessageBlock {
  const ToolCallBlock(
      {required this.toolCallId,
      required this.toolId,
      required this.statusWire});
  final String toolCallId;
  final String toolId;
  final String
      statusWire; // ToolCallStatus.wire — resolvido no application layer
  @override
  String get kind => 'tool_call';
  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'toolCallId': toolCallId,
        'toolId': toolId,
        'status': statusWire
      };
  static ToolCallBlock fromJson(Map<String, Object?> j) => ToolCallBlock(
        toolCallId: j['toolCallId'] as String? ?? '',
        toolId: j['toolId'] as String? ?? '',
        statusWire: j['status'] as String? ?? 'pending',
      );
}

class ApprovalBlock extends MessageBlock {
  const ApprovalBlock(
      {required this.approvalRequestId,
      required this.title,
      required this.riskWire});
  final String approvalRequestId;
  final String title;
  final String riskWire;
  @override
  String get kind => 'approval';
  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'approvalRequestId': approvalRequestId,
        'title': title,
        'risk': riskWire,
      };
  static ApprovalBlock fromJson(Map<String, Object?> j) => ApprovalBlock(
        approvalRequestId: j['approvalRequestId'] as String? ?? '',
        title: j['title'] as String? ?? '',
        riskWire: j['risk'] as String? ?? 'read_only',
      );
}

class ArtifactBlock extends MessageBlock {
  const ArtifactBlock(
      {required this.kindOf, required this.pathOrUri, required this.exists});
  final String
      kindOf; // report|screenshot|trace|coverage|build_output|scene_json|bug_report
  final String pathOrUri;

  /// Verificação real de existência no momento da criação do bloco.
  final bool exists;
  @override
  String get kind => 'artifact';
  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'artifactKind': kindOf,
        'pathOrUri': pathOrUri,
        'exists': exists
      };
  static ArtifactBlock fromJson(Map<String, Object?> j) => ArtifactBlock(
        kindOf: j['artifactKind'] as String? ?? '',
        pathOrUri: j['pathOrUri'] as String? ?? '',
        exists: j['exists'] as bool? ?? false,
      );
}

class CitationBlock extends MessageBlock {
  const CitationBlock({
    required this.sourceType,
    required this.sourceRef,
    required this.label,
    this.lineStart,
    this.lineEnd,
  });
  final String sourceType; // file|url|tool_call|commit|test|log|memory
  final String sourceRef;
  final String label;
  final int? lineStart;
  final int? lineEnd;
  @override
  String get kind => 'citation';
  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'sourceType': sourceType,
        'sourceRef': sourceRef,
        'label': label,
        'lineStart': lineStart,
        'lineEnd': lineEnd,
      };
  static CitationBlock fromJson(Map<String, Object?> j) => CitationBlock(
        sourceType: j['sourceType'] as String? ?? '',
        sourceRef: j['sourceRef'] as String? ?? '',
        label: j['label'] as String? ?? '',
        lineStart: (j['lineStart'] as num?)?.toInt(),
        lineEnd: (j['lineEnd'] as num?)?.toInt(),
      );
}

class ImageBlock extends MessageBlock {
  const ImageBlock(
      {required this.pathOrUrl,
      required this.localExists,
      this.widthPx,
      this.heightPx});
  final String pathOrUrl;
  final bool localExists;
  final int? widthPx;
  final int? heightPx;
  @override
  String get kind => 'image';
  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'pathOrUrl': pathOrUrl,
        'localExists': localExists,
        'widthPx': widthPx,
        'heightPx': heightPx,
      };
  static ImageBlock fromJson(Map<String, Object?> j) => ImageBlock(
        pathOrUrl: j['pathOrUrl'] as String? ?? '',
        localExists: j['localExists'] as bool? ?? false,
        widthPx: (j['widthPx'] as num?)?.toInt(),
        heightPx: (j['heightPx'] as num?)?.toInt(),
      );
}

class FileBlock extends MessageBlock {
  const FileBlock(
      {required this.path, required this.sizeBytes, required this.exists});
  final String path;
  final int sizeBytes;
  final bool exists;
  @override
  String get kind => 'file';
  @override
  Map<String, Object?> toJson() =>
      {'kind': kind, 'path': path, 'sizeBytes': sizeBytes, 'exists': exists};
  static FileBlock fromJson(Map<String, Object?> j) => FileBlock(
        path: j['path'] as String? ?? '',
        sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
        exists: j['exists'] as bool? ?? false,
      );
}

class TerminalBlock extends MessageBlock {
  const TerminalBlock(
      {required this.sessionId,
      required this.command,
      required this.exitCode,
      required this.outputTail});
  final String sessionId;
  final String command;
  final int? exitCode;
  final String outputTail;
  @override
  String get kind => 'terminal';
  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'sessionId': sessionId,
        'command': command,
        'exitCode': exitCode,
        'outputTail': outputTail,
      };
  static TerminalBlock fromJson(Map<String, Object?> j) => TerminalBlock(
        sessionId: j['sessionId'] as String? ?? '',
        command: j['command'] as String? ?? '',
        exitCode: (j['exitCode'] as num?)?.toInt(),
        outputTail: j['outputTail'] as String? ?? '',
      );
}

class ErrorBlock extends MessageBlock {
  const ErrorBlock(this.failureJson);

  /// VtFailure.toJson() — código tipado + ação concreta, nunca texto inventado.
  final Map<String, Object?> failureJson;
  @override
  String get kind => 'error';
  @override
  Map<String, Object?> toJson() => {'kind': kind, 'failure': failureJson};
  static ErrorBlock fromJson(Map<String, Object?> j) =>
      ErrorBlock((j['failure'] as Map?)?.cast<String, Object?>() ?? const {});
}

class PlanBlock extends MessageBlock {
  const PlanBlock(
      {required this.planId, required this.objective, required this.steps});
  final String planId;
  final String objective;

  /// [{index, title, status}] — status real por passo (PlanStepStatus.wire).
  final List<Map<String, Object?>> steps;
  @override
  String get kind => 'plan';
  @override
  Map<String, Object?> toJson() =>
      {'kind': kind, 'planId': planId, 'objective': objective, 'steps': steps};
  static PlanBlock fromJson(Map<String, Object?> j) => PlanBlock(
        planId: j['planId'] as String? ?? '',
        objective: j['objective'] as String? ?? '',
        steps: [
          for (final s in (j['steps'] as List? ?? const []))
            (s as Map).cast<String, Object?>()
        ],
      );
}

class TaskBlock extends MessageBlock {
  const TaskBlock(
      {required this.taskId, required this.title, required this.statusWire});
  final String taskId;
  final String title;
  final String statusWire;
  @override
  String get kind => 'task';
  @override
  Map<String, Object?> toJson() =>
      {'kind': kind, 'taskId': taskId, 'title': title, 'status': statusWire};
  static TaskBlock fromJson(Map<String, Object?> j) => TaskBlock(
        taskId: j['taskId'] as String? ?? '',
        title: j['title'] as String? ?? '',
        statusWire: j['status'] as String? ?? 'pending',
      );
}

class MemoryBlock extends MessageBlock {
  const MemoryBlock(
      {required this.memoryId, required this.type, required this.sourcesCount});
  final String memoryId;
  final String type; // conversation|project|user|episodic|semantic
  final int sourcesCount;
  @override
  String get kind => 'memory';
  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'memoryId': memoryId,
        'type': type,
        'sourcesCount': sourcesCount
      };
  static MemoryBlock fromJson(Map<String, Object?> j) => MemoryBlock(
        memoryId: j['memoryId'] as String? ?? '',
        type: j['type'] as String? ?? '',
        sourcesCount: (j['sourcesCount'] as num?)?.toInt() ?? 0,
      );
}

class CostBlock extends MessageBlock {
  const CostBlock(
      {required this.usage, required this.modelId, required this.currency});
  final TokenUsage usage;
  final String modelId;
  final String currency;
  @override
  String get kind => 'cost';
  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'usage': usage.toJson(),
        'modelId': modelId,
        'currency': currency
      };
  static CostBlock fromJson(Map<String, Object?> j) => CostBlock(
        usage: TokenUsage.fromJson(
            (j['usage'] as Map?)?.cast<String, Object?>() ?? const {}),
        modelId: j['modelId'] as String? ?? '',
        currency: j['currency'] as String? ?? 'USD',
      );
}

MessageBlock blockFromJson(Map<String, Object?> j) {
  switch (j['kind'] as String? ?? 'text') {
    case 'code':
      return CodeBlock.fromJson(j);
    case 'diff':
      return DiffBlock.fromJson(j);
    case 'tool_call':
      return ToolCallBlock.fromJson(j);
    case 'approval':
      return ApprovalBlock.fromJson(j);
    case 'artifact':
      return ArtifactBlock.fromJson(j);
    case 'citation':
      return CitationBlock.fromJson(j);
    case 'image':
      return ImageBlock.fromJson(j);
    case 'file':
      return FileBlock.fromJson(j);
    case 'terminal':
      return TerminalBlock.fromJson(j);
    case 'error':
      return ErrorBlock.fromJson(j);
    case 'plan':
      return PlanBlock.fromJson(j);
    case 'task':
      return TaskBlock.fromJson(j);
    case 'memory':
      return MemoryBlock.fromJson(j);
    case 'cost':
      return CostBlock.fromJson(j);
    default:
      return TextBlock.fromJson(j);
  }
}

class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.createdAt,
    this.modelId,
    this.mode,
    this.agentPosture,
    this.approvalPosture,
    required this.blocks,
    required this.status,
    this.usage,
    this.edited = false,
    this.regeneratedFromId,
  });

  final String id;
  final String conversationId;
  final MessageRole role;
  final DateTime createdAt;
  final String? modelId;
  final String? mode;
  final String? agentPosture;
  final String? approvalPosture;
  final List<MessageBlock> blocks;
  final MessageStatus status;
  final TokenUsage? usage;
  final bool edited;
  final String? regeneratedFromId;

  Map<String, Object?> toJson() => {
        'id': id,
        'conversationId': conversationId,
        'role': role.name,
        'createdAt': createdAt.toIso8601String(),
        'modelId': modelId,
        'mode': mode,
        'agentPosture': agentPosture,
        'approvalPosture': approvalPosture,
        'blocks': [for (final b in blocks) b.toJson()],
        'status': status.name,
        'usage': usage?.toJson(),
        'edited': edited,
        'regeneratedFromId': regeneratedFromId,
      };

  factory Message.fromJson(Map<String, Object?> j) => Message(
        id: j['id'] as String,
        conversationId: j['conversationId'] as String,
        role: MessageRole.values.byName(j['role'] as String),
        createdAt: DateTime.parse(j['createdAt'] as String),
        modelId: j['modelId'] as String?,
        mode: j['mode'] as String?,
        agentPosture: j['agentPosture'] as String?,
        approvalPosture: j['approvalPosture'] as String?,
        blocks: [
          for (final b in (j['blocks'] as List? ?? const []))
            blockFromJson((b as Map).cast<String, Object?>())
        ],
        status:
            MessageStatus.values.byName(j['status'] as String? ?? 'completed'),
        usage: j['usage'] != null
            ? TokenUsage.fromJson((j['usage'] as Map).cast<String, Object?>())
            : null,
        edited: j['edited'] as bool? ?? false,
        regeneratedFromId: j['regeneratedFromId'] as String?,
      );
}

/// Plano estruturado (spec §Plano estruturado): objetivo, hipóteses, arquivos
/// afetados, tools necessárias, riscos, critérios de aceitação, passos,
/// dependências, verificação e rollback plan.
class AgentPlanStep {
  const AgentPlanStep({
    required this.index,
    required this.title,
    required this.status,
    this.dependsOn = const [],
    this.toolIds = const [],
    this.acceptanceCriteria = const [],
  });

  final int index;
  final String title;
  final PlanStepStatus status;
  final List<int> dependsOn;
  final List<String> toolIds;
  final List<String> acceptanceCriteria;

  AgentPlanStep copyWith({String? title, PlanStepStatus? status}) =>
      AgentPlanStep(
        index: index,
        title: title ?? this.title,
        status: status ?? this.status,
        dependsOn: dependsOn,
        toolIds: toolIds,
        acceptanceCriteria: acceptanceCriteria,
      );

  Map<String, Object?> toJson() => {
        'index': index,
        'title': title,
        'status': status.wire,
        'dependsOn': dependsOn,
        'toolIds': toolIds,
        'acceptanceCriteria': acceptanceCriteria,
      };

  factory AgentPlanStep.fromJson(Map<String, Object?> j) => AgentPlanStep(
        index: (j['index'] as num).toInt(),
        title: j['title'] as String? ?? '',
        status: PlanStepStatus.values.firstWhere((s) => s.wire == j['status'],
            orElse: () => PlanStepStatus.pending),
        dependsOn: [
          for (final d in (j['dependsOn'] as List? ?? const []))
            (d as num).toInt()
        ],
        toolIds: (j['toolIds'] as List?)?.cast<String>() ?? const [],
        acceptanceCriteria:
            (j['acceptanceCriteria'] as List?)?.cast<String>() ?? const [],
      );
}

class AgentPlan {
  const AgentPlan({
    required this.id,
    required this.agentRunId,
    required this.objective,
    this.hypotheses = const [],
    this.affectedFiles = const [],
    this.requiredTools = const [],
    this.risks = const [],
    this.acceptanceCriteria = const [],
    required this.steps,
    this.verification,
    this.rollbackPlan,
    required this.createdAt,
  });

  final String id;
  final String agentRunId;
  final String objective;
  final List<String> hypotheses;
  final List<String> affectedFiles;
  final List<String> requiredTools;
  final List<String> risks;
  final List<String> acceptanceCriteria;
  final List<AgentPlanStep> steps;
  final String? verification;
  final String? rollbackPlan;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'agentRunId': agentRunId,
        'objective': objective,
        'hypotheses': hypotheses,
        'affectedFiles': affectedFiles,
        'requiredTools': requiredTools,
        'risks': risks,
        'acceptanceCriteria': acceptanceCriteria,
        'steps': [for (final s in steps) s.toJson()],
        'verification': verification,
        'rollbackPlan': rollbackPlan,
        'createdAt': createdAt.toIso8601String(),
      };

  factory AgentPlan.fromJson(Map<String, Object?> j) => AgentPlan(
        id: j['id'] as String,
        agentRunId: j['agentRunId'] as String? ?? '',
        objective: j['objective'] as String? ?? '',
        hypotheses: (j['hypotheses'] as List?)?.cast<String>() ?? const [],
        affectedFiles:
            (j['affectedFiles'] as List?)?.cast<String>() ?? const [],
        requiredTools:
            (j['requiredTools'] as List?)?.cast<String>() ?? const [],
        risks: (j['risks'] as List?)?.cast<String>() ?? const [],
        acceptanceCriteria:
            (j['acceptanceCriteria'] as List?)?.cast<String>() ?? const [],
        steps: [
          for (final s in (j['steps'] as List? ?? const []))
            AgentPlanStep.fromJson((s as Map).cast<String, Object?>())
        ],
        verification: j['verification'] as String?,
        rollbackPlan: j['rollbackPlan'] as String?,
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

/// Run do agente com métricas reais de custo/tokens/latência.
class AgentRun {
  const AgentRun({
    required this.id,
    required this.conversationId,
    required this.workspaceId,
    required this.agentId,
    required this.modelId,
    required this.mode,
    required this.posture,
    required this.approvalPosture,
    required this.state,
    this.plan,
    this.cost,
    this.startedAt,
    this.endedAt,
    this.stopReason,
  });

  final String id;
  final String conversationId;
  final String workspaceId;
  final String agentId; // techVT-Agent-01 no v1
  final String modelId;
  final String mode;
  final String posture;
  final String approvalPosture;
  final AgentRunState state;
  final AgentPlan? plan;
  final TokenUsage? cost;
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// Motivo real de parada: guardrail excedido, erro tipado, cancelamento.
  final String? stopReason;

  Map<String, Object?> toJson() => {
        'id': id,
        'conversationId': conversationId,
        'workspaceId': workspaceId,
        'agentId': agentId,
        'modelId': modelId,
        'mode': mode,
        'posture': posture,
        'approvalPosture': approvalPosture,
        'state': state.wire,
        'plan': plan?.toJson(),
        'cost': cost?.toJson(),
        'startedAt': startedAt?.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'stopReason': stopReason,
      };

  factory AgentRun.fromJson(Map<String, Object?> j) => AgentRun(
        id: j['id'] as String,
        conversationId: j['conversationId'] as String? ?? '',
        workspaceId: j['workspaceId'] as String? ?? '',
        agentId: j['agentId'] as String? ?? '',
        modelId: j['modelId'] as String? ?? '',
        mode: j['mode'] as String? ?? '',
        posture: j['posture'] as String? ?? '',
        approvalPosture: j['approvalPosture'] as String? ?? '',
        state: AgentRunState.values.firstWhere((s) => s.wire == j['state'],
            orElse: () => AgentRunState.idle),
        plan: j['plan'] != null
            ? AgentPlan.fromJson((j['plan'] as Map).cast<String, Object?>())
            : null,
        cost: j['cost'] != null
            ? TokenUsage.fromJson((j['cost'] as Map).cast<String, Object?>())
            : null,
        startedAt: (j['startedAt'] as String?) != null
            ? DateTime.parse(j['startedAt'] as String)
            : null,
        endedAt: (j['endedAt'] as String?) != null
            ? DateTime.parse(j['endedAt'] as String)
            : null,
        stopReason: j['stopReason'] as String?,
      );
}
