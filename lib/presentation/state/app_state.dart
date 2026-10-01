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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/app_bootstrap.dart';
import '../../application/approval.dart';
import '../../application/chat_service.dart';
import '../../domain/errors/vt_failure.dart';
import '../../domain/models/pagination.dart';
import '../../infrastructure/native/chat_records.dart';
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

final conversationListProvider = AutoDisposeNotifierProviderFamily<
    ConversationListNotifier, List<Map<String, Object?>>, String>(
    ConversationListNotifier.new);

class ConversationListNotifier extends
    AutoDisposeFamilyNotifier<List<Map<String, Object?>>, String> {
  @override
  List<Map<String, Object?>> build(String arg) => _load();

  List<Map<String, Object?>> _load() =>
      ref.watch(chatServiceProvider).listConversations(arg);

  String create(String title) {
    final chat = ref.read(chatServiceProvider);
    final id = chat.createConversation(workspaceId: arg, title: title);
    refresh();
    return id;
  }

  void refresh() => state = _load();
}

/// Página inicial do histórico (cursor-based real via ChatRepository).
final messagesPageProvider =
    FutureProvider.autoDispose.family<Page<MessageRecord>, String>(
  (ref, convId) async => ref.watch(chatServiceProvider).pageMessages(convId),
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
