import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:techvt/infrastructure/provider/openai_compatible_provider.dart';
import 'package:techvt/infrastructure/provider/provider_contract.dart';

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final req in server) {
      if (req.uri.path.endsWith('/models')) {
        req.response.write(jsonEncode({'object':'list','data':[{'id':'gpt-4o-mini'}]}));
        await req.response.close();
        continue;
      }
      await req.cast<List<int>>().transform(utf8.decoder).join(); // drain
      final out = req.response;
      out.headers.set('content-type', 'text/event-stream');
      void sse(Map<String, Object?> c) => out.write('data: ${jsonEncode(c)}\n\n');
      for (final part in ['Olá!', ' Sou', ' o', ' stream', ' real.']) {
        sse({'choices':[{'delta':{'content':part},'finish_reason':null}]});
        await out.flush();
        await Future.delayed(const Duration(milliseconds: 30));
      }
      sse({'choices':[{'delta':{},'finish_reason':'stop'}]});
      sse({'usage':{'prompt_tokens':5,'completion_tokens':9},'choices':[]});
      out.write('data: [DONE]\n\n');
      await out.close();
    }
  }());
  final prov = OpenAiCompatibleProvider(ProviderConfig(
      id: 'openai', displayName: 'OpenAI',
      baseUrl: 'http://127.0.0.1:${server.port}/v1', apiKey: 'sk-test'));
  print('--- run 1 ---');
  await for (final c in prov.streamChat(
      modelId: 'gpt-4o-mini',
      messages: const [ChatRequestMessage(role: 'user', content: 'oi')],
      options: const ChatRequestOptions(),
      toolSchemas: const [])) {
    print('${c.runtimeType}: ${c is DeltaChunk ? c.text : ''}');
  }
  print('--- run 2 (same provider) ---');
  await for (final c in prov.streamChat(
      modelId: 'gpt-4o-mini',
      messages: const [ChatRequestMessage(role: 'user', content: 'oi')],
      options: const ChatRequestOptions(),
      toolSchemas: const [])) {
    print('${c.runtimeType}: ${c is DeltaChunk ? c.text : ''}');
  }
  await prov.dispose();
  await server.close(force: true);
}
