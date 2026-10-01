/// Testes do tool loop REAL (spec §AGENTE: executing_tool → observing_result).
///
/// Sem mocks de comportamento: provider fake implementa o contrato emitindo
/// chunks reais; a tool escreve/lê disco de verdade via sandbox restrito ao
/// diretório temporário do teste; auditoria é lida de SQLite real.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:techvt/application/approval.dart';
import 'package:techvt/application/chat_service.dart';
import 'package:techvt/application/tool_registry.dart';
import 'package:techvt/domain/errors/vt_failure.dart';
import 'package:techvt/domain/tools/tool_contract.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/provider/provider_contract.dart';

// ---------------- Tool real: escrever arquivo no workspace ----------------

class _WriteFileInput extends ToolInput {
  const _WriteFileInput(this.path, this.content);
  final String path;
  final String content;
  @override
  Map<String, Object?> toJson() => {'path': path, 'content': content};
}

class _FsWriteTool extends VtTool<_WriteFileInput, TextOutput> {
  _FsWriteTool({this.approval = ApprovalPolicyMode.auto});

  final ApprovalPolicyMode approval;
  int executions = 0;

  @override
  String get id => 'fs.write_text';
  @override
  String get title => 'Write text file';
  @override
  String get description => 'Escreve um arquivo de texto no workspace.';
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ApprovalPolicyMode get defaultApproval => approval;
  @override
  Map<String, Object?> get inputSchema => {
        'type': 'object',
        'required': ['path', 'content'],
        'properties': {
          'path': {'type': 'string'},
          'content': {'type': 'string'},
        },
      };
  @override
  Map<String, Object?> get outputSchema => {
        'type': 'object',
        'properties': {'text': {'type': 'string'}}
      };
  @override
  bool get isIdempotent => true;
  @override
  Duration get timeout => const Duration(seconds: 5);
  @override
  RetryPolicy get retryPolicy => const RetryPolicy(maxAttempts: 1);
  @override
  List<String> get capabilities => const ['filesystem'];

  @override
  Future<ToolHealth> health(ToolContext ctx) async => const HealthOk();

  @override
  Future<_WriteFileInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return _WriteFileInput(raw['path'] as String, raw['content'] as String);
  }

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, _WriteFileInput input) async {
    // Sandbox valida ANTES de qualquer efeito colateral: nada toca o disco
    // se o path for rejeitado.
    final String resolved;
    try {
      resolved = await ctx.sandbox.resolveWritable(input.path, ctx);
    } on VtFailure catch (f) {
      return ToolFailureResult<TextOutput>(f);
    }
    executions++;
    final f = File(resolved);
    await f.create(recursive: true);
    await f.writeAsString(input.content);
    return ToolSuccess(
        data: TextOutput('wrote ${input.content.length} bytes',
            metadata: {'path': resolved}));
  }
}

// ---------------- Sandbox restrito à raiz do teste ----------------

class _RootSandbox implements SandboxGateway {
  const _RootSandbox(this.root);
  final String root;

  @override
  Future<String> resolveReadable(String rawPath, ToolContext ctx) async =>
      _resolve(rawPath);
  @override
  Future<String> resolveWritable(String rawPath, ToolContext ctx) async =>
      _resolve(rawPath);

  @override
  bool isAllowedDomain(String domain, ToolContext ctx) => false;

  String _resolve(String rawPath) {
    final p = rawPath.startsWith('/')
        ? rawPath
        : '$root/${rawPath.replaceFirst(RegExp(r'^\./'), '')}';
    final norm = Uri.file(p).normalizePath().toFilePath();
    if (!norm.startsWith(root)) {
      throw VtFailure.pathOutOfSandbox(rawPath);
    }
    return norm;
  }
}

class _NoSettings implements SettingsGateway {
  const _NoSettings();
  @override
  Object? get(String key, {String? workspaceId}) => null;
}

class _MapSettings implements SettingsGateway {
  const _MapSettings(this.values);
  final Map<String, Object?> values;
  @override
  Object? get(String key, {String? workspaceId}) => values[key];
}

// ---------------- Provider fake com roteiros REALMENTE emitidos ----------

class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider(this.turns);

  /// Cada turno: texto + tool calls que o modelo "emite" no stream.
  final List<_TurnScript> turns;
  final List<List<ChatRequestMessage>> receivedContexts = [];

  @override
  String get id => 'fake';
  @override
  String get displayName => 'Fake';
  @override
  List<ModelInfo> get models => [
        const ModelInfo(
          id: 'fake-model',
          providerId: 'fake',
          displayName: 'Fake Model',
          contextWindow: 8192,
          capabilities: ModelCapabilities(streaming: true, tools: true),
        ),
      ];

  @override
  Future<ProviderStatus> healthCheck() async => ProviderStatus.ok;
  @override
  Future<List<ModelInfo>> discoverModels() async => models;
  @override
  Future<ToolCompletionOutcome> completeForCompletion(
          {required String modelId,
          required String prefix,
          required String suffix}) async =>
      const ToolCompletionOutcome(text: '', modelId: 'fake-model');

  @override
  Stream<StreamChunk> streamChat({
    required String modelId,
    required List<ChatRequestMessage> messages,
    required ChatRequestOptions options,
    required List<Map<String, Object?>> toolSchemas,
    void Function(StreamHandle handle)? onHandle,
  }) {
    receivedContexts.add(List.of(messages));
    final turn = turns[receivedContexts.length - 1];
    final controller = StreamController<StreamChunk>();
    onHandle?.call(StreamHandle.noop());
    () async {
      for (final piece in turn.textPieces) {
        controller.add(DeltaChunk(piece));
        await Future<void>.delayed(Duration.zero);
      }
      for (final tc in turn.toolCalls) {
        controller.add(ToolCallStartChunk(
            callId: 'call_${turn.toolCalls.indexOf(tc)}',
            toolId: tc.$1,
            argsJson: jsonEncode(tc.$2)));
      }
      controller.add(const UsageChunk(promptTokens: 10, completionTokens: 4));
      controller.add(const DoneChunk("stop"));
      await controller.close();
    }();
    return controller.stream;
  }
}

class _TurnScript {
  const _TurnScript({this.textPieces = const [], this.toolCalls = const []});
  final List<String> textPieces;
  final List<(String, Map<String, Object?>)> toolCalls;
}

class _AutoApprove implements ApprovalGateway {
  int requests = 0;
  @override
  Future<ApprovalDecision> request(ApprovalRequest req) async {
    requests++;
    return const ApprovalDecision(ApprovalOutcome.approved);
  }
}

class _RejectApprove implements ApprovalGateway {
  @override
  Future<ApprovalDecision> request(ApprovalRequest req) async =>
      const ApprovalDecision(ApprovalOutcome.rejected, reason: 'não');
}

// ==========================================================================

void main() {
  late Directory tmp;
  late SqliteDb db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('techvt_toolloop_');
    db = SqliteNative.open('${tmp.path}/chat.db');
  });
  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  ChatService makeService(LlmProvider provider, VtTool<ToolInput, ToolOutput> tool,
      {ApprovalGateway? approval}) {
    final registry = ToolRegistry()..register(tool);
    final providers = ProviderRegistry()..register(provider);
    return ChatService(
      db: db,
      providers: providers,
      tools: registry,
      workspaceRoots: [tmp.path],
      sandbox: _RootSandbox(tmp.path),
      settings: const _NoSettings(),
      approvalGateway: approval,
    );
  }

  test('tool loop: modelo pede tool, tool executa de verdade, resultado volta',
      () async {
    final tool = _FsWriteTool();
    final provider = _ScriptedProvider([
      _TurnScript(toolCalls: [
        ('fs.write_text', {'path': 'out/hello.txt', 'content': 'olá mundo!'})
      ]),
      _TurnScript(textPieces: ['Arquivo criado com sucesso.']),
    ]);
    final svc = makeService(provider, tool);
    final convId = svc.createConversation(workspaceId: 'ws', title: 't');

    final states = <ConversationState>[];
    final sub = svc.states.listen((e) => states.add(e.$2));

    await svc.send(
      conversationId: convId,
      modelId: 'fake-model',
      userText: 'cria hello',
      context: const [],
    );
    await sub.cancel();

    // Tool executou de verdade: arquivo existe no disco com o conteúdo.
    final written = File('${tmp.path}/out/hello.txt');
    expect(written.existsSync(), isTrue);
    expect(await written.readAsString(), 'olá mundo!');
    expect(tool.executions, 1);

    // O resultado da tool voltou ao modelo no segundo turno (role: tool).
    expect(provider.receivedContexts.length, 2);
    final secondTurn = provider.receivedContexts[1];
    expect(secondTurn.last.role, 'tool');
    final toolResult =
        (jsonDecode(secondTurn.last.content) as Map).cast<String, Object?>();
    expect(toolResult["ok"], isTrue);

    // Estado final e persistência.
    expect(svc.stateOf(convId).runStatus, RunStatus.completed);
    expect(states.any((s) => s.toolOutcomes.values.contains(ToolCallStatus.succeeded)),
        isTrue);
    final page = svc.pageMessages(convId);
    // user + assistant(tool_calls) + tool result não é mensagem própria:
    // user + assistant com tool_call block + assistant final.
    final roles = page.items.map((m) => m.role).toList();
    expect(roles, ['user', 'assistant', 'assistant']);
    final blocks = page.items[1].blocks;
    expect(blocks.first['type'], 'tool_call');
    expect(blocks.first['status'], 'pending');

    // Auditoria real em SQLite.
    final audit = db.query(
        'SELECT tool_id, outcome, attempts FROM tool_audit WHERE conversation_id = ?',
        [convId]);
    expect(audit.single['tool_id'], 'fs.write_text');
    expect(audit.single['outcome'], 'succeeded');
    await svc.dispose();
  });

  test('aprovação exigida sem gateway: tool BLOQUEADA, nunca executa escondido',
      () async {
    final tool = _FsWriteTool(approval: ApprovalPolicyMode.reviewEach);
    final provider = _ScriptedProvider([
      _TurnScript(toolCalls: [
        ('fs.write_text', {'path': 'x.txt', 'content': 'y'})
      ]),
      _TurnScript(textPieces: ['ok, bloqueada.']),
    ]);
    final svc = makeService(provider, tool); // approval == null
    final convId = svc.createConversation(workspaceId: 'ws', title: 't');

    await svc.send(
        conversationId: convId,
        modelId: 'fake-model',
        userText: 'escreve',
        context: const []);

    expect(tool.executions, 0);
    expect(File('${tmp.path}/x.txt').existsSync(), isFalse);
    expect(svc.stateOf(convId).toolOutcomes.values,
        contains(ToolCallStatus.blocked));
    final audit = db.query('SELECT outcome, error_code FROM tool_audit');
    expect(audit.single['outcome'], 'blocked');
    expect(audit.single['error_code'], 'approval_required');
    await svc.dispose();
  });

  test('aprovação rejeitada pelo gateway: bloqueada + auditada', () async {
    final tool = _FsWriteTool(approval: ApprovalPolicyMode.reviewEach);
    final provider = _ScriptedProvider([
      _TurnScript(toolCalls: [
        ('fs.write_text', {'path': 'x.txt', 'content': 'y'})
      ]),
      _TurnScript(textPieces: ['entendido.']),
    ]);
    final svc = makeService(provider, tool, approval: _RejectApprove());
    final convId = svc.createConversation(workspaceId: 'ws', title: 't');

    await svc.send(
        conversationId: convId,
        modelId: 'fake-model',
        userText: 'escreve',
        context: const []);

    expect(tool.executions, 0);
    expect(db.query('SELECT outcome FROM tool_audit').single['outcome'],
        'blocked');
    await svc.dispose();
  });

  test('aprovação aceita pelo gateway: executa', () async {
    final tool = _FsWriteTool(approval: ApprovalPolicyMode.reviewEach);
    final gw = _AutoApprove();
    final provider = _ScriptedProvider([
      _TurnScript(toolCalls: [
        ('fs.write_text', {'path': 'a.txt', 'content': 'b'})
      ]),
      _TurnScript(textPieces: ['feito.']),
    ]);
    final svc = makeService(provider, tool, approval: gw);
    final convId = svc.createConversation(workspaceId: 'ws', title: 't');

    await svc.send(
        conversationId: convId,
        modelId: 'fake-model',
        userText: 'escreve',
        context: const []);

    expect(gw.requests, 1);
    expect(tool.executions, 1);
    expect(File('${tmp.path}/a.txt').existsSync(), isTrue);
    await svc.dispose();
  });

  test('sandbox nega path fora da raiz: falha tipada, nada toca o disco',
      () async {
    final tool = _FsWriteTool();
    final provider = _ScriptedProvider([
      _TurnScript(toolCalls: [
        ('fs.write_text', {'path': '/etc/evil.txt', 'content': 'pwn'})
      ]),
      _TurnScript(textPieces: ['sandbox bloqueou.']),
    ]);
    final svc = makeService(provider, tool);
    final convId = svc.createConversation(workspaceId: 'ws', title: 't');

    await svc.send(
        conversationId: convId,
        modelId: 'fake-model',
        userText: 'hack',
        context: const []);

    expect(tool.executions, 0);
    expect(File('/etc/evil.txt').existsSync(), isFalse);
    expect(svc.stateOf(convId).toolOutcomes.values,
        contains(ToolCallStatus.failed));
    final audit = db.query('SELECT outcome, error_code FROM tool_audit');
    expect(audit.single['outcome'], 'failed');
    expect(audit.single['error_code'], 'path_out_of_sandbox');
    await svc.dispose();
  });

  test('maxToolIterations limita runaway do agente', () async {
    // Modelo pede tool para sempre.
    final tool = _FsWriteTool();
    final scripts = [
      for (var i = 0; i < 20; i++)
        _TurnScript(toolCalls: [
          ('fs.write_text', {'path': 'loop$i.txt', 'content': '$i'})
        ]),
    ];
    final provider = _ScriptedProvider(scripts);
    final svc = ChatService(
      db: db,
      providers: ProviderRegistry()..register(provider),
      tools: ToolRegistry()..register(tool),
      workspaceRoots: [tmp.path],
      sandbox: _RootSandbox(tmp.path),
      settings: const _NoSettings(),
      maxToolIterations: 3,
    );
    final convId = svc.createConversation(workspaceId: 'ws', title: 't');

    await svc.send(
        conversationId: convId,
        modelId: 'fake-model',
        userText: 'loopa',
        context: const []);

    // iterações 0..3 executam tools, mas o 4º turno não executa mais.
    expect(provider.receivedContexts.length, 4);
    expect(tool.executions, 3);
    expect(svc.stateOf(convId).runStatus, RunStatus.completed);
    await svc.dispose();
  });

  // ---------------- System prompt do agente ----------------

  test('system prompt default é injetado como 1ª mensagem em todo turno',
      () async {
    final tool = _FsWriteTool();
    final provider = _ScriptedProvider([
      _TurnScript(toolCalls: [
        ('fs.write_text', {'path': 'sp.txt', 'content': 'x'})
      ]),
      _TurnScript(textPieces: ['ok']),
    ]);
    final svc = ChatService(
      db: db,
      providers: ProviderRegistry()..register(provider),
      tools: ToolRegistry()..register(tool),
      workspaceRoots: [tmp.path],
      sandbox: _RootSandbox(tmp.path),
      settings: const _NoSettings(),
    );
    final convId = svc.createConversation(workspaceId: 'ws', title: 't');

    await svc.send(
        conversationId: convId,
        modelId: 'fake-model',
        userText: 'escreve',
        context: const []);

    for (final turn in provider.receivedContexts) {
      expect(turn.first.role, 'system');
      expect(turn.first.content, kDefaultAgentSystemPrompt);
      expect(turn.first.content, contains('agent.plan.create'));
      expect(turn.first.content, contains('todo.list'));
    }
    await svc.dispose();
  });

  test('setting agentSystemPrompt tem precedência; vazio desativa; sem duplicar',
      () async {
    final provider = _ScriptedProvider([_TurnScript(textPieces: ['oi'])]);
    final svc = ChatService(
      db: db,
      providers: ProviderRegistry()..register(provider),
      settings: const _MapSettings({
        'agentSystemPrompt': 'PROMPT CUSTOMIZADO VIA SETTINGS',
      }),
    );
    final convId = svc.createConversation(workspaceId: 'ws', title: 't');
    await svc.send(
        conversationId: convId,
        modelId: 'fake-model',
        userText: 'olá',
        context: const []);
    expect(provider.receivedContexts.single.first.role, 'system');
    expect(provider.receivedContexts.single.first.content,
        'PROMPT CUSTOMIZADO VIA SETTINGS');
    await svc.dispose();

    // Contexto que já traz system não recebe segundo system (sem duplicata).
    final provider2 = _ScriptedProvider([_TurnScript(textPieces: ['oi'])]);
    final svc2 = ChatService(
      db: db,
      providers: ProviderRegistry()..register(provider2),
      settings: const _NoSettings(),
    );
    final convId2 = svc2.createConversation(workspaceId: 'ws', title: 't');
    await svc2.send(
        conversationId: convId2,
        modelId: 'fake-model',
        userText: 'olá',
        context: const [
          ChatRequestMessage(role: 'system', content: 'SYSTEM DO CALLER')
        ]);
    final msgs = provider2.receivedContexts.single;
    expect(msgs.where((m) => m.role == 'system').length, 1);
    expect(msgs.first.content, 'SYSTEM DO CALLER');
    await svc2.dispose();

    // systemPrompt = '' no serviço desativa a injeção.
    final provider3 = _ScriptedProvider([_TurnScript(textPieces: ['oi'])]);
    final svc3 = ChatService(
      db: db,
      providers: ProviderRegistry()..register(provider3),
      settings: const _NoSettings(),
      systemPrompt: '',
    );
    final convId3 = svc3.createConversation(workspaceId: 'ws', title: 't');
    await svc3.send(
        conversationId: convId3,
        modelId: 'fake-model',
        userText: 'olá',
        context: const []);
    expect(
        provider3.receivedContexts.single.every((m) => m.role != 'system'),
        isTrue);
    await svc3.dispose();
  });
}
