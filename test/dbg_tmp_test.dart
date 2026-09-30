import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:techvt/infrastructure/provider/openai_compatible_provider.dart';
import 'package:techvt/infrastructure/provider/provider_contract.dart';

void main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    await utf8.decoder.bind(req).join();
    req.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
    req.response.write('data: {"choices":[{"delta":{"content":"Ol\u00e1"},"finish_reason":null}]}\n\n');
    req.response.write('data: {"choices":[{"delta":{"content":" mundo"},"finish_reason":null}]}\n\n');
    req.response.write('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n');
    req.response.write('data: [DONE]\n\n');
    await req.response.close();
  });
  final p = OpenAiCompatibleProvider(ProviderConfig(
    id: 'custom', displayName: 'Test', baseUrl: 'http://127.0.0.1:${server.port}/v1',
    apiKey: 'sk-test', modelIds: const ['gpt-4o-mini'],
  ));
  try {
    final chunks = await p.streamChat(
      modelId: 'gpt-4o-mini',
      messages: const [ChatRequestMessage(role: 'user', content: 'oi')],
      options: const ChatRequestOptions(),
      toolSchemas: const [],
    ).toList().timeout(const Duration(seconds: 5), onTimeout: () { print('TIMEOUT'); return []; });
    print('chunks: $chunks');
  } catch (e, st) {
    print('ERROR: $e\n$st');
  }
  await p.dispose();
  await server.close(force: true);
}
