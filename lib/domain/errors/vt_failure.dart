/// Erros tipados reais do techVT.
///
/// Cada falha de tool/provider/sistema retorna um [VtFailure] com um código da
/// especificação e, sempre que possível, uma **ação concreta** para o usuário
/// (configurar provider, adicionar API key, instalar sidecar, autorizar pasta,
/// permitir domínio, abrir logs, tentar novamente, trocar modelo).
library;

/// Códigos de erro tipados definidos pela especificação techVT.
enum VtErrorCode {
  providerNotConfigured('provider_not_configured'),
  apiKeyMissing('api_key_missing'),
  binaryMissing('binary_missing'),
  sidecarNotRunning('sidecar_not_running'),
  permissionDenied('permission_denied'),
  pathOutOfSandbox('path_out_of_sandbox'),
  domainNotAllowed('domain_not_allowed'),
  rateLimited('rate_limited'),
  timeout('timeout'),
  validationFailed('validation_failed'),
  userRejected('user_rejected'),
  approvalRequired('approval_required'),
  checkpointFailed('checkpoint_failed'),
  rollbackUnavailable('rollback_unavailable'),
  modelDoesNotSupportTools('model_does_not_support_tools'),
  networkUnavailable('network_unavailable'),
  deviceNotFound('device_not_found'),
  buildFailed('build_failed'),
  testFailed('test_failed'),
  secretDetected('secret_detected'),
  promptInjectionSuspected('prompt_injection_suspected'),
  cancelled('cancelled'),
  notImplemented('not_implemented'),
  internalError('internal_error');

  const VtErrorCode(this.wire);
  final String wire;

  static VtErrorCode fromWire(String w) => VtErrorCode.values
      .firstWhere((e) => e.wire == w, orElse: () => VtErrorCode.internalError);
}

/// Ação concreta sugerida ao usuário quando algo está bloqueado.
class RecoveryAction {
  const RecoveryAction({
    required this.kind,
    required this.label,
    this.target,
  });

  /// ex.: `configure_provider`, `add_api_key`, `install_sidecar`,
  /// `authorize_folder`, `allow_domain`, `open_logs`, `retry`,
  /// `switch_model`, `open_settings`.
  final String kind;
  final String label;

  /// Destaque navegável (id de settings, caminho, URL de docs local).
  final String? target;
}

/// Resultado de falha tipado — nunca contém conteúdo simulado.
class VtFailure implements Exception {
  const VtFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.details,
    this.setupUri,
    this.recoveryActions = const [],
  });

  final VtErrorCode code;
  final String message;
  final bool retryable;
  final Map<String, Object?>? details;

  /// URI de configuração real (ex.: `techvt://settings/providers/openai`).
  final String? setupUri;
  final List<RecoveryAction> recoveryActions;

  Map<String, Object?> toJson() => {
        'code': code.wire,
        'message': message,
        'retryable': retryable,
        if (details != null) 'details': details,
        if (setupUri != null) 'setupUri': setupUri,
        'recoveryActions': [
          for (final a in recoveryActions)
            {
              'kind': a.kind,
              'label': a.label,
              if (a.target != null) 'target': a.target
            }
        ],
      };

  factory VtFailure.fromJson(Map<String, Object?> j) => VtFailure(
        code: VtErrorCode.fromWire(j['code'] as String? ?? 'internal_error'),
        message: j['message'] as String? ?? 'unknown',
        retryable: j['retryable'] as bool? ?? false,
        details: (j['details'] as Map?)?.cast<String, Object?>(),
        setupUri: j['setupUri'] as String?,
      );

  // --- Construtores padrão com ação concreta (motivo técnico + próximo passo) ---

  factory VtFailure.providerNotConfigured(String providerId) => VtFailure(
        code: VtErrorCode.providerNotConfigured,
        message: 'O provedor "$providerId" não está configurado.',
        setupUri: 'techvt://settings/providers/$providerId',
        recoveryActions: const [
          RecoveryAction(
              kind: 'configure_provider',
              label: 'Configurar provider em Settings → AI Providers',
              target: 'aiProviders'),
        ],
      );

  factory VtFailure.apiKeyMissing(String providerId) => VtFailure(
        code: VtErrorCode.apiKeyMissing,
        message: 'Falta a API key do provedor "$providerId". '
            'Ela é armazenada no secure storage do sistema operacional.',
        setupUri: 'techvt://settings/providers/$providerId/key',
        recoveryActions: const [
          RecoveryAction(
              kind: 'add_api_key',
              label: 'Adicionar API key',
              target: 'aiProviders'),
        ],
      );

  factory VtFailure.binaryMissing(String binary, {String? hint}) => VtFailure(
        code: VtErrorCode.binaryMissing,
        message: 'Binário "$binary" não encontrado no PATH.$hint',
        recoveryActions: [
          const RecoveryAction(
              kind: 'open_settings',
              label: 'Definir caminho do binário em Settings',
              target: 'tools'),
          RecoveryAction(
              kind: 'retry', label: 'Tentar novamente após instalar "$binary"'),
        ],
      );

  factory VtFailure.sidecarNotRunning(String sidecar) => VtFailure(
        code: VtErrorCode.sidecarNotRunning,
        message:
            'O sidecar "$sidecar" não está instalado ou não respondeu ao health check.',
        recoveryActions: [
          const RecoveryAction(
              kind: 'install_sidecar',
              label: 'Instalar/verificar sidecar em Settings → Diagnostics',
              target: 'diagnostics'),
        ],
      );

  factory VtFailure.permissionDenied(String path) => VtFailure(
        code: VtErrorCode.permissionDenied,
        message: 'Permissão negada para acessar "$path".',
        recoveryActions: const [
          RecoveryAction(
              kind: 'authorize_folder',
              label: 'Autorizar pasta via grant de permissão'),
        ],
      );

  factory VtFailure.pathOutOfSandbox(String path) => VtFailure(
        code: VtErrorCode.pathOutOfSandbox,
        message: 'Caminho fora do sandbox do workspace: "$path". '
            'External paths exigem grant explícito.',
        recoveryActions: const [
          RecoveryAction(
              kind: 'authorize_folder',
              label: 'Conceder acesso com permission.grant (auditado)'),
        ],
      );

  factory VtFailure.domainNotAllowed(String domain) => VtFailure(
        code: VtErrorCode.domainNotAllowed,
        message: 'Domínio "$domain" não está na allowlist de rede.',
        recoveryActions: [
          RecoveryAction(
              kind: 'allow_domain',
              label:
                  'Permitir domínio em Settings → Security → Network allowlist',
              target: 'security'),
        ],
      );

  factory VtFailure.rateLimited(String source) => VtFailure(
        code: VtErrorCode.rateLimited,
        message:
            'Rate limit atingido em "$source". Aguarde o backoff indicado.',
        retryable: true,
        recoveryActions: const [
          RecoveryAction(kind: 'retry', label: 'Tentar novamente mais tarde'),
          RecoveryAction(
              kind: 'switch_model', label: 'Trocar de modelo/fallback chain'),
        ],
      );

  factory VtFailure.timeout(Duration after) => VtFailure(
        code: VtErrorCode.timeout,
        message: 'Operação excedeu o timeout de ${after.inSeconds}s.',
        retryable: true,
        recoveryActions: const [
          RecoveryAction(kind: 'retry', label: 'Tentar novamente'),
          RecoveryAction(
              kind: 'open_settings',
              label: 'Aumentar timeout em Settings → Tools'),
        ],
      );

  factory VtFailure.networkUnavailable([String? detail]) => VtFailure(
        code: VtErrorCode.networkUnavailable,
        message: 'Rede indisponível.${detail ?? ''}',
        retryable: true,
        recoveryActions: const [
          RecoveryAction(
              kind: 'retry', label: 'Verificar conexão e tentar novamente'),
          RecoveryAction(
              kind: 'open_settings',
              label: 'Revisar proxy em Settings → AI Providers',
              target: 'aiProviders'),
        ],
      );

  factory VtFailure.modelDoesNotSupportTools(String modelId) => VtFailure(
        code: VtErrorCode.modelDoesNotSupportTools,
        message:
            'O modelo "$modelId" não suporta tool calling; Agent mode está bloqueado.',
        recoveryActions: const [
          RecoveryAction(
              kind: 'switch_model', label: 'Trocar para um modelo com tools'),
        ],
      );

  factory VtFailure.cancelled() => VtFailure(
        code: VtErrorCode.cancelled,
        message: 'Operação cancelada pelo usuário.',
      );

  factory VtFailure.notImplemented(String feature) => VtFailure(
        code: VtErrorCode.notImplemented,
        message: '"$feature" ainda não possui implementação real. '
            'Este recurso aparece como disabled até existir backend real.',
      );

  @override
  String toString() => 'VtFailure(${code.wire}: $message)';
}
