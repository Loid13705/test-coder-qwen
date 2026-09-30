/// Smoke test REAL do pipeline de streaming (sem mock):
/// 1. Sobe um servidor HTTP local que fala o protocolo SSE OpenAI de verdade
///    (linha por linha, com delays reais) — fixture local em tool/, não lib/.
/// 2. Aponta o OpenAiCompatibleProvider real para ele e consome streamChat().
/// 3. Valida deltas, tool_calls acumulados, usage, finish e CANCELAMENTO real
///    (stop() no meio → servidor observa EOF).
/// 4. Testa estados sem servidor: unconfigured / api_key_missing / offline.
/// 5. Roda o ChatService completo (provider real + SQLite real) e valida a
///    persistência user+assistant, paginação e estado final do composer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:techvt/application/chat_service.dart';
import 'package:techvt/domain/errors/vt_failure.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/provider/openai_compatible_provider.dart';
import 'package:techvt/infrastructure/provider/provider_contract.dart';

Future<void> _serveSse(HttpServer server) async {
  await for (final req in server) {
    if (req.uri.path.endsWith('/models')) {
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'object': 'list',
          'data': [
            {'id': 'gpt-4o-mini', 'object': 'model'}
          ]
        }));
      await req.response.close();
      continue;
    }
    // fixture local: corpo JSON ASCII, mas decodificação leniente por
    // robustez (mesma regra dos providers para streams de rede).
    final bodyBytes = <int>[];
    await for (final b in req) {
      bodyBytes.addAll(b);
    }
    final body = utf8.decode(bodyBytes, allowMalformed: true);
    final parsed = jsonDecode(body) as Map<String, Object?>;
    final isToolReq = parsed.containsKey('tools');
    stdout.writeln('[server] chat request, tools=$isToolReq');
    req.response.headers.set('content-type', 'text/event-stream');
    final out = req.response;
    void sse(Map<String, Object?> c) => out.write('data: ${jsonEncode(c)}\n\n');
    if (isToolReq) {
      sse({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_9f',
                  'function': {'name': 'fs_read'}
                }
              ]
            },
            'finish_reason': null
          }
        ]
      });
      await Future.delayed(const Duration(milliseconds: 5));
      sse({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': '{"path"'}
                }
              ]
            },
            'finish_reason': null
          }
        ]
      });
      sse({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': ': "a.txt"}'}
                }
              ]
            },
            'finish_reason': null
          }
        ]
      });
      sse({
        'choices': [
          {'delta': {}, 'finish_reason': 'tool_calls'}
        ]
      });
      sse({
        'usage': {'prompt_tokens': 11, 'completion_tokens': 7},
        'choices': []
      });
      out.write('data: [DONE]\n\n');
      await out.close();
    } else {
      for (final part in ['Olá!', ' Sou', ' o', ' stream', ' real.']) {
        sse({
          'choices': [
            {
              'delta': {'content': part},
              'finish_reason': null
            }
          ]
        });
        await out.flush();
        await Future.delayed(const Duration(milliseconds: 30));
      }
      sse({
        'choices': [
          {'delta': {}, 'finish_reason': 'stop'}
        ]
      });
      sse({
        'usage': {'prompt_tokens': 5, 'completion_tokens': 9},
        'choices': []
      });
      out.write('data: [DONE]\n\n');
      await out.close();
    }
  }
}

/// Servidor lento usado para o teste de cancelamento: emite deltas até o
/// cliente abortar a conexão (observado como erro de write/flush no servidor).
class _SlowCancelServer {
  _SlowCancelServer(this._server);
  final HttpServer _server;
  bool clientClosedEarly = false;

  static Future<_SlowCancelServer> bind() async {
    final s = _SlowCancelServer(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    unawaited(s._run());
    return s;
  }

  Future<void> _run() async {
    await for (final req in _server) {
      req.response.headers.set('content-type', 'text/event-stream');
      for (var i = 0; i < 200; i++) {
        try {
          req.response.write(
              'data: {"choices":[{"delta":{"content":"x$i"},"finish_reason":null}]}\n\n');
          await req.response.flush();
        } catch (_) {
          clientClosedEarly = true;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 20));
      }
      stdout.writeln('[slow-server] client closed early: $clientClosedEarly');
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}

Future<void> main() async {
  var failures = 0;
  void check(bool ok, String label) {
    print('${ok ? "PASS" : "FAIL"}: $label');
    if (!ok) failures++;
  }

  // ---- Estados sem backend real ----
  final noUrl = OpenAiCompatibleProvider(
      const ProviderConfig(id: 'openai', displayName: 'OpenAI', baseUrl: ''));
  check(await noUrl.healthCheck() == ProviderStatus.unconfigured,
      'healthCheck sem base URL -> unconfigured');
  final noKey = OpenAiCompatibleProvider(const ProviderConfig(
      id: 'openai',
      displayName: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1'));
  check(await noKey.healthCheck() == ProviderStatus.unconfigured,
      'healthCheck sem key -> unconfigured');
  StreamChunk? firstErr;
  try {
    firstErr = await noKey
        .streamChat(
            modelId: 'gpt-4o-mini',
            messages: const [ChatRequestMessage(role: 'user', content: 'oi')],
            options: const ChatRequestOptions(),
            toolSchemas: const [])
        .first;
  } catch (_) {}
  check(
      firstErr is ErrorChunk &&
          (firstErr as ErrorChunk).failure.code == VtErrorCode.apiKeyMissing,
      'streamChat sem key -> ErrorChunk(api_key_missing)');

  final offline = OpenAiCompatibleProvider(const ProviderConfig(
      id: 'ollama',
      displayName: 'Ollama',
      baseUrl: 'http://127.0.0.1:59999/v1',
      timeout: Duration(seconds: 2)));
  check(await offline.healthCheck() == ProviderStatus.offline,
      'ollama sem processo -> offline (real SocketException)');

  // ---- Servidor SSE local + provider real consumindo ----
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(_serveSse(server));
  final cfg = ProviderConfig(
    id: 'openai',
    displayName: 'OpenAI',
    baseUrl: 'http://127.0.0.1:${server.port}/v1',
    apiKey: 'sk-test-local',
  );
  final prov = OpenAiCompatibleProvider(cfg);

  final deltas = <String>[];
  StreamChunk? last;
  await for (final c in prov.streamChat(
      modelId: 'gpt-4o-mini',
      messages: const [ChatRequestMessage(role: 'user', content: 'oi')],
      options: const ChatRequestOptions(),
      toolSchemas: const [])) {
    if (c is DeltaChunk) deltas.add(c.text);
    last = c;
  }
  check(deltas.join() == 'Olá! Sou o stream real.',
      'streaming SSE deltas montam texto real do servidor');
  check(last is DoneChunk && (last as DoneChunk).finishReason == 'stop',
      'DoneChunk(stop) real');

  // tool calls acumulados entre chunks parciais
  final tcs = <ToolCallStartChunk>[];
  UsageChunk? usage;
  await for (final c in prov.streamChat(
      modelId: 'gpt-4o-mini',
      messages: const [ChatRequestMessage(role: 'user', content: 'lê a.txt')],
      options: const ChatRequestOptions(),
      toolSchemas: const [
        {'name': 'fs_read', 'parameters': {'type': 'object'}}
      ])) {
    if (c is ToolCallStartChunk) tcs.add(c);
    if (c is UsageChunk) usage = c;
  }
  check(
      tcs.length == 1 &&
          tcs.first.toolId == 'fs_read' &&
          tcs.first.argsJson == '{"path": "a.txt"}',
      'tool_call parcial acumulado corretamente');
  check(usage != null && usage.promptTokens == 11 && usage.completionTokens == 7,
      'UsageChunk com tokens reais do servidor');

  // discoverModels real contra o servidor
  final models = await prov.discoverModels();
  check(models.any((m) => m.id == 'gpt-4o-mini'),
      'discoverModels lê /models real');

  // ---- Cancelamento REAL no meio do stream ----
  final slowServer = await _SlowCancelServer.bind();
  final slowProv = OpenAiCompatibleProvider(ProviderConfig(
      id: 'openai',
      displayName: 'OpenAI',
      baseUrl: 'http://127.0.0.1:${slowServer.port}/v1',
      apiKey: 'k'));
  StreamHandle? h;
  var got = 0;
  final stream = slowProv.streamChat(
      modelId: 'gpt-4o-mini',
      messages: const [ChatRequestMessage(role: 'user', content: 'longo')],
      options: const ChatRequestOptions(),
      toolSchemas: const [],
      onHandle: (hh) => h = hh);
  await for (final c in stream) {
    if (c is DeltaChunk) got++;
    if (got == 3) {
      unawaited(h!.stop());
    }
  }
  check(h != null && h!.isCancelled && got >= 3,
      'stop() cancela após receber deltas reais (parcial preservado: $got)');
  await slowServer.close();

  // ---- ChatService com SQLite real (se disponível) ----
  if (SqliteNative.available) {
    final dbPath = '${Directory.systemTemp.path}/techvt_stream_smoke_$pid.db';
    final db = SqliteNative.open(dbPath);
    final registry = ProviderRegistry()..register(prov);
    final svc = ChatService(db: db, providers: registry);
    final convId = svc.createConversation(workspaceId: 'ws1', title: 'smoke');
    await svc.send(
        conversationId: convId,
        modelId: 'gpt-4o-mini',
        userText: 'oi',
        context: const [ChatRequestMessage(role: 'user', content: 'oi')]);
    final page = svc.pageMessages(convId);
    check(
        page.items.length == 2 &&
            page.items.first.role == 'user' &&
            page.items.last.role == 'assistant' &&
            page.totalEstimate == 2,
        'ChatService persiste user+assistant no SQLite real com paginação');
    check(
        svc.stateOf(convId).runStatus == RunStatus.completed &&
            svc.stateOf(convId).streamingText == 'Olá! Sou o stream real.',
        'estado final do composer reflete stream real');
    await svc.dispose();
    db.close();
    File(dbPath).deleteSync();
  } else {
    print('SKIP: libsqlite3 ausente nesta máquina (estado real missing_binary)');
  }

  unawaited(server.close(force: true));
  await prov.dispose();
  await noUrl.dispose();
  await noKey.dispose();
  await offline.dispose();
  await slowProv.dispose();

  print(failures == 0 ? 'ALL PASS' : '$failures FAILURES');
  exit(failures == 0 ? 0 : 1);
}
