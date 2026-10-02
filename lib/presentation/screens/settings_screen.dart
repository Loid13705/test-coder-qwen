/// Tela de Ajustes — edição REAL do settings.json (providers, modelo default,
/// postura do agente, tema) e das chaves de API via FileSecretStore.
///
/// Regra de segurança: o segredo NUNCA é exibido na tela — só se grava,
/// se apaga e se mostra "definida/não definida" (com tamanho, nunca conteúdo).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/app_bootstrap.dart';
import '../../application/approval.dart';
import '../../application/chat_service.dart';
import '../../domain/errors/vt_failure.dart';
import '../../infrastructure/provider/provider_contract.dart';
import '../state/app_state.dart';
import '../theme/vt_theme.dart';

/// Estado medido por um health check REAL (HTTP ao endpoint do provider).
class _ProviderHealth {
  const _ProviderHealth._(
      {this.status, this.error, required this.checkedAtMs, this.latencyMs});

  factory _ProviderHealth.pending() =>
      const _ProviderHealth._(checkedAtMs: 0);

  final ProviderStatus? status;
  final String? error;

  /// Epoch ms em que a checagem terminou. Sentinelas: 0 = nunca executada,
  /// -1 = checagem em andamento (in-flight).
  final int checkedAtMs;

  /// Latência medida da requisição de health, quando houve tentativa real.
  final int? latencyMs;

  bool get isChecking => checkedAtMs == -1;
  bool get hasResult => checkedAtMs > 0 && (status != null || error != null);
}

/// Health check sob demanda dos providers configurados — usa o MESMO
/// `healthCheck()` real do contrato (GET models + credencial), nunca um
/// estado simulado. Chaves ficam em [providerHealthMapProvider]; a lista
/// ordenada em [providerHealthListProvider] é derivada dela para a UI.
final providerHealthMapProvider =
    StateNotifierProvider<ProviderHealthNotifier, Map<String, _ProviderHealth>>(
        (ref) => ProviderHealthNotifier(ref));

class ProviderHealthNotifier extends StateNotifier<Map<String, _ProviderHealth>> {
  ProviderHealthNotifier(this._ref) : super(const {}) {
    _syncKeys();
  }

  final Ref _ref;

  void _syncKeys() {
    final ids = _ref.read(chatServiceProvider).providers.all.map((p) => p.id);
    state = {for (final id in ids) id: state[id] ?? _ProviderHealth.pending()};
  }

  /// Dispara uma checagem REAL e independente por provider.
  void checkAll() {
    _syncKeys();
    for (final p in _ref.read(chatServiceProvider).providers.all) {
      _checkOne(p.id);
    }
  }

  Future<void> checkOne(String id) async => _checkOne(id);

  Future<void> _checkOne(String id) async {
    final now = DateTime.now();
    // marca como "em verificação" (checkedAtMs < 0 é sentinela de in-flight)
    state = {
      ...state,
      id: const _ProviderHealth._(checkedAtMs: -1),
    };
    try {
      final p = _ref.read(chatServiceProvider).providers.byId(id);
      if (p == null) {
        state = {
          ...state,
          id: _ProviderHealth._(
              error: 'provider não registrado nesta sessão',
              checkedAtMs: now.millisecondsSinceEpoch),
        };
        return;
      }
      final st = await p.healthCheck();
      state = {
        ...state,
        id: _ProviderHealth._(
          status: st,
          checkedAtMs: DateTime.now().millisecondsSinceEpoch,
          latencyMs: DateTime.now().difference(now).inMilliseconds,
        ),
      };
    } on VtFailure catch (f) {
      state = {
        ...state,
        id: _ProviderHealth._(
            error: '${f.code.wire}: ${f.message}',
            checkedAtMs: DateTime.now().millisecondsSinceEpoch,
            latencyMs: DateTime.now().difference(now).inMilliseconds),
      };
    } catch (e) {
      state = {
        ...state,
        id: _ProviderHealth._(
            error: e.toString(),
            checkedAtMs: DateTime.now().millisecondsSinceEpoch),
      };
    }
  }
}

final providerHealthListProvider = Provider<List<({String id, _ProviderHealth h})>>((ref) {
  ref.watch(providerHealthMapProvider);
  final map = ref.read(providerHealthMapProvider);
  final providers = ref.watch(chatServiceProvider).providers.all;
  return [
    for (final p in providers) (id: p.id, h: map[p.id] ?? _ProviderHealth.pending())
  ];
});

/// Modos do composer — os mesmos ids persistidos em settings.json
/// (`composerMode`) e gravados nas mensagens.
const _kComposerModes = <({String id, String label, String description})>[
  (
    id: 'build',
    label: 'Build',
    description:
        'Agente executa tools e aplica mudanças no código (com aprovação).'
  ),
  (
    id: 'plan',
    label: 'Plan',
    description:
        'Agente planeja e propõe diffs; nada é escrito sem você aprovar.'
  ),
  (
    id: 'ask',
    label: 'Ask',
    description:
        'Somente leitura: responde com contexto real, sem ações de efeito.'
  ),
];

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
      children: [
        Text('Ajustes', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Persistidos em <dataDir>/settings.json. Chaves ficam no storage de '
          'segredos local, separadas do arquivo de configuração.',
          style:
              theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
        const SizedBox(height: 16),
        const _Section(title: 'Provedores de modelos', child: _ProvidersCard()),
        const _Section(
            title: 'Modelo padrão', child: _DefaultModelCard()),
        const _Section(title: 'Modo do composer', child: _ComposerModeCard()),
        const _Section(
            title: 'Postura do agente', child: _PostureCard()),
        const _Section(
            title: 'Aprovação de ferramentas', child: _ApprovalCard()),
        const _Section(title: 'Limites do agente', child: _LimitsCard()),
        const _Section(
            title: 'System prompt do agente',
            child: _SystemPromptCard()),
        const _Section(title: 'Segredos', child: _SecretsCard()),
        const _Section(title: 'Aparência', child: _ThemeCard()),
        const _Section(title: 'Diagnóstico', child: _HealthSummaryCard()),
        const _Section(title: 'Sobre', child: _AboutCard()),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(),
              style: theme.textTheme.labelSmall
                  ?.copyWith(letterSpacing: 1.1, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Card(child: child),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Provedores (specs em settings.json + chaves no FileSecretStore)
// ---------------------------------------------------------------------------

class _ProvidersCard extends ConsumerStatefulWidget {
  const _ProvidersCard();

  @override
  ConsumerState<_ProvidersCard> createState() => _ProvidersCardState();
}

class _ProvidersCardState extends ConsumerState<_ProvidersCard> {
  bool _busy = false;

  Future<void> _saveSpecs(List<ProviderFileSpec> specs) async {
    setState(() => _busy = true);
    try {
      await ref.read(settingsWriterProvider).update((current) async {
        final next = Map<String, Object?>.of(current);
        next['providers'] = [for (final s in specs) s.toJson()];
        return next;
      });
      // Providers reais só existem depois do boot: recarrega o núcleo inteiro
      // para registrar os novos endpoints/chaves sem fingir estado.
      ref.invalidate(vtAppProvider);
      ref.invalidate(healthReportProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text(
            'Settings salvos. Reinicie a sessão do app (botão abaixo) para '
            'registrar os providers no núcleo.'),
        action: SnackBarAction(label: 'Reiniciar', onPressed: _rebootstrap),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rebootstrap() async {
    final shellContext = ref.read(bootProvider.notifier);
    await shellContext.bootstrapStrict(
      workspaceRoots: ref.read(pendingWorkspaceRootsProvider),
      uiContext: () => context,
    );
  }

  Future<void> _editProvider(ProviderFileSpec? existing) async {
    final result = await showDialog<ProviderFileSpec>(
      context: context,
      builder: (_) => _ProviderDialog(existing: existing),
    );
    if (result == null) return;
    final current = ref.read(settingsProvider).providers.toList();
    final idx = current.indexWhere((p) => p.id == result.id);
    if (idx >= 0) {
      current[idx] = result;
    } else {
      current.add(result);
    }
    await _saveSpecs(current);
  }

  Future<void> _removeProvider(String id) async {
    final current = ref.read(settingsProvider).providers
        .where((p) => p.id != id)
        .toList();
    final secrets = ref.read(secretStoreProvider);
    await secrets?.delete(id);
    await _saveSpecs(current);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final specs = ref.watch(settingsProvider).providers;
    final secretIds = ref.watch(_secretIdsProvider).valueOrNull ?? const [];
    // mapa REAL de health medido sob demanda (vazio até a primeira checagem)
    final health = ref.watch(providerHealthMapProvider);
    final anyChecking = health.values.any((h) => h.isChecking);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Saúde da conexão do chat com os providers',
                  style: theme.textTheme.labelMedium,
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: anyChecking || specs.isEmpty
                    ? null
                    : () => ref
                        .read(providerHealthMapProvider.notifier)
                        .checkAll(),
                icon: anyChecking
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.monitor_heart_outlined, size: 16),
                label: Text(anyChecking ? 'Verificando…' : 'Verificar conexão'),
              ),
            ],
          ),
        ),
        if (specs.isEmpty)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              'Nenhum provider configurado. O chat exige ao menos um endpoint '
              'real com chave.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        for (final s in specs)
          ListTile(
            dense: true,
            title: Text(s.displayName,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${s.id} → ${s.baseUrl}',
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11)),
                Text(
                    'modelos: ${s.modelIds.isEmpty ? '(nenhum listado)' : s.modelIds.join(', ')}'
                    '${s.anthropicNative ? ' • wire Anthropic nativo' : ''}',
                    style: theme.textTheme.labelSmall),
                if (health[s.id]?.hasResult ?? false)
                  _HealthDetail(h: health[s.id]!),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _HealthBadge(h: health[s.id]),
                Tooltip(
                  message: secretIds.contains(s.id)
                      ? 'chave definida (não exibida)'
                      : 'sem chave',
                  child: Icon(
                    secretIds.contains(s.id)
                        ? Icons.key_outlined
                        : Icons.key_off_outlined,
                    size: 15,
                    color:
                        secretIds.contains(s.id) ? vt.riskLow : vt.riskMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  onPressed: _busy ? null : () => _editProvider(s),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 16, color: vt.riskCritical),
                  onPressed: _busy ? null : () => _removeProvider(s.id),
                ),
              ],
            ),
            onTap: _busy ? null : () => _editProvider(s),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _editProvider(null),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Adicionar provedor'),
            ),
          ),
        ),
      ],
    );
  }
}

/// Lista real dos ids com chave gravada (nunca o valor).
final _secretIdsProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  final store = ref.watch(secretStoreProvider);
  if (store == null) return const [];
  return store.ids();
});

({IconData icon, String label, Color color}) _healthVisual(
    ProviderStatus s, VtColors vt) {
  switch (s) {
    case ProviderStatus.ok:
      return (icon: Icons.check_circle_outline, label: 'online', color: vt.riskLow);
    case ProviderStatus.rateLimited:
      return (
        icon: Icons.hourglass_empty,
        label: 'rate limited',
        color: vt.riskMedium
      );
    case ProviderStatus.offline:
      return (
        icon: Icons.cloud_off,
        label: 'offline',
        color: vt.riskMedium
      );
    case ProviderStatus.unconfigured:
      return (
        icon: Icons.settings_ethernet,
        label: 'não configurado',
        color: vt.riskHigh
      );
    case ProviderStatus.error:
      return (
        icon: Icons.error_outline,
        label: 'erro',
        color: vt.riskCritical
      );
  }
}

/// Selo de saúde por provider: só mostra estado medido; sem checagem feita,
/// um botão dispara a verificação real — nunca há status presumido.
class _HealthBadge extends StatelessWidget {
  const _HealthBadge({this.h});
  final _ProviderHealth? h;

  @override
  Widget build(BuildContext context) {
    final vt = VtTheme.of(context);
    final health = h;
    if (health == null || health.checkedAtMs == 0) {
      return IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Verificar conexão deste provider (health check real)',
        icon: const Icon(Icons.wifi_tethering_off, size: 15),
        onPressed: () =>
            ProviderScope.containerOf(context)
                .read(providerHealthMapProvider.notifier)
                .checkAll(),
      );
    }
    if (health.isChecking) {
      return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2));
    }
    final (icon, label, color) = health.status != null
        ? _healthVisual(health.status!, VtTheme.of(context))
        : (Icons.help_outline, 'falhou', vt.riskCritical);
    return Tooltip(
      message: '$label • ${_checkedAgo(health.checkedAtMs)}'
          '${health.latencyMs != null ? ' • ${health.latencyMs}ms' : ''}'
          '${health.error != null ? '\n${health.error}' : ''}',
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// Linha de detalhe do último resultado REAL de health check.
class _HealthDetail extends StatelessWidget {
  const _HealthDetail({required this.h});
  final _ProviderHealth h;

  @override
  Widget build(BuildContext context) {
    final vt = VtTheme.of(context);
    final (icon, label, color) = h.status != null
        ? _healthVisual(h.status!, vt)
        : (Icons.help_outline, 'falhou', vt.riskCritical);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        'conexão: $label'
        '${h.latencyMs != null ? ' • ${h.latencyMs}ms' : ''}'
        ' • verificado ${_checkedAgo(h.checkedAtMs)}'
        '${h.error != null ? ' • ${h.error}' : ''}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10.5, color: color),
      ),
    );
  }
}

String _checkedAgo(int epochMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final s = DateTime.now().difference(dt).inSeconds;
  if (s < 5) return 'agora';
  if (s < 60) return 'há ${s}s';
  if (s < 3600) return 'há ${s ~/ 60}min';
  return 'há ${s ~/ 3600}h';
}

class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog({this.existing});
  final ProviderFileSpec? existing;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late final TextEditingController _id;
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _models;
  late final TextEditingController _apiKey;
  late bool _anthropic;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _id = TextEditingController(text: e?.id ?? '');
    _name = TextEditingController(text: e?.displayName ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _models = TextEditingController(text: e?.modelIds.join(', ') ?? '');
    _apiKey = TextEditingController(); // nunca pré-preenchido
    _anthropic = e?.anthropicNative ?? false;
  }

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _baseUrl.dispose();
    _models.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final id = _id.text.trim();
    final base = _baseUrl.text.trim();
    if (id.isEmpty || base.isEmpty) {
      setState(() => _error = 'id e baseUrl são obrigatórios.');
      return;
    }
    final spec = ProviderFileSpec(
      id: id,
      displayName: _name.text.trim().isEmpty ? id : _name.text.trim(),
      baseUrl: base,
      modelIds: _models.text
          .split(',')
          .map((m) => m.trim())
          .where((m) => m.isNotEmpty)
          .toList(),
      anthropicNative: _anthropic,
    );
    final key = _apiKey.text.trim();
    if (key.isNotEmpty) {
      final container = ProviderScope.containerOf(context);
      final store = container.read(secretStoreProvider);
      if (store == null) {
        setState(() => _error = 'Storage de segredos indisponível nesta sessão.');
        return;
      }
      await store.write(id, key);
      container.invalidate(_secretIdsProvider);
    }
    if (mounted) Navigator.of(context).pop(spec);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null
          ? 'Novo provedor'
          : 'Editar provedor "${widget.existing!.id}"'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _id,
                enabled: widget.existing == null,
                decoration: const InputDecoration(
                    labelText: 'id (estável, ex.: openai)'),
              ),
              const SizedBox(height: 10),
              TextField(
                  controller: _name,
                  decoration:
                      const InputDecoration(labelText: 'Nome de exibição')),
              const SizedBox(height: 10),
              TextField(
                controller: _baseUrl,
                decoration: const InputDecoration(
                    labelText: 'baseUrl',
                    helperText:
                        'ex.: https://api.openai.com/v1 ou http://localhost:11434/v1'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _models,
                decoration: const InputDecoration(
                    labelText: 'ids de modelos',
                    helperText: 'separados por vírgula'),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _anthropic,
                title: const Text('Wire Anthropic Messages nativo',
                    style: TextStyle(fontSize: 13)),
                onChanged: (v) => setState(() => _anthropic = v),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _apiKey,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'API key',
                  helperText: widget.existing == null
                      ? 'gravada no storage local; nunca aparece aqui de novo'
                      : 'deixe vazio para manter a chave atual',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!,
                      style: TextStyle(
                          color: VtTheme.of(context).riskCritical,
                          fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Modelo default / postura / tema / sobre
// ---------------------------------------------------------------------------

class _DefaultModelCard extends ConsumerWidget {
  const _DefaultModelCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final models = ref
        .watch(chatServiceProvider)
        .providers
        .all
        .expand((p) => p.models.where((m) => m.enabled))
        .toList();
    final selected = ref.watch(selectedModelProvider);

    return ListTile(
      dense: true,
      title: const Text('Modelo usado quando o composer não escolhe um',
          style: TextStyle(fontSize: 13)),
      subtitle: models.isEmpty
          ? Text(
              'Nenhum provider registrado — configure acima. '
              'O chat não inventa modelo fallback.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor))
          : DropdownButton<String?>(
              value: models.any((m) => m.id == selected) ? selected : null,
              isExpanded: true,
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('(perguntar a cada envio)')),
                for (final m in models)
                  DropdownMenuItem(
                    value: m.id,
                    child: Text('${m.displayName} · ${m.providerId}',
                        style: const TextStyle(fontSize: 12)),
                  ),
              ],
              onChanged: (v) async {
                ref.read(selectedModelProvider.notifier).state = v;
                await ref.read(settingsWriterProvider).update((cur) {
                  final next = Map<String, Object?>.of(cur);
                  if (v == null) {
                    next.remove('defaultModel');
                  } else {
                    next['defaultModel'] = v;
                  }
                  return next;
                });
                ref.invalidate(settingsProvider);
              },
            ),
    );
  }
}

class _PostureCard extends ConsumerWidget {
  const _PostureCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(agentPostureProvider);
    return Column(
      children: [
        for (final p in AgentPostureChoice.values)
          RadioListTile<AgentPostureChoice>(
            dense: true,
            value: p,
            groupValue: current,
            title: Text(p.label, style: const TextStyle(fontSize: 13)),
            subtitle: Text(p.description,
                style: const TextStyle(fontSize: 11)),
            onChanged: (v) async {
              if (v == null) return;
              ref.read(agentPostureProvider.notifier).state = v;
              await ref.read(settingsWriterProvider).update((cur) {
                final next = Map<String, Object?>.of(cur);
                next['agentPosture'] = v.name;
                return next;
              });
              ref.invalidate(settingsProvider);
            },
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Modo do composer / aprovação / limites / system prompt / segredos / saúde
// ---------------------------------------------------------------------------

class _ComposerModeCard extends ConsumerWidget {
  const _ComposerModeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final current = ref.watch(composerModeProvider);
    return Column(
      children: [
        for (final m in _kComposerModes)
          RadioListTile<String>(
            dense: true,
            value: m.id,
            groupValue: current,
            title: Text(m.label, style: const TextStyle(fontSize: 13)),
            subtitle: Text(m.description,
                style: const TextStyle(fontSize: 11)),
            onChanged: (v) async {
              if (v == null) return;
              ref.read(composerModeProvider.notifier).state = v;
              await persistSetting(ref, 'composerMode', v);
            },
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                ref.read(composerModeProvider.notifier).state = null;
                await persistSetting(ref, 'composerMode', null);
              },
              child: Text('Sem preferência (o composer decide por envio)',
                  style: theme.textTheme.labelSmall),
            ),
          ),
        ),
      ],
    );
  }
}

class _ApprovalCard extends ConsumerWidget {
  const _ApprovalCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final current = ref.watch(composerApprovalProvider);
    final tools = ref.watch(vtAppProvider).registry.all;
    int needing(String posture) => tools.where((t) {
          switch (posture) {
            case 'manual':
              return t.defaultApproval != ApprovalPolicyMode.auto;
            case 'autoSafe':
              return t.risk != RiskLevel.readOnly &&
                  t.defaultApproval != ApprovalPolicyMode.auto;
            case 'autoAll':
              return t.defaultApproval == ApprovalPolicyMode.explicitApproval ||
                  t.defaultApproval == ApprovalPolicyMode.typedConfirmation;
            default:
              return t.defaultApproval != ApprovalPolicyMode.auto;
          }
        }).length;

    return Column(
      children: [
        for (final p in ComposerApprovalChoice.values)
          RadioListTile<ComposerApprovalChoice>(
            dense: true,
            value: p,
            groupValue: current,
            title: Row(
              children: [
                Expanded(
                  child: Text(p.label, style: const TextStyle(fontSize: 13)),
                ),
                Text('${needing(p.name)} de ${tools.length} pedirão aprovação',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: vt.riskMedium)),
              ],
            ),
            subtitle: Text(p.description, style: const TextStyle(fontSize: 11)),
            onChanged: (v) async {
              if (v == null) return;
              ref.read(composerApprovalProvider.notifier).state = v;
              await persistSetting(ref, 'approvalPosture', v.name);
            },
          ),
        ListTile(
          dense: true,
          selected: current == null,
          leading: const Icon(Icons.verified_outlined, size: 18),
          title: const Text('Política do contrato (padrão)',
              style: TextStyle(fontSize: 13)),
          subtitle: Text(
              'Cada tool define sua própria política (read-only auto, escrita '
              'com revisão). Nunca força execução silenciosa.',
              style: const TextStyle(fontSize: 11)),
          onTap: () async {
            ref.read(composerApprovalProvider.notifier).state = null;
            await persistSetting(ref, 'approvalPosture', null);
          },
        ),
      ],
    );
  }
}

class _LimitsCard extends ConsumerStatefulWidget {
  const _LimitsCard();

  @override
  ConsumerState<_LimitsCard> createState() => _LimitsCardState();
}

class _LimitsCardState extends ConsumerState<_LimitsCard> {
  late final TextEditingController _maxSteps;
  late final TextEditingController _maxCost;
  late final TextEditingController _timeout;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Pré-preenche com os valores REAIS atualmente persistidos.
    final s = ref.read(settingsProvider);
    _maxSteps =
        TextEditingController(text: '${s.get('maxToolSteps') ?? ''}');
    _maxCost =
        TextEditingController(text: '${s.get('maxCostUsd') ?? ''}');
    _timeout =
        TextEditingController(text: '${s.get('stepTimeoutSeconds') ?? ''}');
  }

  @override
  void dispose() {
    _maxSteps.dispose();
    _maxCost.dispose();
    _timeout.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    Object? parseInto(TextEditingController c, String label, int min) {
      final t = c.text.trim();
      if (t.isEmpty) return null;
      final v = int.tryParse(t);
      if (v == null || v < min) {
        _error ??= '$label: inteiro ≥ $min, ou vazio (sem limite).';
        return -9999; // sentinela de erro
      }
      return v;
    }

    _error = null;
    final steps = parseInto(_maxSteps, 'Passos máximos', 1);
    final cost = parseInto(_maxCost, 'Custo máximo (centavos USD)', 1);
    final to = parseInto(_timeout, 'Timeout por passo (s)', 5);
    if (_error != null) {
      setState(() {});
      return;
    }
    await ref.read(settingsWriterProvider).update((cur) {
      final next = Map<String, Object?>.of(cur);
      void put(String k, Object? v) => v == null ? next.remove(k) : next[k] = v;
      put('maxToolSteps', steps);
      put('maxCostUsd', cost);
      put('stepTimeoutSeconds', to);
      return next;
    });
    ref.invalidate(settingsProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Limites salvos em settings.json.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Valores gravados de verdade em settings.json. Deixe vazio para '
            'não impor o limite. O executor do agente consulta estas chaves.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _maxSteps,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Passos máximos por turno (maxToolSteps)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _maxCost,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Custo máximo por turno em centavos de USD (maxCostUsd)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _timeout,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Timeout por passo em segundos (stepTimeoutSeconds)',
              isDense: true,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: TextStyle(
                      color: VtTheme.of(context).riskCritical, fontSize: 12)),
            ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(onPressed: _save, child: const Text('Salvar')),
          ),
        ],
      ),
    );
  }
}

class _SystemPromptCard extends ConsumerStatefulWidget {
  const _SystemPromptCard();

  @override
  ConsumerState<_SystemPromptCard> createState() => _SystemPromptCardState();
}

class _SystemPromptCardState extends ConsumerState<_SystemPromptCard> {
  late final TextEditingController _controller;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    // Pré-preenche com o prompt REAL em vigor nesta sessão (default do
    // techVT-Agent-01 ou a override persistida — nunca texto inventado).
    _controller =
        TextEditingController(text: ref.read(chatServiceProvider).systemPrompt);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      await restoreDefault();
      return;
    }
    // Aplica na sessão atual E persiste a override real. A setting
    // `agentSystemPrompt` tem precedência no executor, então gravá-la já é
    // suficiente para o prompt sobreviver ao restart.
    ref.read(chatServiceProvider).systemPrompt = text;
    await persistSetting(ref, 'agentSystemPrompt', text);
    if (!mounted) return;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('System prompt aplicado e salvo.')));
  }

  Future<void> restoreDefault() async {
    final def = kDefaultAgentSystemPrompt;
    ref.read(chatServiceProvider).systemPrompt = def;
    _controller.value = TextEditingValue(text: def);
    await persistSetting(ref, 'agentSystemPrompt', null);
    if (mounted) {
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Prompt padrão techVT-Agent-01 restaurado.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overridden =
        ref.watch(settingsProvider).get('agentSystemPrompt') != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(overridden ? Icons.edit_note : Icons.assistant_outlined,
                  size: 16, color: theme.hintColor),
              const SizedBox(width: 6),
              Text(
                  overridden
                      ? 'Override ativo (settings.json → agentSystemPrompt)'
                      : 'Prompt padrão techVT-Agent-01 em vigor',
                  style: theme.textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            minLines: 6,
            maxLines: 16,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            onChanged: (_) {
              if (!_dirty) setState(() => _dirty = true);
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: _dirty ? _save : null,
                child: const Text('Salvar e aplicar'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: restoreDefault,
                child: const Text('Restaurar padrão'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SecretsCard extends ConsumerStatefulWidget {
  const _SecretsCard();

  @override
  ConsumerState<_SecretsCard> createState() => _SecretsCardState();
}

class _SecretsCardState extends ConsumerState<_SecretsCard> {
  List<String>? _ids;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(secretStoreProvider);
    final ids = store == null ? <String>[] : (await store.ids())..sort();
    if (mounted) setState(() => _ids = ids);
  }

  Future<void> _delete(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Apagar chave "$id"?'),
        content: const Text(
            'A chave é removida do storage local de segredos. Providers que '
            'dependem dela param de funcionar até você reconfigurar.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Apagar')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(secretStoreProvider)?.delete(id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final store = ref.watch(secretStoreProvider);
    if (store == null) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Text('Storage de segredos indisponível nesta sessão.',
            style: theme.textTheme.bodySmall),
      );
    }
    final ids = _ids;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'Chaves gravadas no storage local (<dataDir>/secrets). O conteúdo '
            'nunca é exibido aqui — apenas o id e o estado.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ),
        if (ids == null)
          const Padding(
              padding: EdgeInsets.all(14),
              child: CircularProgressIndicator(strokeWidth: 2))
        else if (ids.isEmpty)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text('Nenhuma chave definida.',
                style: theme.textTheme.bodySmall),
          )
        else
          for (final id in ids)
            ListTile(
              dense: true,
              leading: Icon(Icons.key_outlined, size: 16, color: vt.riskLow),
              title: Text(id,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12)),
              trailing: IconButton(
                icon: Icon(Icons.delete_outline, size: 16, color: vt.riskCritical),
                tooltip: 'Apagar chave (conteúdo nunca exibido)',
                onPressed: () => _delete(id),
              ),
            ),
        if (_failed)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Falha ao listar o storage de segredos.',
                style: TextStyle(fontSize: 12, color: vt.riskCritical)),
          ),
      ],
    );
  }
}

class _HealthSummaryCard extends ConsumerWidget {
  const _HealthSummaryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final report = ref.watch(healthReportProvider);

    Color colorFor(String status) => switch (status) {
          'ok' => vt.riskLow,
          'warn' => vt.riskMedium,
          _ => vt.riskCritical,
        };

    return report.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => ListTile(
        dense: true,
        leading: Icon(Icons.error_outline, color: vt.riskCritical, size: 18),
        title: Text('Health check falhou: $e',
            style: const TextStyle(fontSize: 12)),
        trailing: IconButton(
          icon: const Icon(Icons.refresh, size: 16),
          onPressed: () => ref.invalidate(healthReportProvider),
        ),
      ),
      data: (r) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
            child: Row(
              children: [
                Text('${r.entries.length} verificações reais',
                    style: theme.textTheme.labelSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => ref.invalidate(healthReportProvider),
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Re-verificar'),
                ),
              ],
            ),
          ),
          for (final e in r.entries)
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: Icon(
                switch (e.status) {
                  'ok' => Icons.check_circle_outline,
                  'warn' => Icons.warning_amber_rounded,
                  _ => Icons.error_outline,
                },
                size: 16,
                color: colorFor(e.status),
              ),
              title: Text(e.name, style: const TextStyle(fontSize: 12)),
              subtitle: Text(e.detail,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            ),
        ],
      ),
    );
  }
}

class _ThemeCard extends ConsumerWidget {
  const _ThemeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(themeModeProvider);
    return Column(
      children: [
        for (final t in VtThemeChoice.values)
          RadioListTile<VtThemeChoice>(
            dense: true,
            value: t,
            groupValue: current,
            title: Text(switch (t) {
              VtThemeChoice.dark => 'Escuro (padrão)',
              VtThemeChoice.light => 'Claro',
              VtThemeChoice.highContrast => 'Alto contraste',
            }, style: const TextStyle(fontSize: 13)),
            onChanged: (v) async {
              if (v == null) return;
              ref.read(themeModeProvider.notifier).state = v;
              await ref.read(settingsWriterProvider).update((cur) {
                final next = Map<String, Object?>.of(cur);
                next['theme'] = v.name;
                return next;
              });
              ref.invalidate(settingsProvider);
            },
          ),
      ],
    );
  }
}

class _AboutCard extends ConsumerWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(vtAppProvider);
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      title: const Text('techVT 0.1.0 — local-first, single-user',
          style: TextStyle(fontSize: 13)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Dados: ${app.dataDir}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          Text(
              'Banco: techvt.sqlite (SQLite FFI) · '
              '${app.registry.all.length} ferramentas · '
              '${app.providerIds.length} providers ativos',
              style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}
