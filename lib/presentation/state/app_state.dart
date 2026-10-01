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
import '../../domain/models/pagination.dart';
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

enum UiSection { chat, workspaces, tools, memory, diagnostics, settings }

final sectionProvider =
    StateProvider<UiSection>((ref) => UiSection.chat);

final currentWorkspacePathProvider = StateProvider<String?>((ref) => null);

final currentConversationIdProvider = StateProvider<String?>((ref) => null);

enum VtThemeChoice { dark, light, highContrast }

final themeModeProvider =
    StateProvider<VtThemeChoice>((ref) => VtThemeChoice.dark);

enum AgentPostureChoice {
  askFirst('Ask first', 'Executa tools somente após aprovação explícita.'),
  proposeOnly('Propose only', 'Planeja e propõe mudanças, nunca executa sozinho.'),
  safeAuto('Safe auto', 'Auto-executa apenas tools read-only; o resto exige aprovação.');

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

  Future<void> add(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Pasta inexistente: $path',
        recoveryActions: const [
          RecoveryAction(kind: 'pick_folder', label: 'Escolher uma pasta válida')
        ],
      );
    }
    final settings = ref.read(settingsProvider);
    final list = [
      path,
      ...settings.recentWorkspaces.where((p) => p != path),
    ];
    await _persist(list);
    state = build();
  }

  Future<void> remove(String path) async {
    final settings = ref.read(settingsProvider);
    await _persist(
        settings.recentWorkspaces.where((p) => p != path).toList());
    state = build();
  }

  Future<void> _persist(List<String> list) async {
    final app = ref.read(vtAppProvider);
    final values = await _readRawSettings(app.dataDir);
    values['recentWorkspaces'] = list;
    await FileSettings.save(app.dataDir, values);
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

class ConversationListData {
  const ConversationListData({required this.items, required this.workspaceId});
  /// Linhas reais de `conversations` (id, title, created_at, ...).
  final List<Map<String, Object?>> items;
  final String? workspaceId;
}

class ConversationListNotifier extends AutoDisposeNotifier<ConversationListData> {
  @override
  ConversationListData build() {
    final ws = ref.watch(focusedWorkspacePathProvider);
    if (ws == null) {
      return const ConversationListData(items: [], workspaceId: null);
    }
    return ConversationListData(
      items: ref.watch(chatServiceProvider).listConversations(ws),
      workspaceId: ws,
    );
  }

  /// Cria conversa REAL no SQLite e a coloca em foco.
  String create(String title) {
    final ws = state.workspaceId;
    if (ws == null) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Nenhum workspace aberto para criar a conversa.',
        recoveryActions: const [
          RecoveryAction(kind: 'pick_folder', label: 'Abrir uma pasta'),
        ],
      );
    }
    final id = ref.read(chatServiceProvider)
        .createConversation(workspaceId: ws, title: title);
    ref.read(currentConversationIdProvider.notifier).state = id;
    refresh();
    return id;
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
