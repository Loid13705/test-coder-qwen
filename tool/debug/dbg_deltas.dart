import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:techvt/infrastructure/provider/openai_compatible_provider.dart';
import 'package:techvt/infrastructure/provider/provider_contract.dart';

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final req in server) {
      await for (final _ in req) {}
      req.response.headers.set('content-type', 'text/event-stream');
      final out = req.response;
      for (final part in ['Olá!', ' Sou', ' o', ' stream', ' real.']) {
        out.write('data: ${jsonEncode({'choices': [
          {'delta': {'content': part}, 'finish_reason': null}
        ]})}\n\n');
        await out.flush();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      out.write('data: [DONE]\n\n');
      await out.close();
    }
  }());
  final cfg = ProviderConfig(
      id: 'openai',
      displayName: 'OpenAI',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'sk-test-local');
  final prov = OpenAiCompatibleProvider(cfg);
  final deltas = <String>[];
  await for (final c in prov.streamChat(
      modelId: 'gpt-4o-mini',
      messages: const [ChatRequestMessage(role: 'user', content: 'oi')],
      options: const ChatRequestOptions(),
      toolSchemas: const [])) {
    if (c is DeltaChunk) {
      deltas.add(c.text);
      stdout.writeln('DELTA bytes=${c.text.codeUnits} repr=${jsonEncode(c.text)}');
    } else {
      stdout.writeln('CHUNK $c');
    }
  }
  stdout.writeln('joined=${jsonEncode(deltas.join())}');
  stdout.writeln('expected=${jsonEncode('Olá! Sou o stream real.')}');
  await prov.dispose();
  await server.close(force: true);
}
