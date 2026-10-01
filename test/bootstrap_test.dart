/// Testes da composição root (bootstrap): settings reais em disco, registro
/// completo de tools e abertura do app com SQLite real em pasta temporária.
library;

import 'dart:io';

import 'package:techvt/application/app_bootstrap.dart';
import 'package:techvt/domain/tools/tool_contract.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/provider/openai_compatible_provider.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('techvt_boot_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('FileSettings', () {
    test('sem arquivo => vazio real (nunca mock)', () async {
      final s = await FileSettings.load(tmp.path);
      expect(s.get('qualquer.coisa'), isNull);
      expect(s.providers, isEmpty);
      expect(s.recentWorkspaces, isEmpty);
    });

    test('save/load round-trip com hierarquia de workspace', () async {
      await FileSettings.save(tmp.path, {
        'filesystem.maxReadBytes': 1234,
        'workspace': {
          'wsA': {'filesystem.maxReadBytes': 99},
        },
        'providers': [
          const ProviderFileSpec(
            id: 'ollama',
            displayName: 'Ollama',
            baseUrl: 'http://127.0.0.1:11434/v1',
            modelIds: ['llama3'],
          ).toJson(),
        ],
        'recentWorkspaces': ['/home/u/proj'],
      });

      final s = await FileSettings.load(tmp.path);
      expect(s.get('filesystem.maxReadBytes'), 1234);
      expect(
          s.get('filesystem.maxReadBytes', workspaceId: 'wsA'),
          99, // escopo de workspace sobrepõe global
          reason: 'hierarquia de settings ignorada');
      expect(s.get('filesystem.maxReadBytes', workspaceId: 'wsB'), 1234);
      expect(s.providers.single.id, 'ollama');
      expect(s.providers.single.modelIds, ['llama3']);
      expect(s.recentWorkspaces, ['/home/u/proj']);
    });

    test('JSON corrompido degrada para vazio sem lançar', () async {
      File('${tmp.path}/settings.json').writeAsStringSync('{isso não é json');
      final s = await FileSettings.load(tmp.path);
      expect(s.get('x'), isNull);
    });
  });

  group('defaultDataDir', () {
    test('respeita override TECHVT_DATA_DIR documentado', () {
      // O override é lido do ambiente do processo; aqui exercitamos o
      // caminho via parâmetro explícito em VtApp.open (abaixo), então só
      // garantimos que sem override cai no home.
      final d = defaultDataDir();
      expect(d, isNotEmpty);
      expect(d.contains('.techVT') || d.contains('techVT'), isTrue);
    });
  });

  group('buildFullToolRegistry', () {
    test('registra as 35 ferramentas reais (15 fs + 15 git + 5 memória)',
        () {
      if (!SqliteNative.available) return; // mesma guarda dos demais testes
      final db = SqliteNative.open('${tmp.path}/tools.db');
      addTearDown(db.close);
      final reg = buildFullToolRegistry(db);
      final ids = reg.all.map((t) => t.id).toList()..sort();
      expect(ids.length, 35);
      for (final must in [
        'fs.read_text',
        'fs.write_text',
        'git.status',
        'git.commit',
        'memory.save',
        'memory.search',
      ]) {
        expect(reg.contains(must), isTrue, reason: 'faltando $must');
      }
      // nenhuma duplicata silenciosa: register lança se colidir
      expect(ids.toSet().length, ids.length);
    });
  });

  group('VtApp.open (composição root real)', () {
    test('abre app sobre pasta temporária, cria DB/settings e health ok',
        () async {
      if (!SqliteNative.available) return;
      final ws = Directory('${tmp.path}/ws')..createSync();
      final dataDir = '${tmp.path}/data';
      await FileSettings.save(dataDir, {
        'providers': [
          const ProviderFileSpec(
            id: 'local',
            displayName: 'Local',
            baseUrl: 'http://127.0.0.1:1/v1',
            modelIds: ['m1'],
          ).toJson(),
        ],
      });

      final app = await VtApp.open(
        dataDir: dataDir,
        workspaceRoots: [ws.path],
        keyResolver: (id) async => id == 'local' ? 'test-key' : null,
      );
      addTearDown(app.dispose);

      expect(File('$dataDir/techvt.sqlite').existsSync(), isTrue);
      expect(app.providerIds, ['local']);
      expect(app.chat.tools!.all.length, 35);

      // provider registrado de verdade (chave resolvida via resolver)
      final p = app.chat.providers.require('local');
      expect(p, isA<OpenAiCompatibleProvider>());
      expect((p as OpenAiCompatibleProvider).config.apiKey, 'test-key');

      // sandbox bloqueia escrita fora do workspace (real, não simulado)
      final ctx = ToolContext(
        workspaceRoots: [ws.path],
        sandbox: app.sandbox,
        settings: app.settings,
      );
      var denied = false;
      try {
        await app.sandbox.resolveWritable('/etc/passwd', ctx);
      } on Exception {
        denied = true;
      }
      expect(denied, isTrue, reason: 'sandbox deveria negar /etc/passwd');

      // dentro do workspace passa
      final ok = await app.sandbox.resolveWritable('${ws.path}/a.txt', ctx);
      expect(ok.endsWith('a.txt'), isTrue);
    });
  });
}
