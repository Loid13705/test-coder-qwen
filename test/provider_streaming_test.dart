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
    final body = await utf8.decoder.bind(req).join();
    requests.add(body);
    try {
      await handler(req);
    } catch (_) {
      // cliente desconectou (cancelamento) — ignora
    }
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

    test('sem API key em provider remoto -> api_key_missing', () async {
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
    late HttpServer server;
    late List<String> requests;
    late OpenAiCompatibleProvider provider;
    late Future<void> Function(HttpRequest req) handler;

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

    Future<void> dispatch(HttpRequest req) => handler(req);

    Future<void> restart(Future<void> Function(HttpRequest) h) async {
      await server.close(force: true);
      handler = h;
      final s2 = await _startServer(dispatch);
      server = s2.server;
      requests = s2.requests;
      provider = OpenAiCompatibleProvider(ProviderConfig(
        id: 'custom',
        displayName: 'Test Local',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'sk-local-test',
        modelIds: ['gpt-4o-mini'],
      ));
    }

    setUp(() async {
      handler = respondStop;
      final s = await _startServer(dispatch);
        req.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        req.response.write(_sse([
          _chunkDelta('Olá'),
          _chunkDelta(' mundo'),
          {
            'choices': [
              {
                'delta': {},
                'finish_reason': 'stop',
              }
            ]
          },
        ]));
        await req.response.close();
      });
      server = s.server;
      requests = s.requests;
      baseUrl = 'http://127.0.0.1:${server.port}/v1';
      // ignore: unused_local_variable

      provider = OpenAiCompatibleProvider(ProviderConfig(
        id: 'custom',
        displayName: 'Test Local',
        baseUrl: baseUrl,
        apiKey: 'sk-local-test',
        modelIds: ['gpt-4o-mini'],
      ));
    });

    tearDown(() async {
      await provider.dispose();
      await server.close(force: true);
    });

    test('recebe deltas reais na ordem e DoneChunk(stop)', () async {
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
      expect(requests.single, contains('"model":"gpt-4o-mini"'));
      expect(requests.single, contains('"max_tokens":64'));
      expect(requests.single, contains('"stream":true'));
    });

    test('tool_calls fragmentados são acumulados em ToolCallStartChunk',
        () async {
      await _restart((req) async {
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
                      'function': {'name': 'fs.read_', 'arguments': '{"pa'}
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
                      'function': {'name': 'text', 'arguments': 'th":"x"}'}
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

    test('HTTP 401 -> ErrorChunk api_key_missing com body redigido',
        () async {
      await _restart((req) async {
        req.response.statusCode = 401;
        req.response.write('{"error":{"message":"bad key sk-shouldberedacted0987654321abcdef"}}');
        await req.response.close();
      });
      server = s2.server;
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
      expect(err.failure.message, isNot(contains('sk-shouldberedacted0987654321abcdef')));
    });

    test('HTTP 429 -> rate_limited', () async {
      await _restart((req) async {
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
      expect((chunks.single as ErrorChunk).failure.code, VtErrorCode.rateLimited);
    });
  });

  group('descoberta e capacidades', () {
    test('discoverModels cruza ids reais com catálogo; desconhecidos ficam disabled',
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
      final unknown =
          models.firstWhere((m) => m.id == 'modelo-misterioso-v9');
      // Capacidades desconhecidas NUNCA são presumidas:
      expect(unknown.enabled, isFalse);
      expect(unknown.capabilities.tools, isFalse);
      expect(unknown.capabilities.vision, isFalse);
      await provider.dispose();
      await s.server.close(force: true);
    });

    test('modelo sem suporte a tools -> model_does_not_support_tools',
        () async {
      // Servidor local REAL (loopback) para o provider passar do preflight;
      // a guarda de capacidades roda ANTES de qualquer requisição de rede.
      final s = await _startServer((req) async {
        req.response.statusCode = 500;
        await req.response.close();
      });
      final provider = OpenAiCompatibleProvider(ProviderConfig(
        id: 'ollama',
        displayName: 'Ollama',
        baseUrl: 'http://127.0.0.1:${s.server.port}/v1',
        modelIds: ['llama3.1:8b'],
      ));
      final chunks = await provider
          .streamChat(
            modelId: 'llama3.2:3b',
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
      await s.server.close(force: true);
    });
  });
}
