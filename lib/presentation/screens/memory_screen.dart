/// Tela de Memória — CRUD/leitura REAL sobre o MemoryStore (tabela `memories`
/// no SQLite local). Busca lexical com score, stats por kind e criação de
/// memórias pelo formulário — tudo persistido de verdade.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/errors/vt_failure.dart';
import '../../infrastructure/native/memory_store.dart';
import '../state/app_state.dart';
import '../theme/vt_theme.dart';

class MemoryQuery {
  const MemoryQuery({required this.workspaceId, this.text = '', this.kind});
  final String? workspaceId;
  final String text;
  final String? kind;

  @override
  bool operator ==(Object other) =>
      other is MemoryQuery &&
      other.workspaceId == workspaceId &&
      other.text == text &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(workspaceId, text, kind);
}

final memoryQueryProvider =
    StateProvider<MemoryQuery>((ref) => const MemoryQuery(workspaceId: null));

final memorySearchProvider = Provider.autoDispose<MemorySearchResult>(
  (ref) {
    final q = ref.watch(memoryQueryProvider);
    final ws = q.workspaceId;
    if (ws == null) {
      return const MemorySearchResult(items: [], totalEstimate: 0,
          error: 'Abra um workspace para ver a memória dele.');
    }
    try {
      final page = ref.watch(vtAppProvider).memory.search(
            workspaceId: ws,
            query: q.text,
            kind: q.kind,
            pageSize: 50,
            reinforce: false, // navegação na UI não deve inflar pesos
          );
      return MemorySearchResult(
          items: page.items, totalEstimate: page.totalEstimate ?? page.items.length);
    } on VtFailure catch (f) {
      return MemorySearchResult(items: const [], error: '${f.code.wire}: ${f.message}');
    }
  },
);

final memoryStatsProvider = Provider.autoDispose<List<Map<String, Object?>>>(
  (ref) {
    final ws = ref.watch(memoryQueryProvider).workspaceId;
    if (ws == null) return const [];
    return ref.watch(vtAppProvider).memory.stats(workspaceId: ws);
  },
);

class MemorySearchResult {
  const MemorySearchResult({
    required this.items,
    this.totalEstimate = 0,
    this.error,
  });
  final List<MemoryRecord> items;
  final int totalEstimate;
  final String? error;
}

const _kMemoryKinds = ['fact', 'preference', 'procedure', 'decision'];

class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key});

  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final ws = ref.watch(focusedWorkspacePathProvider);
    // Sincroniza o escopo da busca com o workspace em foco.
    final current = ref.watch(memoryQueryProvider);
    if (current.workspaceId != ws ||
        current.text != _searchCtrl.text) {
      if (current.workspaceId != ws) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(memoryQueryProvider.notifier).state = MemoryQuery(
              workspaceId: ws, text: _searchCtrl.text, kind: current.kind);
        });
      }
    }
    final result = ref.watch(memorySearchProvider);
    final stats = ref.watch(memoryStatsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Memória', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      ws == null
                          ? 'Sem workspace em foco — a memória é por workspace.'
                          : 'Memórias de "$ws" (tabela memories, SQLite local).',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: ws == null
                    ? null
                    : () => _showEditor(context, ref, null),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Nova memória'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    hintText: 'Busca lexical (tokens)…',
                    prefixIcon: Icon(Icons.search, size: 16),
                  ),
                  onChanged: (v) {
                    ref.read(memoryQueryProvider.notifier).state =
                        MemoryQuery(
                            workspaceId: ws,
                            text: v,
                            kind: ref.read(memoryQueryProvider).kind);
                  },
                ),
              ),
              const SizedBox(width: 10),
              DropdownButton<String?>(
                value: ref.watch(memoryQueryProvider).kind,
                hint: const Text('tipo'),
                style: theme.textTheme.bodyMedium,
                items: [
                  const DropdownMenuItem(value: null, child: Text('todos')),
                  for (final k in _kMemoryKinds)
                    DropdownMenuItem(value: k, child: Text(k)),
                ],
                onChanged: (k) {
                  ref.read(memoryQueryProvider.notifier).state = MemoryQuery(
                      workspaceId: ws,
                      text: _searchCtrl.text,
                      kind: k);
                },
              ),
            ],
          ),
        ),
        if (stats.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in stats)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: vt.accent.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${s['kind']}: ${s['count']} '
                      '(peso médio ${(double.tryParse('${s['avg_weight']}') ?? 0).toStringAsFixed(2)})',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Divider(height: 1, color: theme.dividerColor),
        Expanded(
          child: result.error != null
              ? Center(
                  child: Text(result.error!,
                      style: theme.textTheme.bodyMedium))
              : result.items.isEmpty
                  ? Center(
                      child: Text(
                        _searchCtrl.text.isEmpty
                            ? 'Nenhuma memória salva neste workspace ainda.'
                            : 'Nada encontrado para "${_searchCtrl.text}".',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: result.items.length,
                      itemBuilder: (context, i) => _MemoryTile(
                        record: result.items[i],
                        onEdit: () =>
                            _showEditor(context, ref, result.items[i]),
                        onDelete: () async {
                          final ok = ref
                              .read(vtAppProvider)
                              .memory
                              .delete(result.items[i].id);
                          ref.invalidate(memorySearchProvider);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(ok
                                ? 'Memória #${result.items[i].id} excluída.'
                                : 'Falha ao excluir (registro ausente).'),
                          ));
                        },
                      ),
                    ),
        ),
      ],
    );
  }

  Future<void> _showEditor(
      BuildContext context, WidgetRef ref, MemoryRecord? existing) async {
    final ws = ref.read(focusedWorkspacePathProvider);
    if (ws == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _MemoryEditorDialog(existing: existing),
    );
    if (saved != true) return;
    ref.read(memorySearchProvider); // recria leitura limpa
    setState(() {});
    ref.invalidate(memorySearchProvider);
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile(
      {required this.record, required this.onEdit, required this.onDelete});
  final MemoryRecord record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: vt.accent.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(record.kind,
                    style: TextStyle(fontSize: 10, color: vt.accent)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(record.title,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
              ),
              Text('peso ${record.weight.toStringAsFixed(2)}',
                  style: theme.textTheme.labelSmall),
              IconButton(
                tooltip: 'Editar',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 16),
                onPressed: onEdit,
              ),
              IconButton(
                tooltip: 'Excluir',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.delete_outline,
                    size: 16, color: vt.riskCritical),
                onPressed: onDelete,
              ),
            ],
          ),
          Text(record.body,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall),
          if (record.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                children: [
                  for (final t in record.tags)
                    Text('#$t',
                        style: TextStyle(fontSize: 11, color: theme.hintColor)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MemoryEditorDialog extends StatefulWidget {
  const _MemoryEditorDialog({this.existing});
  final MemoryRecord? existing;

  @override
  State<_MemoryEditorDialog> createState() => _MemoryEditorDialogState();
}

class _MemoryEditorDialogState extends State<_MemoryEditorDialog> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late final TextEditingController _tags;
  late String _kind;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title ?? '');
    _body = TextEditingController(text: e?.body ?? '');
    _tags = TextEditingController(text: e?.tags.join(', ') ?? '');
    _kind = e?.kind ?? 'fact';
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null
          ? 'Nova memória'
          : 'Editar memória #${widget.existing!.id}'),
      content: SizedBox(width: 460, child: _form(context)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final app = ProviderScope.containerOf(context)
                .read(vtAppProvider);
            final ws = ProviderScope.containerOf(context)
                .read(focusedWorkspacePathProvider);
            if (ws == null) return;
            final title = _title.text.trim();
            final body = _body.text.trim();
            if (title.isEmpty || body.isEmpty) {
              setState(() => _error = 'Título e corpo são obrigatórios.');
              return;
            }
            app.memory.upsert(
              id: widget.existing?.id,
              workspaceId: ws,
              kind: _kind,
              title: title,
              body: body,
              tags: _tags.text
                  .split(',')
                  .map((t) => t.trim())
                  .where((t) => t.isNotEmpty)
                  .toList(),
              weight: widget.existing?.weight ?? 1.0,
            );
            Navigator.of(context).pop(true);
          },
          child: const Text('Salvar'),
        ),
      ],
    );
  }

  Widget _form(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _kind,
          decoration: const InputDecoration(labelText: 'Tipo'),
          items: [
            for (final k in _kMemoryKinds)
              DropdownMenuItem(value: k, child: Text(k)),
          ],
          onChanged: (v) => setState(() => _kind = v ?? _kind),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _title,
          decoration: const InputDecoration(labelText: 'Título'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _body,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(labelText: 'Corpo'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _tags,
          decoration: const InputDecoration(
              labelText: 'Tags', helperText: 'separadas por vírgula'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!,
                style: TextStyle(
                    color: VtTheme.of(context).riskCritical, fontSize: 12)),
          ),
      ],
    );
  }
}
