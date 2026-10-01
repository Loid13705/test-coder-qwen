/// Bootstrap/composição root do techVT (spec: desktop-first, local-first,
/// sem mocks em produção).
///
/// Centraliza a fiação REAL de todas as camadas — SQLite via FFI, sandbox de
/// workspace, registro completo de tools (FS/Git/memória), provedores LLM e
/// ChatService — para que UI, smoke tests e modo headless usem exatamente o
/// mesmo caminho de produção. Se uma capacidade falta (ex.: libsqlite3
/// ausente), a falha é tipada e propagada por quem abre o DB — nunca há
/// fallback silencioso em memória.
library;

import 'dart:convert';
import 'dart:io';

import '../domain/tools/tool_contract.dart';
import '../infrastructure/checkpoint/checkpoint_store.dart';
import '../infrastructure/checkpoint/checkpoint_tools.dart';
import '../infrastructure/devtools/debug_tools.dart';
import '../infrastructure/devtools/dev_tools.dart';
import '../infrastructure/fs/fs_tools.dart';
import '../infrastructure/git/git_tools.dart';
import '../infrastructure/native/memory_store.dart';
import '../infrastructure/native/memory_tools.dart';
import '../infrastructure/native/sqlite_native.dart';
import '../infrastructure/search/code_index_store.dart';
import '../infrastructure/search/code_index_tools.dart';
import '../infrastructure/search/vector_index_store.dart';
import '../infrastructure/search/vector_index_tools.dart';
import '../infrastructure/provider/anthropic_provider.dart';
import '../infrastructure/provider/openai_compatible_provider.dart';
import '../infrastructure/provider/provider_contract.dart';
import '../infrastructure/sandbox/sandbox.dart';
import 'approval.dart';
import 'chat_service.dart';
import 'tool_registry.dart';

/// Diretório de dados da aplicação (spec local-first):
/// `~/.techVT` em Unix, `%APPDATA%\techVT` em Windows. Pode ser sobrescrito
/// pela env `TECHVT_DATA_DIR` (usada pelo modo headless e pelos testes de
/// integração com pasta temporária real — nunca um stub).
String defaultDataDir() {
  final override = Platform.environment['TECHVT_DATA_DIR'];
  if (override != null && override.isNotEmpty) return override;
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) return '$appData\\techVT';
    return '${_defaultHomeDir()}\\AppData\\Roaming\\techVT';
  }
  return '${_defaultHomeDir()}/.techVT';
}

String _defaultHomeDir() =>
    Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';

/// Configuração declarativa de um provedor LLM persistida em settings.json.
/// O segredo NÃO vive aqui: chega do secure storage no momento de construir
/// o [ProviderConfig] (arquivo em claro jamais contém api key).
class ProviderFileSpec {
  const ProviderFileSpec({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    this.wire = OpenAiCompatWire.chatCompletions,
    this.modelIds = const [],
    this.anthropicNative = false,
  });

  factory ProviderFileSpec.fromJson(Map<String, Object?> j) =>
      ProviderFileSpec(
        id: j['id'] as String,
        displayName: (j['displayName'] as String?) ?? (j['id'] as String),
        baseUrl: j['baseUrl'] as String,
        wire: OpenAiCompatWire.values.firstWhere(
          (w) => w.name == j['wire'],
          orElse: () => OpenAiCompatWire.chatCompletions,
        ),
        modelIds: ((j['modelIds'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        anthropicNative: (j['anthropicNative'] as bool?) ?? false,
      );

  final String id;
  final String displayName;
  final String baseUrl;
  final OpenAiCompatWire wire;
  final List<String> modelIds;

  /// true quando o endpoint fala o wire protocol Messages nativo da
  /// Anthropic (usa [AnthropicProvider]) em vez do formato OpenAI-compat.
  final bool anthropicNative;

  Map<String, Object?> toJson() => {
        'id': id,
        'displayName': displayName,
        'baseUrl': baseUrl,
        'wire': wire.name,
        'modelIds': modelIds,
        if (anthropicNative) 'anthropicNative': true,
      };
}

/// Settings reais persistidos em `<dataDir>/settings.json` (JSON em disco,
/// lidos de verdade — implementa o [SettingsGateway] que os tools consultam).
class FileSettings implements SettingsGateway {
  FileSettings._(this._values);

  static const fileName = 'settings.json';
  final Map<String, Object?> _values;

  static Future<FileSettings> load(String dataDir) async {
    final f = File('$dataDir/$fileName');
    if (!await f.exists()) return FileSettings._(const {});
    try {
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map<Object?, Object?>) {
        return FileSettings._(decoded.cast<String, Object?>());
      }
    } on FormatException {
      // JSON corrompido: settings vazios REAIS (nunca valores mockados).
    }
    return FileSettings._(const {});
  }

  static Future<void> save(
      String dataDir, Map<String, Object?> values) async {
    final f = File('$dataDir/$fileName');
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(values));
  }

  @override
  Object? get(String key, {String? workspaceId}) {
    // Hierarquia simples: workspace.<id>.<chave> sobrepõe <chave> global.
    if (workspaceId != null) {
      final ws = _values['workspace'];
      if (ws is Map) {
        final scope = ws[workspaceId];
        if (scope is Map && scope.containsKey(key)) return scope[key];
      }
    }
    return _values[key];
  }

  List<ProviderFileSpec> get providers =>
      ((_values['providers'] as List?) ?? const [])
          .whereType<Map<Object?, Object?>>()
          .map((e) => ProviderFileSpec.fromJson(e.cast<String, Object?>()))
          .toList();

  /// Lista de workspaces recentes (mais recente primeiro).
  List<String> get recentWorkspaces =>
      ((_values['recentWorkspaces'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
}

/// Abre (ou cria) o banco de dados local na pasta de dados.
Future<SqliteDb> openLocalDb(String dataDir) async {
  await Directory(dataDir).create(recursive: true);
  return SqliteNative.open("$dataDir/techvt.sqlite");
}

/// Registra TODAS as ferramentas reais disponíveis (15 FS + 15 Git + 3
/// checkpoint + 5 memória + 4 índice de código + 3 índice vetorial). A política
/// de aprovação continua sendo do contrato de cada tool (write/exec exigem
/// aprovação; reads são auto). [embedderResolver] pode retornar null (sem
/// provider de embeddings configurado) — as tools vectoriais degradam
/// honestamente.
ToolRegistry buildFullToolRegistry(SqliteDb db,
    {EmbeddingProvider? Function()? embedderResolver, String? dataDir}) {
  final memory = MemoryStore(db);
  final codeIndex = CodeIndexStore(db);
  final vectors = VectorIndexStore(db, codeIndex);
  final checkpoints = CheckpointStore(db, dataDir: dataDir ?? defaultDataDir());
  final resolve = embedderResolver ?? () => null;
  return ToolRegistry()
    // filesystem
    ..register(FsListTool())
    ..register(FsStatTool())
    ..register(FsReadTextTool())
    ..register(FsWriteTextTool())
    ..register(FsReadBytesTool())
    ..register(FsWriteBytesTool())
    ..register(FsCopyTool())
    ..register(FsMoveTool())
    ..register(FsRenameTool())
    ..register(FsCreateDirTool())
    ..register(FsGlobTool())
    ..register(FsSearchContentTool())
    ..register(FsChecksumTool())
    ..register(FsDeleteTrashTool())
    ..register(FsPermanentDeleteTool())
    // checkpoint (rollback pré/post-write real)
    ..register(CheckpointCreateTool(checkpoints))
    ..register(CheckpointListTool(checkpoints))
    ..register(CheckpointRestoreTool(checkpoints))
    // git
    ..register(GitStatusTool())
    ..register(GitDiffTool())
    ..register(GitLogTool())
    ..register(GitShowTool())
    ..register(GitBranchListTool())
    ..register(GitBranchCreateTool())
    ..register(GitBranchDeleteTool())
    ..register(GitCheckoutTool())
    ..register(GitStageTool())
    ..register(GitUnstageTool())
    ..register(GitCommitTool())
    ..register(GitPushTool())
    ..register(GitPullTool())
    ..register(GitFetchTool())
    ..register(GitStashTool())
    // memória persistente
    ..register(MemorySaveTool(memory))
    ..register(MemorySearchTool(memory))
    ..register(MemoryRecallTool(memory))
    ..register(MemoryStatsTool(memory))
    ..register(MemoryForgetTool(memory))
    // índice de código do workspace
    ..register(CodeIndexScanTool(codeIndex))
    ..register(CodeIndexSearchTool(codeIndex))
    ..register(CodeIndexStatsTool(codeIndex))
    ..register(CodeIndexPurgeTool(codeIndex))
    // índice vetorial / busca semântica (degrada p/ lexical sem embedder)
    ..register(CodeIndexEmbedTool(vectors, resolve))
    ..register(CodeIndexSemanticSearchTool(vectors, resolve))
    ..register(CodeIndexVectorStatsTool(vectors, resolve))
    // cadeia de desenvolvimento: pub / flutter / ci / release (binários reais;
    // health tipado degrada honestamente quando dart/flutter/git ausentes)
    ..register(PubGetTool())
    ..register(PubAddTool())
    ..register(PubOutdatedTool())
    ..register(FlutterDoctorTool())
    ..register(FlutterRunTool())
    ..register(FlutterBuildApkTool())
    ..register(FlutterBuildWebTool())
    ..register(FlutterTestTool())
    ..register(CiPipelineTriggerTool())
    ..register(ReleaseCreateTool())
    // qualidade & depuração: testes/cobertura/lint/reprodução/bisect REAIS +
    // sessões DAP reais (debug.*) e attach de VM Service real
    ..register(TestRunSuiteTool())
    ..register(TestGetCoverageTool())
    ..register(LintRunTool())
    ..register(BugReproduceTool())
    ..register(BugVerifyFixTool())
    ..register(BugBisectTool())
    ..register(DebugStartSessionTool())
    ..register(DebugSetBreakpointTool())
    ..register(DebugRemoveBreakpointTool())
    ..register(DebugStepTool('next', 'debug.step_over', 'Step over',
        'DAP next REAL na primeira thread viva; aguarda o próximo evento '
        'stopped do adapter e reporta arquivo:linha do topo da stack.'))
    ..register(DebugStepTool('stepIn', 'debug.step_into', 'Step into',
        'DAP stepIn REAL na primeira thread viva; aguarda parada e reporta '
        'posição resultante.'))
    ..register(DebugStepTool('stepOut', 'debug.step_out', 'Step out',
        'DAP stepOut REAL: sai da função atual e espera o evento stopped do '
        'adapter.'))
    ..register(DebugEvaluateExpressionTool())
    ..register(DebugGetStackTool())
    ..register(DebugGetVariablesTool())
    ..register(DebugAttachObservatoryTool());
}

/// Constrói o registro de provedores a partir das specs de settings.json +
/// chaves resolvidas do secure storage via [keyResolver]. Provedor sem chave
/// quando esperada também entra no registro: o health check tipado dele
/// (`api_key_missing`) é o mecanismo de diagnóstico — não filtramos em
/// silêncio.
Future<ProviderRegistry> buildProviders(
  List<ProviderFileSpec> specs,
  Future<String?> Function(String providerId) keyResolver,
) async {
  final registry = ProviderRegistry();
  for (final s in specs) {
    final key = await keyResolver(s.id) ?? '';
    final config = ProviderConfig(
      id: s.id,
      displayName: s.displayName,
      baseUrl: s.baseUrl,
      apiKey: key,
      modelIds: s.modelIds,
    );
    if (s.anthropicNative) {
      registry.register(AnthropicProvider(config));
    } else {
      registry.register(OpenAiCompatibleProvider(config, wire: s.wire));
    }
  }
  return registry;
}

/// Estado da composição root depois de aberta.
class VtApp {
  VtApp._({
    required this.dataDir,
    required this.workspaceRoots,
    required this.db,
    required this.memory,
    required this.checkpoints,
    required this.sandbox,
    required this.settings,
    required this.registry,
    required this.chat,
    required this.providerIds,
  });

  /// Monta a aplicação completa sobre um diretório de dados e raízes de
  /// workspace reais. [approvalGateway] vem da UI (diálogos de aprovação);
  /// no modo headless pode ficar null (tools não-auto falham com erro
  /// tipado em vez de executar escondido).
  static Future<VtApp> open({
    String? dataDir,
    required List<String> workspaceRoots,
    ApprovalGateway? approvalGateway,
    Future<String?> Function(String providerId)? keyResolver,
  }) async {
    final dir = dataDir ?? defaultDataDir();
    await Directory(dir).create(recursive: true);
    final tempDir = Directory('$dir/tmp')..createSync(recursive: true);

    final db = await openLocalDb(dir);
    final settings = await FileSettings.load(dir);
    final sandbox = WorkspaceSandbox(roots: workspaceRoots, tempDir: tempDir.path);
    final registry = buildFullToolRegistry(db, dataDir: dir);
    final providers = await buildProviders(
      settings.providers,
      keyResolver ?? (_) async => null,
    );
    final chat = ChatService(
      db: db,
      providers: providers,
      tools: registry,
      workspaceRoots: workspaceRoots,
      sandbox: sandbox,
      settings: settings,
      approvalGateway: approvalGateway,
    );

    return VtApp._(
      dataDir: dir,
      workspaceRoots: workspaceRoots,
      db: db,
      memory: MemoryStore(db),
      checkpoints: CheckpointStore(db, dataDir: dir),
      sandbox: sandbox,
      settings: settings,
      registry: registry,
      chat: chat,
      providerIds: providers.all.map((p) => p.id).toList(growable: false),
    );
  }

  final String dataDir;
  final List<String> workspaceRoots;
  final SqliteDb db;
  final MemoryStore memory;

  /// Rollback seguro: snapshots pré-write reais (bytes + SQLite).
  final CheckpointStore checkpoints;
  final WorkspaceSandbox sandbox;
  final FileSettings settings;
  final ToolRegistry registry;
  final ChatService chat;

  /// ids dos provedores registrados nesta sessão (segredos já resolvidos).
  final List<String> providerIds;

  void dispose() => db.close();
}
