/// Testes do provider OpenAI-compatible com servidor HTTP LOCAL REAL.
///
/// Não é mock da aplicação: sobe um `HttpServer` de verdade no loopback que
/// responde SSE byte-a-byte como um endpoint OpenAI-compatível faria. O código
/// de produção (`OpenAiCompatibleProvider`) executa integralmente — sockets,
/// parsing SSE, acumulação de tool_calls, cancelamento e redação de secrets.
/// Este arquivo vive em /test, onde fixtures determinísticos são permitidos.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:techvt/domain/errors/vt_failure.dart';
import 'package:techvt/infrastructure/provider/openai_compatible_provider.dart';
import 'package:techvt/infrastructure/provider/provider_contract.dart';

Future<({HttpServer server, List<String> requests})> _startServer(
    FutureOr<void> Function(HttpRequest req) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <String>[];
  server.listen((req) async {
    // Decodificação leniente: o corpo contém acentos UTF-8 e os chunks TCP
    // podem partir sequências multi-byte ao meio — allowMalformed no join
    // final é a forma correta (a armadilha de chunked só vale p/ streaming).
    final body = await req
        .map<List<int>>((c) => c)
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    requests.add(body);
    try {
      await handler(req);
    } catch (_) {
      // cliente desconectou (cancelamento) — ignora
    }
  }, onError: (Object _) {
    // requisição abortada pelo cliente durante leitura — real em stop()
  });
  return (server: server, requests: requests);
}

String _sse(List<Map<String, Object?>> deltas) {
  final sb = StringBuffer();
  for (final d in deltas) {
    sb.write('data: ${jsonEncode(d)}\n\n');
  }
  sb.write('data: [DONE]\n\n');
  return sb.toString();
}

Map<String, Object?> _chunkDelta(String content) => {
      'choices': [
        {
          'delta': {'content': content},
          'finish_reason': null,
        }
      ],
    };

void main() {
  group('preflight (sem conexão fingida)', () {
    test('sem base URL -> provider_not_configured', () async {
      final p = OpenAiCompatibleProvider(ProviderConfig(
        id: 'custom',
        displayName: 'Custom',
        baseUrl: '',
        apiKey: 'sk-test',
      ));
      final chunks = await p
          .streamChat(
            modelId: 'gpt-4o-mini',
            messages: const [
              ChatRequestMessage(role: 'user', content: 'oi')
            ],
            options: const ChatRequestOptions(),
            toolSchemas: const [],
          )
          .toList();
      expect(chunks, hasLength(1));
      final err = chunks.single as ErrorChunk;
      expect(err.failure.code, VtErrorCode.providerNotConfigured);
      expect(err.failure.setupUri, isNotNull);
      await p.dispose();
    });

    test('sem API key em provider remoto -> unconfigured', () async {
      final p = OpenAiCompatibleProvider(ProviderConfig(
        id: 'openai',
        displayName: 'OpenAI',
        baseUrl: 'https://api.invalid.techvt.test/v1',
      ));
      final status = await p.healthCheck();
      expect(status, ProviderStatus.unconfigured);
      await p.dispose();
    });

    test('endpoint local inalcançável -> offline (estado real)', () async {
      // Porta fechada de verdade no loopback.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final p = OpenAiCompatibleProvider(ProviderConfig(
        id: 'ollama',
        displayName: 'Ollama',
        baseUrl: 'http://127.0.0.1:$port/v1',
      ));
      final status = await p.healthCheck();
      expect(status, ProviderStatus.offline);
      await p.dispose();
    });
  });

  group('streamChat contra servidor SSE real', () {
    late ({HttpServer server, List<String> requests}) s;
    late OpenAiCompatibleProvider provider;

    Future<void> respondStop(HttpRequest req) async {
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.write(_sse([
        _chunkDelta('Olá'),
        _chunkDelta(' mundo'),
        {
          'choices': [
            <String, Object?>{
              'delta': <String, Object?>{},
              'finish_reason': 'stop',
            }
          ]
        },
      ]));
      await req.response.close();
    }

    /// Sobe um servidor novo por handler — sem estado compartilhado entre
    /// testes, determinístico.
    Future<void> start(Future<void> Function(HttpRequest) h) async {
      s = await _startServer(h);
      provider = OpenAiCompatibleProvider(ProviderConfig(
        id: 'custom',
        displayName: 'Test Local',
        baseUrl: 'http://127.0.0.1:${s.server.port}/v1',
        apiKey: 'sk-local-test',
        modelIds: const ['gpt-4o-mini'],
      ));
    }

    tearDown(() async {
      await provider.dispose();
      await s.server.close(force: true);
    });

    test('recebe deltas reais na ordem e DoneChunk(stop)', () async {
      await start(respondStop);
      final chunks = await provider
          .streamChat(
            modelId: 'gpt-4o-mini',
            messages: const [
              ChatRequestMessage(role: 'user', content: 'diga olá mundo')
            ],
            options: const ChatRequestOptions(maxTokens: 64),
            toolSchemas: const [],
          )
          .toList();
      final text = chunks.whereType<DeltaChunk>().map((c) => c.text).join();
      expect(text, 'Olá mundo');
      expect(chunks.last, isA<DoneChunk>());
      expect((chunks.last as DoneChunk).finishReason, 'stop');
      // O request real levado ao servidor contém o corpo correto:
      expect(s.requests.single, contains('"model":"gpt-4o-mini"'));
      expect(s.requests.single, contains('"max_tokens":64'));
      expect(s.requests.single, contains('"stream":true'));
    });

    test('tool_calls fragmentados são acumulados e normalizados p/ toolId',
        () async {
      await start((req) async {
        req.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        req.response.write(_sse([
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_abc',
                      // provedores locais frequentemente devolvem o nome
                      // com underscores (não aceitam '.' em function names):
                      'function': {
                        'name': 'fs_read_text', 'arguments': '{"pa'
                      }
                    }
                  ]
                },
                'finish_reason': null,
              }
            ]
          },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': 'th":"x"}'}
                    }
                  ]
                },
                'finish_reason': 'tool_calls',
              }
            ]
          },
        ]));
        await req.response.close();
      });
      final chunks = await provider
          .streamChat(
            modelId: 'gpt-4o-mini',
            messages: const [
              ChatRequestMessage(role: 'user', content: 'leia x')
            ],
            options: const ChatRequestOptions(),
            toolSchemas: const [
              {'name': 'fs.read_text', 'parameters': <String, Object?>{}}
            ],
          )
          .toList();
      final tc = chunks.whereType<ToolCallStartChunk>().single;
      expect(tc.callId, 'call_abc');
      expect(tc.toolId, 'fs.read_text');
      expect(jsonDecode(tc.argsJson), {'path': 'x'});
      expect(chunks.last, isA<DoneChunk>());
    });

    test('HTTP 401 -> ErrorChunk api_key_missing com body redigido', () async {
      await start((req) async {
        req.response.statusCode = 401;
        req.response.write(
            '{"error":{"message":"bad key sk-shouldberedacted0987654321abcdef"}}');
        await req.response.close();
      });
      final chunks = await provider
          .streamChat(
            modelId: 'gpt-4o-mini',
            messages: const [
              ChatRequestMessage(role: 'user', content: 'oi')
            ],
            options: const ChatRequestOptions(),
            toolSchemas: const [],
          )
          .toList();
      final err = chunks.single as ErrorChunk;
      expect(err.failure.code, VtErrorCode.apiKeyMissing);
      expect(err.failure.message, contains('[REDACTED'));
      expect(err.failure.message,
          isNot(contains('sk-shouldberedacted0987654321abcdef')));
    });

    test('HTTP 429 -> rate_limited', () async {
      await start((req) async {
        req.response.statusCode = 429;
        req.response.write('{"error":"slow down"}');
        await req.response.close();
      });
      final chunks = await provider
          .streamChat(
            modelId: 'gpt-4o-mini',
            messages: const [
              ChatRequestMessage(role: 'user', content: 'oi')
            ],
            options: const ChatRequestOptions(),
            toolSchemas: const [],
          )
          .toList();
      expect(
          (chunks.single as ErrorChunk).failure.code, VtErrorCode.rateLimited);
    });

    test('usage chunk real é propagado', () async {
      await start((req) async {
        req.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        req.response.write(_sse([
          _chunkDelta('ok'),
          {
            'usage': {'prompt_tokens': 11, 'completion_tokens': 7},
            'choices': <Object?>[],
          },
          {
            'choices': [
              {
                'delta': <String, Object?>{},
                'finish_reason': 'stop',
              }
            ]
          },
        ]));
        await req.response.close();
      });
      final chunks = await provider
          .streamChat(
            modelId: 'gpt-4o-mini',
            messages: const [
              ChatRequestMessage(role: 'user', content: 'oi')
            ],
            options: const ChatRequestOptions(),
            toolSchemas: const [],
          )
          .toList();
      final usage = chunks.whereType<UsageChunk>().single;
      expect(usage.promptTokens, 11);
      expect(usage.completionTokens, 7);
    });
  });

  group('descoberta e capacidades', () {
    test(
        'discoverModels cruza ids reais com catálogo; desconhecidos ficam disabled',
        () async {
      final s = await _startServer((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'data': [
            {'id': 'gpt-4o-mini'},
            {'id': 'modelo-misterioso-v9'},
          ]
        }));
        await req.response.close();
      });
      final provider = OpenAiCompatibleProvider(ProviderConfig(
        id: 'custom',
        displayName: 'Test Local',
        baseUrl: 'http://127.0.0.1:${s.server.port}/v1',
        apiKey: 'sk-local-test',
      ));
      final models = await provider.discoverModels();
      final known = models.firstWhere((m) => m.id == 'gpt-4o-mini');
      expect(known.enabled, isTrue);
      final unknown = models.firstWhere((m) => m.id == 'modelo-misterioso-v9');
      // Capacidades desconhecidas NUNCA são presumidas:
      expect(unknown.enabled, isFalse);
      expect(unknown.capabilities.tools, isFalse);
      expect(unknown.capabilities.vision, isFalse);
      await provider.dispose();
      await s.server.close(force: true);
    });

    test('modelo local sem suporte a tools -> model_does_not_support_tools',
        () async {
      // A guarda de capacidades roda ANTES de qualquer requisição de rede;
      // ollama não tem API key exigida (isLocal), então o preflight passa.
      final provider = OpenAiCompatibleProvider(ProviderConfig(
        id: 'ollama',
        displayName: 'Ollama',
        baseUrl: 'http://127.0.0.1:1/v1',
        modelIds: ['llama3.1:8b'],
      ));
      final chunks = await provider
          .streamChat(
            modelId: 'llama3.1:8b',
            messages: const [
              ChatRequestMessage(role: 'user', content: 'oi')
            ],
            options: const ChatRequestOptions(),
            toolSchemas: const [
              {'name': 'fs.read_text', 'parameters': <String, Object?>{}}
            ],
          )
          .toList();
      final err = chunks.single as ErrorChunk;
      expect(err.failure.code, VtErrorCode.modelDoesNotSupportTools);
      await provider.dispose();
    });

    test('capability override confirmado pelo usuário habilita tools',
        () async {
      final provider = OpenAiCompatibleProvider(ProviderConfig(
        id: 'ollama',
        displayName: 'Ollama',
        baseUrl: 'http://127.0.0.1:1/v1',
        modelIds: ['qwen2.5-coder:7b'],
        capabilityOverrides: {
          'qwen2.5-coder:7b': CapabilityOverride(tools: true),
        },
      ));
      final m =
          provider.models.singleWhere((m) => m.id == 'qwen2.5-coder:7b');
      expect(m.capabilities.tools, isTrue);
      await provider.dispose();
    });

    test('override negativo desabilita capacidade do catálogo', () async {
      final provider = OpenAiCompatibleProvider(ProviderConfig(
        id: 'openai',
        displayName: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-x',
        modelIds: ['gpt-4o'],
        capabilityOverrides: {
          'gpt-4o': CapabilityOverride(vision: false),
        },
      ));
      final m = provider.models.singleWhere((m) => m.id == 'gpt-4o');
      expect(m.capabilities.vision, isFalse);
      expect(m.capabilities.tools, isTrue); // não sobrescrito
      await provider.dispose();
    });
  });

  group('wire protocols alternativos (gateways/proxies)', () {
    test('anthropicMessages: parseia envelope SSE nativo via gateway',
        () async {
      final (server: server, requests: requests) = await _startServer((req) async {
        req.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        String ev(Map<String, Object?> m) => 'data: ${jsonEncode(m)}\n\n';
        req.response.write(ev({
          'type': 'message_start',
          'message': {'id': 'msg_1', 'usage': {'input_tokens': 7}}
        }));
        req.response.write(ev({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''}
        }));
        req.response.write(ev({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'Olá '}
        }));
        req.response.write(ev({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'mundo!'}
        }));
        req.response.write(ev({'type': 'content_block_stop', 'index': 0}));
        req.response.write(ev({
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 5}
        }));
        req.response.write(ev({'type': 'message_stop'}));
        await req.response.close();
      });
      final provider = OpenAiCompatibleProvider(
        ProviderConfig(
          id: 'gateway',
          displayName: 'Anthropic Gateway',
          baseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'sk-gw',
          modelIds: ['claude-sonnet-4-20250514'],
        ),
        wire: OpenAiCompatWire.anthropicMessages,
      );
      final chunks = await provider
          .streamChat(
            modelId: 'claude-sonnet-4-20250514',
            messages: const [
              ChatRequestMessage(role: 'system', content: 'sys'),
              ChatRequestMessage(role: 'user', content: 'oi'),
            ],
            options: const ChatRequestOptions(),
            toolSchemas: const [],
          )
          .toList();
      final text = chunks.whereType<DeltaChunk>().map((c) => c.text).join();
      expect(text, 'Olá mundo!');
      final usage = chunks.whereType<UsageChunk>().toList();
      expect(usage.last.completionTokens, 5);
      expect(chunks.last, isA<DoneChunk>());
      // corpo enviado no wire Anthropic: system separado + x-api-key header
      expect(requests.single, contains('"system":"sys"'));
      expect(requests.single, contains('"role":"user","content":"oi"'));
      await provider.dispose();
      await server.close(force: true);
    });

    test('textCompletions: stream legado com choices[].text', () async {
      final (server: server, requests: requests) = await _startServer((req) async {
        req.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        req.response.write(
            'data: ${jsonEncode({'choices': [{'text': 'ab', 'finish_reason': null}]})}\n\n');
        req.response.write(
            'data: ${jsonEncode({'choices': [{'text': 'cd', 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 2, 'completion_tokens': 2}})}\n\n');
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });
      final provider = OpenAiCompatibleProvider(
        ProviderConfig(
          id: 'legacy',
          displayName: 'Legacy',
          baseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'k',
          modelIds: ['gpt-3.5-base'],
        ),
        wire: OpenAiCompatWire.textCompletions,
      );
      final chunks = await provider
          .streamChat(
            modelId: 'gpt-3.5-base',
            messages: const [
              ChatRequestMessage(role: 'user', content: 'vai')
            ],
            options: const ChatRequestOptions(),
            toolSchemas: const [],
          )
          .toList();
      expect(chunks.whereType<DeltaChunk>().map((c) => c.text).join(), 'abcd');
      final done = chunks.whereType<DoneChunk>().single;
      expect(done.finishReason, 'stop');
      expect(requests.single, contains('"prompt":'));
      expect(requests.single, isNot(contains('"messages"')));
      await provider.dispose();
      await server.close(force: true);
    });

    test('detectWireFromHost e presets', () {
      expect(detectWireFromHost('https://api.anthropic.com/v1'),
          OpenAiCompatWire.anthropicMessages);
      expect(detectWireFromHost('https://api.openai.com/v1'),
          OpenAiCompatWire.chatCompletions);
      expect(detectWireFromHost('http://localhost:11434/v1'),
          OpenAiCompatWire.chatCompletions);
      expect(detectWireFromHost('https://minha-proxy.exemplo.com/v1'), isNull);
      expect(kProviderPresets.map((p) => p.id),
          containsAll(['openai', 'anthropic', 'deepseek', 'ollama']));
      final anthropicPreset =
          kProviderPresets.firstWhere((p) => p.id == 'anthropic');
      expect(anthropicPreset.wire, OpenAiCompatWire.anthropicMessages);
    });
  });
}
