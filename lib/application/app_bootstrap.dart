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

import '../domain/models/pagination.dart';
import '../domain/net_access.dart';
import '../domain/tools/tool_contract.dart';
import '../infrastructure/agent/agent_state_store.dart';
import '../infrastructure/agent/agent_tools.dart';
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
import '../infrastructure/web/web_tools.dart';
import '../infrastructure/provider/anthropic_provider.dart';
import '../infrastructure/provider/openai_compatible_provider.dart';
import '../infrastructure/provider/provider_contract.dart';
import '../infrastructure/runtime/local_llama_runtime.dart';
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
    this.timeoutSeconds,
    this.proxyUrl,
    this.proxyDirect = false,
    this.sslVerification = true,
    this.organization,
    this.headers = const {},
    this.retryMaxAttempts,
    this.retryBackoffMs,
    this.fallbackChain = const [],
    this.capabilityOverrides = const {},
    this.generation = const GenerationDefaults(),
  });

  factory ProviderFileSpec.fromJson(Map<String, Object?> j) {
    final caps = <String, CapabilityOverride>{};
    final rawCaps = j['capabilityOverrides'];
    if (rawCaps is Map) {
      rawCaps.cast<String, Object?>().forEach((modelId, v) {
        if (v is! Map) return;
        final m = v.cast<String, Object?>();
        caps[modelId] = CapabilityOverride(
          tools: m['tools'] as bool?,
          vision: m['vision'] as bool?,
          streaming: m['streaming'] as bool?,
          jsonMode: m['jsonMode'] as bool?,
          contextWindow: (m['contextWindow'] as num?)?.toInt(),
        );
      });
    }
    final hdrs = <String, String>{};
    final rawHdrs = j['headers'];
    if (rawHdrs is Map) {
      rawHdrs.forEach((k, v) => hdrs[k.toString()] = v.toString());
    }
    final genRaw = j['generation'];
    final gen = genRaw is Map ? genRaw.cast<String, Object?>() : null;
    return ProviderFileSpec(
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
      timeoutSeconds: (j['timeoutSeconds'] as num?)?.toInt(),
      proxyUrl: (j['proxyUrl'] as String?)?.trim(),
      proxyDirect: (j['proxyDirect'] as bool?) ?? false,
      sslVerification: (j['sslVerification'] as bool?) ?? true,
      organization: (j['organization'] as String?)?.trim(),
      headers: hdrs,
      retryMaxAttempts: (j['retryMaxAttempts'] as num?)?.toInt(),
      retryBackoffMs: (j['retryBackoffMs'] as num?)?.toInt(),
      fallbackChain: ((j['fallbackChain'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      capabilityOverrides: caps,
      generation: GenerationDefaults(
        temperature: (gen?['temperature'] as num?)?.toDouble(),
        topP: (gen?['topP'] as num?)?.toDouble(),
        maxTokens: (gen?['maxTokens'] as num?)?.toInt(),
        seed: (gen?['seed'] as num?)?.toInt(),
        stopSequences: ((gen?['stopSequences'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      ),
    );
  }

  final String id;
  final String displayName;
  final String baseUrl;
  final OpenAiCompatWire wire;
  final List<String> modelIds;

  /// true quando o endpoint fala o wire protocol Messages nativo da
  /// Anthropic (usa [AnthropicProvider]) em vez do formato OpenAI-compat.
  final bool anthropicNative;

  // --- campos avançados (§SETTINGS AI Providers) -------------------------
  final int? timeoutSeconds;
  final String? proxyUrl;
  final bool proxyDirect;
  final bool sslVerification;
  final String? organization;
  final Map<String, String> headers;
  final int? retryMaxAttempts;
  final int? retryBackoffMs;

  /// ids de providers alternativos tentados quando este falha por motivo
  /// transitório (rate limit/timeout/offline). Persistido; aplicado pelo
  /// ChatService antes de declarar bloqueio.
  final List<String> fallbackChain;
  final Map<String, CapabilityOverride> capabilityOverrides;
  final GenerationDefaults generation;

  Map<String, Object?> toJson() => {
        'id': id,
        'displayName': displayName,
        'baseUrl': baseUrl,
        'wire': wire.name,
        'modelIds': modelIds,
        if (anthropicNative) 'anthropicNative': true,
        if (timeoutSeconds != null) 'timeoutSeconds': timeoutSeconds,
        if (proxyUrl != null && proxyUrl!.isNotEmpty) 'proxyUrl': proxyUrl,
        if (proxyDirect) 'proxyDirect': true,
        if (!sslVerification) 'sslVerification': false,
        if (organization != null && organization!.isNotEmpty)
          'organization': organization,
        if (headers.isNotEmpty) 'headers': headers,
        if (retryMaxAttempts != null) 'retryMaxAttempts': retryMaxAttempts,
        if (retryBackoffMs != null) 'retryBackoffMs': retryBackoffMs,
        if (fallbackChain.isNotEmpty) 'fallbackChain': fallbackChain,
        if (capabilityOverrides.isNotEmpty)
          'capabilityOverrides': {
            for (final e in capabilityOverrides.entries)
              e.key: {
                if (e.value.tools != null) 'tools': e.value.tools,
                if (e.value.vision != null) 'vision': e.value.vision,
                if (e.value.streaming != null) 'streaming': e.value.streaming,
                if (e.value.jsonMode != null) 'jsonMode': e.value.jsonMode,
                if (e.value.contextWindow != null)
                  'contextWindow': e.value.contextWindow,
              },
          },
        if (!generation.isEmpty)
          'generation': {
            if (generation.temperature != null)
              'temperature': generation.temperature,
            if (generation.topP != null) 'topP': generation.topP,
            if (generation.maxTokens != null)
              'maxTokens': generation.maxTokens,
            if (generation.seed != null) 'seed': generation.seed,
            if (generation.stopSequences.isNotEmpty)
              'stopSequences': generation.stopSequences,
          },
      };
}

/// Defaults de geração persistidos por provider (aplicados quando o request
/// não traz valor explícito — nunca inventados pelo app).
class GenerationDefaults {
  const GenerationDefaults({
    this.temperature,
    this.topP,
    this.maxTokens,
    this.seed,
    this.stopSequences = const [],
  });

  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final int? seed;
  final List<String> stopSequences;

  bool get isEmpty =>
      temperature == null &&
      topP == null &&
      maxTokens == null &&
      seed == null &&
      stopSequences.isEmpty;
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

  int? _intAt(String key) {
    final v = get(key);
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  double? _doubleAt(String key) {
    final v = get(key);
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  /// Limites REAIS do tool loop, lidos de settings.json. Null = sem limite.
  /// Chaves: `maxToolSteps` (passos por envio), `maxCostUsd` (custo acumulado
  /// em USD estimado pela cost table do modelo), `stepTimeoutSeconds`
  /// (timeout global por execução de tool quando a tool não declara um menor).
  int? get maxToolSteps => _intAt('maxToolSteps');
  double? get maxCostUsd => _doubleAt('maxCostUsd');
  int? get stepTimeoutSeconds => _intAt('stepTimeoutSeconds');

  /// Toggle global de internet (`internetEnabled`). Ausente = ligado.
  bool get internetEnabled {
    final v = get('internetEnabled');
    return v is! bool || v;
  }

  /// Page size persistido por superfície (§PAGINAÇÃO GLOBAL). Chaves:
  /// `pagination.chatPageSize` (50), `pagination.searchPageSize` (50),
  /// `pagination.logsPageSize` (100), `pagination.toolCatalogPageSize` (30),
  /// `pagination.gitLogPageSize` (50). Valores fora de kVtPageSizes são
  /// ignorados (retorna o default da superfície, nunca um número inválido).
  int pageSizeFor(String key, int fallbackDefault) {
    final v = _intAt(key);
    if (v == null) return fallbackDefault;
    return kVtPageSizes.contains(v) ? v : fallbackDefault;
  }

  int get chatPageSize =>
      pageSizeFor('pagination.chatPageSize', kDefaultPageSizeChat);
  int get searchPageSize =>
      pageSizeFor('pagination.searchPageSize', kDefaultPageSizeSearch);
  int get logsPageSize =>
      pageSizeFor('pagination.logsPageSize', kDefaultPageSizeLogs);
  int get toolCatalogPageSize => pageSizeFor(
      'pagination.toolCatalogPageSize', kDefaultPageSizeToolCatalog);
  int get gitLogPageSize =>
      pageSizeFor('pagination.gitLogPageSize', kDefaultPageSizeGitLog);

  /// Infinite scroll on/off (default: ligado, como na spec de UX).
  bool get infiniteScrollEnabled {
    final v = get('infiniteScroll');
    return v is! bool || v;
  }

  /// Postura de aprovação global persistida (`approvalPosture`). Retorna o
  /// nome normalizado ('manual' | 'autoSafe' | 'autoAll') ou null quando a
  /// política deve ser a pura do contrato de cada tool.
  String? get approvalPostureName {
    final v = get('approvalPosture');
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }
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
  final agentState = AgentStateStore(db);
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
    ..register(DebugStartSessionTool(null))
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
    ..register(DebugAttachObservatoryTool())
    // web: busca/fetch/extração/citação/robots/sitemap REAIS (HttpClient)
    ..register(WebSearchTool())
    ..register(WebNewsSearchTool())
    ..register(WebImageSearchTool())
    ..register(WebDocSearchTool())
    ..register(WebCodeSearchTool())
    ..register(WebFetchPageTool())
    ..register(WebExtractArticleTool())
    ..register(WebCitationFormatTool())
    ..register(WebRobotsCheckTool())
    ..register(WebSitemapQueryTool())
    // operação do agente (agent.* + todo.list): plano, tarefas com audit
    // trail, reflexão, esclarecimento, resumo citado, compactação preservando
    // originais e pedidos de aprovação — tudo persistido em SQLite real
    ..register(AgentPlanCreateTool(agentState))
    ..register(AgentPlanUpdateTool(agentState))
    ..register(AgentTaskStartTool(agentState))
    ..register(AgentTaskCompleteTool(agentState))
    ..register(AgentReflectEvaluateTool(agentState))
    ..register(AgentClarifyTool(agentState))
    ..register(AgentContextSummarizeTool(agentState))
    ..register(AgentHistoryCompactTool(agentState))
    ..register(AgentApprovalRequestTool(agentState))
    ..register(TodoListTool(agentState));
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
