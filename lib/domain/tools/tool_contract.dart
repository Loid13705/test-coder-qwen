/// Contrato de tools da spec (§TOOLS / TOOL REGISTRY).
library;

import 'dart:convert';

import '../errors/vt_failure.dart';

enum RiskLevel {
  readOnly('read_only'),
  networkRead('network_read'),
  localWrite('local_write'),
  execute('execute'),
  externalWrite('external_write'),
  destructive('destructive'),
  secret('secret'),
  privileged('privileged');

  const RiskLevel(this.wire);
  final String wire;
}

enum ApprovalPolicyMode {
  auto, // executa sem aprovação quando permitido pelo modo/posture
  reviewEach, // sempre cria ApprovalRequest
  explicitApproval, // push/migrate/secret/delete: aprovação explícita sempre
  typedConfirmation, // confirmação tipada (delete permanente)
}

enum ToolCategory {
  agent,
  checkpoint,
  memory,
  security,
  permission,
  fileSystem,
  editor,
  workspace,
  terminal,
  process,
  git,
  web,
  browser,
  debug,
  bug,
  test,
  lint,
  lsp,
  codeIndex,
  pub,
  flutter,
  ci,
  release,
  database,
  api,
  issueTracker,
  gameDev,
  logs,
  metrics,
  health,
  settings,
  diagnostics,
}

/// Resultado de health check real (binário presente? sidecar vivo? key set?).
sealed class ToolHealth {
  const ToolHealth();
  Map<String, Object?> toJson();
}

class HealthOk extends ToolHealth {
  const HealthOk([this.detail]);
  final String? detail;
  @override
  Map<String, Object?> toJson() =>
      {'status': 'ok', if (detail != null) 'detail': detail};
}

class HealthMissingBinary extends ToolHealth {
  const HealthMissingBinary(this.binary);
  final String binary;
  @override
  Map<String, Object?> toJson() =>
      {'status': 'missing_binary', 'binary': binary};
}

class HealthMissingSidecar extends ToolHealth {
  const HealthMissingSidecar(this.sidecar);
  final String sidecar;
  @override
  Map<String, Object?> toJson() =>
      {'status': 'missing_sidecar', 'sidecar': sidecar};
}

class HealthUnconfigured extends ToolHealth {
  const HealthUnconfigured(this.what);
  final String what;
  @override
  Map<String, Object?> toJson() => {'status': 'unconfigured', 'what': what};
}

class HealthDegraded extends ToolHealth {
  const HealthDegraded(this.reason);
  final String reason;
  @override
  Map<String, Object?> toJson() => {'status': 'degraded', 'reason': reason};
}

abstract class ToolInput {
  const ToolInput();
  Map<String, Object?> toJson();
}

abstract class ToolOutput {
  const ToolOutput();
  Map<String, Object?> toJson();
}

/// Saída simples com texto estruturado — usado por tools de leitura/execução.
class TextOutput extends ToolOutput {
  const TextOutput(this.text, {this.metadata = const {}});
  final String text;
  final Map<String, Object?> metadata;
  @override
  Map<String, Object?> toJson() => {'text': text, 'metadata': metadata};
}

class Citation {
  const Citation({
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

  Map<String, Object?> toJson() => {
        'sourceType': sourceType,
        'sourceRef': sourceRef,
        'label': label,
        'lineStart': lineStart,
        'lineEnd': lineEnd,
      };
}

class ArtifactRef {
  const ArtifactRef({required this.kindOf, required this.pathOrUri});
  final String kindOf;
  final String pathOrUri;
  Map<String, Object?> toJson() => {'kind': kindOf, 'pathOrUri': pathOrUri};
}

/// ToolResult sealed (spec §Contrato Dart sugerido).
sealed class ToolResult<O extends ToolOutput> {
  const ToolResult();
}

class ToolSuccess<O extends ToolOutput> extends ToolResult<O> {
  const ToolSuccess({
    required this.data,
    this.citations = const [],
    this.artifacts = const [],
    this.usage,
    this.auditId,
  });
  final O data;
  final List<Citation> citations;
  final List<ArtifactRef> artifacts;
  final Map<String, Object?>? usage;
  final String? auditId;
}

class ToolFailureResult<O extends ToolOutput> extends ToolResult<O> {
  const ToolFailureResult(this.failure);
  final VtFailure failure;
}

/// Contexto injetado pela application layer no momento da execução.
class ToolContext {
  const ToolContext({
    required this.workspaceRoots,
    required this.sandbox,
    required this.settings,
    this.agentRunId,
    this.conversationId,
  });

  /// Raízes do workspace multi-root reais.
  final List<String> workspaceRoots;

  /// Callback de sandbox — validação de path/trust feita na infra real.
  final SandboxGateway sandbox;
  final SettingsGateway settings;
  final String? agentRunId;
  final String? conversationId;
}

/// Portais para serviços cross-layer (implementados em infrastructure).
abstract class SandboxGateway {
  /// Retorna o caminho absoluto normalizado se dentro do sandbox/grants,
  /// senão lança [VtFailure.pathOutOfSandbox] ou [VtFailure.permissionDenied].
  Future<String> resolveReadable(String rawPath, ToolContext ctx);
  Future<String> resolveWritable(String rawPath, ToolContext ctx);
  bool isAllowedDomain(String domain, ToolContext ctx);
}

abstract class SettingsGateway {
  Object? get(String key, {String? workspaceId});
}

/// Contrato base de tool (spec): id estável, schemas, risco, política default,
/// timeout, retry, idempotência, requisitos de capacidade, health check e audit.
abstract class VtTool<I extends ToolInput, O extends ToolOutput> {
  String get id; // ex.: fs.read_text
  String get title;
  String get description;
  ToolCategory get category;
  RiskLevel get risk;
  ApprovalPolicyMode get defaultApproval;
  Map<String, Object?> get inputSchema; // JSON Schema
  Map<String, Object?> get outputSchema; // JSON Schema
  bool get isIdempotent;
  Duration get timeout;
  RetryPolicy get retryPolicy;

  /// Capacidades exigidas (ex.: ['git','sqlite','network']). Se ausentes,
  /// execute() retorna erro tipado real — nunca simulação.
  List<String> get capabilities;

  Future<ToolHealth> health(ToolContext ctx);
  Future<I> parseInput(Map<String, Object?> raw);
  Future<ToolResult<O>> execute(ToolContext ctx, I input);

  /// Validação estrutural do input contra o schema declarado (real).
  void validateInput(Map<String, Object?> raw) {
    final required =
        (inputSchema['required'] as List?)?.cast<String>() ?? const [];
    for (final r in required) {
      if (!raw.containsKey(r) || raw[r] == null) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Campo obrigatório "$r" ausente no input de $id.',
        );
      }
    }
  }

  Map<String, Object?> catalogEntry() => {
        'id': id,
        'title': title,
        'description': description,
        'category': category.name,
        'risk': risk.wire,
        'defaultApproval': defaultApproval.name,
        'inputSchema': inputSchema,
        'outputSchema': outputSchema,
        'isIdempotent': isIdempotent,
        'timeoutMs': timeout.inMilliseconds,
        'retryPolicy': retryPolicy.toJson(),
        'capabilities': capabilities,
      };

  static String encodeCatalog(List<Map<String, Object?>> entries) =>
      jsonEncode(entries);
}

class RetryPolicy {
  const RetryPolicy(
      {this.maxAttempts = 1, this.backoff = const Duration(seconds: 1)});
  final int maxAttempts;
  final Duration backoff;
  Map<String, Object?> toJson() =>
      {'maxAttempts': maxAttempts, 'backoffMs': backoff.inMilliseconds};
}

/// Input genérico para tools que só recebem um map validado pelo schema.
class MapToolInput extends ToolInput {
  const MapToolInput(this.values);
  final Map<String, Object?> values;
  @override
  Map<String, Object?> toJson() => values;

  String str(String k) => values[k] as String? ?? '';
  int? intOrNull(String k) => (values[k] as num?)?.toInt();
  bool boolOf(String k, [bool def = false]) => values[k] as bool? ?? def;
  List<String> list(String k) =>
      (values[k] as List?)?.cast<String>() ?? const [];
}
