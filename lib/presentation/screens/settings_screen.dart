/// Tela de Ajustes — edição REAL do settings.json (providers, modelo default,
/// postura do agente, tema) e das chaves de API via FileSecretStore.
///
/// Regra de segurança: o segredo NUNCA é exibido na tela — só se grava,
/// se apaga e se mostra "definida/não definida" (com tamanho, nunca conteúdo).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/app_bootstrap.dart';
import '../secrets/secret_store.dart';
import '../state/app_state.dart';
import '../theme/vt_theme.dart';

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
        const _Section(
            title: 'Postura do agente', child: _PostureCard()),
        const _Section(title: 'Aparência', child: _ThemeCard()),
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

    return Column(
      children: [
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
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
