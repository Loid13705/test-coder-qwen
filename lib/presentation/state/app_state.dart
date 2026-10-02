/// Estado global do app (Riverpod) — fiação REAL com a camada de aplicação.
///
/// Regra do projeto: sem mocks. O boot estrito (`BootNotifier.bootstrapStrict`)
/// abre o núcleo real (SQLite FFI + sandbox + tools + providers). Se algo
/// falha, a UI mostra o `VtFailure` tipado com ação concreta — nunca um
/// estado inventado para "deixar a interface abrir".
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/app_bootstrap.dart';
import '../../application/approval.dart';
import '../../application/chat_service.dart';
import '../../application/tool_registry.dart';
import '../../domain/errors/vt_failure.dart';
import '../../infrastructure/native/chat_records.dart';
import '../../infrastructure/provider/provider_contract.dart';
import '../dialogs/approval_dialog.dart';
import '../secrets/secret_store.dart';

// ============================================================================
// Boot
// ============================================================================

sealed class BootResult {
  const BootResult();
}

class Booting extends BootResult {
  const Booting();
}

class BootSuccess extends BootResult {
  const BootSuccess(this.app);
  final VtApp app;
}

class BootFailed extends BootResult {
  const BootFailed(this.failure);
  final VtFailure failure;
}

/// Gateway de aprovação que abre o diálogo real da UI (spec §APROVAÇÃO).
/// Sem resposta (janela fechada) = rejeitado — nunca aprovado por default.
class UiApprovalGateway implements ApprovalGateway {
  UiApprovalGateway(this._context);

  /// Contexto da raiz do app (estável; dialogs vivem acima das rotas).
  final BuildContext Function() _context;

  @override
  Future<ApprovalDecision> request(ApprovalRequest req) async {
    final ctx = _context();
    final decision = await showApprovalDialog(ctx, req);
    // Fechou sem decidir: decisão explícita do usuário é REJEITAR.
    return decision ??
        const ApprovalDecision(ApprovalOutcome.rejected,
            reason: 'diálogo fechado sem decisão');
  }
}

/// Raízes de workspace informadas na abertura (CLI/desktop picker).
final pendingWorkspaceRootsProvider =
    StateProvider<List<String>>((ref) => const []);

class BootNotifier extends Notifier<BootResult> {
  @override
  BootResult build() => const Booting();

  /// Injeta um resultado de boot determinístico em testes de widget (a UI do
  /// gate é idêntica à produzida por `bootstrapStrict` — mesma hierarquia
  /// [BootResult], mesmo [VtFailure] tipado). Em produção ninguém chama isto.
  @visibleForTesting
  void debugSetState(BootResult result) => state = result;

  /// Boot real chamado pelo splash ANTES de publicar [vtAppProvider].
  Future<void> bootstrapStrict({
    required List<String> workspaceRoots,
    required BuildContext Function() uiContext,
    String? dataDir,
  }) async {
    state = const Booting();
    try {
      final secrets = await FileSecretStore.open(dataDir ?? defaultDataDir());
      final app = await VtApp.open(
        dataDir: dataDir,
        workspaceRoots: workspaceRoots,
        approvalGateway: UiApprovalGateway(uiContext),
        keyResolver: secrets.read,
      );
      ref.read(secretStoreProvider.notifier).state = secrets;
      if (workspaceRoots.isNotEmpty) {
        ref.read(currentWorkspacePathProvider.notifier).state =
            workspaceRoots.first;
      }
      state = BootSuccess(app);
    } on VtFailure catch (f) {
      state = BootFailed(f);
    } catch (e) {
      state = BootFailed(VtFailure(
        code: VtErrorCode.internalError,
        message: 'Falha inesperada no boot: $e',
        recoveryActions: const [
          RecoveryAction(kind: 'retry', label: 'Tentar novamente'),
        ],
      ));
    }
  }

  Future<void> retry(BuildContext Function() uiContext) async {
    await bootstrapStrict(
      workspaceRoots: ref.read(pendingWorkspaceRootsProvider),
      uiContext: uiContext,
    );
  }
}

final bootProvider =
    NotifierProvider<BootNotifier, BootResult>(BootNotifier.new);

/// Só é lido depois do boot bem-sucedido (a árvore abaixo do gate garante).
final vtAppProvider = Provider<VtApp>((ref) {
  final boot = ref.watch(bootProvider);
  if (boot is BootSuccess) return boot.app;
  throw StateError('vtAppProvider lido sem boot bem-sucedido.');
});

final chatServiceProvider =
    Provider<ChatService>((ref) => ref.watch(vtAppProvider).chat);

final toolRegistryProvider =
    Provider<ToolRegistry>((ref) => ref.watch(vtAppProvider).registry);

final settingsProvider =
    Provider<FileSettings>((ref) => ref.watch(vtAppProvider).settings);

final secretStoreProvider = StateProvider<FileSecretStore?>((ref) => null);

// ============================================================================
// Navegação / seleção
// ============================================================================

enum UiSection {
  chat,
  editor,
  workspaces,
  tools,
  memory,
  diagnostics,
  settings
}

final sectionProvider = StateProvider<UiSection>((ref) => UiSection.chat);

final currentWorkspacePathProvider = StateProvider<String?>((ref) => null);

final currentConversationIdProvider = StateProvider<String?>((ref) => null);

enum VtThemeChoice { dark, light, highContrast }

final themeModeProvider =
    StateProvider<VtThemeChoice>((ref) => VtThemeChoice.dark);

enum AgentPostureChoice {
  askFirst('Ask first', 'Executa tools somente após aprovação explícita.'),
  proposeOnly(
      'Propose only', 'Planeja e propõe mudanças, nunca executa sozinho.'),
  safeAuto('Safe auto',
      'Auto-executa apenas tools read-only; o resto exige aprovação.');

  const AgentPostureChoice(this.label, this.description);
  final String label;
  final String description;
}

final agentPostureProvider =
    StateProvider<AgentPostureChoice>((ref) => AgentPostureChoice.askFirst);

/// Modelo selecionado no composer; default vem de settings.json (real).
final selectedModelProvider = StateProvider<String?>((ref) {
  final v = ref.watch(settingsProvider).get('defaultModel');
  return v is String && v.isNotEmpty ? v : null;
});

/// Postura de aprovação global do composer (settings `approvalPosture`).
/// Persistida em settings.json; o executor a recebe via chatService.
final composerApprovalProvider = StateProvider<ComposerApprovalChoice?>((ref) {
  final v = ref.watch(settingsProvider).get('approvalPosture');
  if (v is String && v.isNotEmpty) {
    for (final c in ComposerApprovalChoice.values) {
      if (c.name == v) return c;
    }
  }
  return null; // null = política pura do contrato de cada tool
});

/// Modo do composer (settings `composerMode`): build | plan | ask.
final composerModeProvider = StateProvider<String?>((ref) {
  final v = ref.watch(settingsProvider).get('composerMode');
  return v is String && v.isNotEmpty ? v : null;
});

// ============================================================================
// Workspaces reais (settings.recentWorkspaces + raízes da sessão)
// ============================================================================

class WorkspaceInfo {
  const WorkspaceInfo({
    required this.path,
    required this.exists,
    required this.isGitRepo,
    this.lastOpenedAt,
  });
  final String path;
  final bool exists;
  final bool isGitRepo;
  final DateTime? lastOpenedAt;

  String get name {
    final normalized = path.replaceAll(RegExp(r'[\\/]+$'), '');
    final idx = normalized.lastIndexOf(RegExp(r'[\\/]'));
    return idx >= 0 ? normalized.substring(idx + 1) : normalized;
  }
}

class WorkspaceListNotifier extends Notifier<List<WorkspaceInfo>> {
  @override
  List<WorkspaceInfo> build() {
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(vtAppProvider);
    final paths = <String>{...app.workspaceRoots, ...settings.recentWorkspaces};
    final list = [for (final p in paths) _probe(p)];
    list.sort((a, b) => (b.lastOpenedAt ?? DateTime(1970))
        .compareTo(a.lastOpenedAt ?? DateTime(1970)));
    return list;
  }

  WorkspaceInfo _probe(String path) {
    final dir = Directory(path);
    final exists = dir.existsSync();
    var isGit = false;
    DateTime? modified;
    if (exists) {
      isGit = Directory('${dir.path}/.git').existsSync() ||
          File('${dir.path}/.git').existsSync();
      try {
        modified = dir.statSync().modified;
      } catch (_) {
        modified = null;
      }
    }
    return WorkspaceInfo(
        path: path, exists: exists, isGitRepo: isGit, lastOpenedAt: modified);
  }

  Future<String> add(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Pasta inexistente: $path',
        recoveryActions: const [
          RecoveryAction(
              kind: 'pick_folder', label: 'Escolher uma pasta válida')
        ],
      );
    }
    final resolvedPath = await dir.resolveSymbolicLinks();
    final settings = ref.read(settingsProvider);
    final list = [
      resolvedPath,
      ...settings.recentWorkspaces.where((p) => p != resolvedPath),
    ];
    await _persist(list);
    final app = ref.read(vtAppProvider);
    app.setWorkspaceRoots({...app.workspaceRoots, resolvedPath});
    state = build();
    return resolvedPath;
  }

  Future<void> remove(String path) async {
    final settings = ref.read(settingsProvider);
    await _persist(settings.recentWorkspaces.where((p) => p != path).toList());
    final app = ref.read(vtAppProvider);
    app.setWorkspaceRoots(app.workspaceRoots.where((root) => root != path));
    state = build();
  }

  Future<void> _persist(List<String> list) async {
    final app = ref.read(vtAppProvider);
    final values = await _readRawSettings(app.dataDir);
    values['recentWorkspaces'] = list;
    await FileSettings.save(app.dataDir, values);
    app.settings.setRecentWorkspaces(list);
    // Re-carrega settings para que a UI reflita o estado real do disco.
    ref.invalidate(settingsProvider);
  }
}

Future<Map<String, Object?>> _readRawSettings(String dataDir) async {
  final f = File('$dataDir/${FileSettings.fileName}');
  if (!await f.exists()) return {};
  try {
    final d = jsonDecode(await f.readAsString());
    if (d is Map) return d.cast<String, Object?>();
  } on FormatException {
    return {};
  }
  return {};
}

final workspaceListProvider =
    NotifierProvider<WorkspaceListNotifier, List<WorkspaceInfo>>(
        WorkspaceListNotifier.new);

// ============================================================================
// Conversas & mensagens
// ============================================================================

/// Workspace efetivo em foco: seleção manual ou primeira raiz do boot.
final focusedWorkspacePathProvider = Provider<String?>((ref) {
  final selected = ref.watch(currentWorkspacePathProvider);
  if (selected != null && selected.isNotEmpty) return selected;
  final roots = ref.watch(vtAppProvider).workspaceRoots;
  return roots.isEmpty ? null : roots.first;
});

/// Escopo de listagem do painel lateral de conversas (spec §CHAT): a conversa
/// por workspace é o default; "Todas" cruza workspaces; "Global" usa o
/// sentinel real [kGlobalConversationWorkspace] no `workspace_id` do SQLite.
enum ConversationScope { currentWorkspace, global, all }

final conversationScopeProvider = StateProvider<ConversationScope>(
    (ref) => ConversationScope.currentWorkspace);

/// Filtro de status da lista (arquivadas/lixeira têm restore dedicado).
enum ConversationListFilter { active, archived, trash }

final conversationFilterProvider = StateProvider<ConversationFilterHolder>(
    (ref) => const ConversationFilterHolder());

/// Holder imutável para o filtro poder ser carregado dentro do notifier sem
/// ciclo (StateProvider simples também serviria; este wrapper só dá nome ao
/// estado na árvore de debug).
class ConversationFilterHolder {
  const ConversationFilterHolder({this.filter = ConversationListFilter.active});
  final ConversationListFilter filter;
}

class ConversationListData {
  const ConversationListData({
    required this.items,
    required this.workspaceId,
    required this.scope,
    required this.filter,
  });

  /// Linhas reais de `conversations` (id, title, pinned, tags, folder, ...).
  final List<Map<String, Object?>> items;
  final String? workspaceId;
  final ConversationScope scope;
  final ConversationListFilter filter;
}

class ConversationListNotifier
    extends AutoDisposeNotifier<ConversationListData> {
  @override
  ConversationListData build() {
    final ws = ref.watch(focusedWorkspacePathProvider);
    final scope = ref.watch(conversationScopeProvider);
    final filter = ref.watch(conversationFilterProvider).filter;
    final chat = ref.watch(chatServiceProvider);
    final targetWs = switch (scope) {
      ConversationScope.currentWorkspace => ws,
      ConversationScope.global => kGlobalConversationWorkspace,
      ConversationScope.all => null,
    };
    if (targetWs == null &&
        scope == ConversationScope.currentWorkspace &&
        filter == ConversationListFilter.active) {
      // Sem workspace aberto e escopo "deste workspace": nada a listar — mas
      // ainda assim um banco com todas as conversas existe; a UI mostra a
      // dica de abrir workspace.
      return ConversationListData(
          items: const [], workspaceId: null, scope: scope, filter: filter);
    }
    final includeAll = scope == ConversationScope.all;
    final items = switch (filter) {
      ConversationListFilter.active =>
        chat.listConversations(targetWs, includeAllWs: includeAll),
      ConversationListFilter.archived =>
        chat.listArchivedConversations(targetWs, includeAllWs: includeAll),
      ConversationListFilter.trash =>
        chat.listDeletedConversations(targetWs, includeAllWs: includeAll),
    };
    return ConversationListData(
        items: items,
        workspaceId: targetWs ?? ws,
        scope: scope,
        filter: filter);
  }

  /// Cria conversa REAL no SQLite e a coloca em foco. No escopo Global usa o
  /// sentinel [kGlobalConversationWorkspace]; no escopo "Todas" herda o
  /// workspace em foco (a conversa pertence a um lugar concreto).
  String create(String title) {
    final data = state;
    final ws = data.scope == ConversationScope.global
        ? kGlobalConversationWorkspace
        : data.workspaceId;
    if (ws == null) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Nenhum workspace aberto para criar a conversa.',
        recoveryActions: const [
          RecoveryAction(kind: 'pick_folder', label: 'Abrir uma pasta'),
        ],
      );
    }
    final id = ref
        .read(chatServiceProvider)
        .createConversation(workspaceId: ws, title: title);
    ref.read(currentConversationIdProvider.notifier).state = id;
    refresh();
    return id;
  }

  /// Fork/branch REAL: nova linha `conversations` apontando `parent_id` para a
  /// conversa original (a origem continua intacta; histórico compartilhado é
  /// copiado à frente conforme novas mensagens chegarem).
  String fork(String sourceId, String title) {
    final src = _rowById(sourceId);
    if (src == null) {
      throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Conversa de origem não encontrada: $sourceId');
    }
    final id = ref.read(chatServiceProvider).createConversation(
        workspaceId: '${src['workspace_id']}',
        title: title,
        parentId: sourceId);
    ref.read(currentConversationIdProvider.notifier).state = id;
    refresh();
    return id;
  }

  void setPinned(String id, bool pinned) {
    ref.read(chatServiceProvider).setPinned(id, pinned);
    refresh();
  }

  void setTags(String id, List<String> tags) {
    ref.read(chatServiceProvider).setTags(id, tags);
    refresh();
  }

  void setFolder(String id, String folder) {
    ref.read(chatServiceProvider).setFolder(id, folder);
    refresh();
  }

  void rename(String id, String title) {
    ref.read(chatServiceProvider).renameConversation(id, title);
    refresh();
  }

  void archive(String id) {
    ref.read(chatServiceProvider).archiveConversation(id);
    if (ref.read(currentConversationIdProvider) == id) {
      ref.read(currentConversationIdProvider.notifier).state = null;
    }
    refresh();
  }

  /// Delete SOFT (vai para a lixeira, restaurável). A UI pede confirmação
  /// antes de chamar isto; purge definitivo exige segunda confirmação.
  void softDelete(String id) {
    ref.read(chatServiceProvider).softDeleteConversation(id);
    if (ref.read(currentConversationIdProvider) == id) {
      ref.read(currentConversationIdProvider.notifier).state = null;
    }
    refresh();
  }

  void restore(String id) {
    ref.read(chatServiceProvider).restoreConversation(id);
    refresh();
  }

  void purge(String id) {
    ref.read(chatServiceProvider).purgeConversation(id);
    if (ref.read(currentConversationIdProvider) == id) {
      ref.read(currentConversationIdProvider.notifier).state = null;
    }
    refresh();
  }

  Map<String, Object?>? _rowById(String id) {
    for (final r in ref
        .read(chatServiceProvider)
        .listConversations(null, includeAllWs: true)) {
      if (r['id'] == id) return r;
    }
    return null;
  }

  void refresh() => state = build();
}

final conversationListProvider =
    AutoDisposeNotifierProvider<ConversationListNotifier, ConversationListData>(
        ConversationListNotifier.new);

/// Página inicial do histórico (cursor-based real via ChatRepository).
final messagesPageProvider =
    FutureProvider.autoDispose.family<List<MessageRecord>, String>(
  (ref, convId) async =>
      ref.watch(chatServiceProvider).pageMessages(convId).items,
);

/// Estado observável da conversa em foco (stream real do ChatService).
final focusedConversationStateProvider =
    StreamProvider.autoDispose<ConversationState>((ref) async* {
  final convId = ref.watch(currentConversationIdProvider);
  if (convId == null) {
    yield const ConversationState(runStatus: RunStatus.idle);
    return;
  }
  final chat = ref.watch(chatServiceProvider);
  yield chat.stateOf(convId);
  await for (final update in chat.states.where((e) => e.$1 == convId)) {
    yield update.$2;
  }
});

// ============================================================================
// Settings persistidos (JSON real em <dataDir>/settings.json)
// ============================================================================

class SettingsWriter {
  final String dataDir;
  SettingsWriter(this.dataDir);

  Future<Map<String, Object?>> update(
      FutureOr<Map<String, Object?>?> Function(Map<String, Object?> current)
          mutator) async {
    final current = await _readRawSettings(dataDir);
    final next = await mutator(current);
    await FileSettings.save(dataDir, next ?? current);
    return next ?? current;
  }
}

final settingsWriterProvider = Provider<SettingsWriter>(
    (ref) => SettingsWriter(ref.watch(vtAppProvider).dataDir));

/// Grava/remove uma chave de topo em settings.json de forma centralizada
/// (usado por todas as cards de Ajustes — evita duplicar o boilerplate).
Future<void> persistSetting(WidgetRef ref, String key, Object? value) async {
  await ref.read(settingsWriterProvider).update((cur) {
    final next = Map<String, Object?>.of(cur);
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    return next;
  });
  ref.invalidate(settingsProvider);
}

// ============================================================================
// Diagnostics (health checks REAIS)
// ============================================================================

class HealthEntry {
  const HealthEntry({
    required this.name,
    required this.status,
    required this.detail,
    this.setupUri,
  });
  final String name;
  final String status; // ok | warn | error
  final String detail;
  final String? setupUri;
}

class HealthReport {
  const HealthReport(this.entries);
  final List<HealthEntry> entries;
  int get errors => entries.where((e) => e.status == 'error').length;
  int get warnings => entries.where((e) => e.status == 'warn').length;
}

final healthReportProvider = FutureProvider<HealthReport>((ref) async {
  final app = ref.watch(vtAppProvider);
  final entries = <HealthEntry>[];

  entries.add(HealthEntry(
    name: 'Banco local (SQLite FFI)',
    status: 'ok',
    detail: '${app.dataDir}/techvt.sqlite — aberto de verdade nesta sessão.',
  ));

  for (final root in app.workspaceRoots) {
    final exists = Directory(root).existsSync();
    entries.add(HealthEntry(
      name: 'Workspace $root',
      status: exists ? 'ok' : 'error',
      detail: exists ? 'Diretório acessível.' : 'Diretório inexistente.',
    ));
  }

  for (final p in app.chat.providers.all) {
    try {
      final st = await p.healthCheck();
      entries.add(HealthEntry(
        name: 'Provider ${p.displayName}',
        status: switch (st) {
          ProviderStatus.ok => 'ok',
          ProviderStatus.rateLimited => 'warn',
          _ => 'error',
        },
        detail: 'healthCheck → ${st.name}',
        setupUri: 'techvt://settings/providers/${p.id}',
      ));
    } on VtFailure catch (f) {
      entries.add(HealthEntry(
        name: 'Provider ${p.displayName}',
        status: 'error',
        detail: '${f.code.wire}: ${f.message}',
        setupUri: f.setupUri,
      ));
    }
  }

  final tools = app.registry.all;
  entries.add(HealthEntry(
    name: 'Registro de ferramentas',
    status: tools.isEmpty ? 'error' : 'ok',
    detail: '${tools.length} ferramentas reais registradas '
        '(${tools.where((t) => t.defaultApproval.name == 'auto').length} auto).',
  ));

  return HealthReport(entries);
});
