import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:techvt/application/chat_service.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/provider/openai_compatible_provider.dart';
import 'package:techvt/infrastructure/provider/provider_contract.dart';

// servidor SSE com deltas em "Olá! Sou o stream real." + usage + [DONE]
Future<(HttpServer, int)> startSse() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final req in server) {
      if (req.uri.path.endsWith('/models')) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'data': [
            {'id': 'gpt-4o-mini'}
          ]
        }));
        await req.response.close();
        continue;
      }
      final body = await utf8.decoder.bind(req).join();
      final useTools = body.contains('"tools"');
      print('[server] chat request, tools=$useTools');
      req.response.bufferOutput = false;
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      const full = 'Olá! Sou o stream real.';
      for (var i = 0; i < full.length; i += 4) {
        final piece = full.substring(i, (i + 4).clamp(0, full.length));
        req.response.write(
            'data: ${jsonEncode({"choices": [{"delta": {"content": piece}}]})}\n\n'
                .replaceAll('piece', jsonEncode(piece)));
        await req.response.flush();
        await Future.delayed(const Duration(milliseconds: 30));
      }
      req.response.write(
          'data: ${jsonEncode({"choices": [{"delta": {}, "finish_reason": "stop"}]})}\n\n');
      req.response.write(
          'data: ${jsonEncode({"choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 7}})}\n\n');
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
    }
  }());
  return (server, server.port);
}

Future<void> main() async {
  final (server, port) = await startSse();
  final base = 'http://127.0.0.1:$port/v1';
  final prov = OpenAiCompatibleProvider(ProviderConfig(
      id: 'openai', displayName: 'test', baseUrl: base, apiKey: 'k'));
  final dbPath = '/tmp/repro_chat_${pid}.db';
  final db = SqliteNative.open(dbPath);
  print('db open ok');
  final registry = ProviderRegistry()..register(prov);
  final svc = ChatService(db: db, providers: registry);
  print('svc created');
  final convId = svc.createConversation(workspaceId: 'ws1', title: 'smoke');
  print('conv created: $convId');
  await svc.send(
      conversationId: convId,
      modelId: 'gpt-4o-mini',
      userText: 'oi',
      context: const [ChatRequestMessage(role: 'user', content: 'oi')]);
  print('send done');
  final page = svc.pageMessages(convId);
  print('page items=${page.items.length} first=${page.items.first.role} last=${page.items.last.role}');
  await svc.dispose();
  db.close();
  await server.close(force: true);
  await prov.dispose();
  File(dbPath).deleteSync();
  print('DONE');
}
