library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:techvt/domain/errors/vt_failure.dart';
import 'package:techvt/domain/tools/tool_contract.dart';
import 'package:techvt/infrastructure/native/memory_store.dart';
import 'package:techvt/infrastructure/native/memory_tools.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

class _NoSandbox implements SandboxGateway {
  const _NoSandbox();
  @override
  Future<String> resolveReadable(String rawPath, ToolContext ctx) async =>
      throw VtFailure.pathOutOfSandbox(rawPath);
  @override
  Future<String> resolveWritable(String rawPath, ToolContext ctx) async =>
      throw VtFailure.pathOutOfSandbox(rawPath);
  @override
  bool isAllowedDomain(String domain, ToolContext ctx) => false;
}

class _NoSettings implements SettingsGateway {
  const _NoSettings();
  @override
  Object? get(String key, {String? workspaceId}) => null;
}

ToolContext _ctx(String root) => ToolContext(
      workspaceRoots: [root],
      sandbox: const _NoSandbox(),
      settings: const _NoSettings(),
    );

void main() {
  group('MemoryStore SQLite real', () {
    late Directory tmp;
    late SqliteDb db;
    late MemoryStore store;

    setUp(() {
      if (!SqliteNative.available) return;
      tmp = Directory.systemTemp.createTempSync('techvt_mem_test_');
      db = SqliteNative.open('${tmp.path}/mem.db');
      store = MemoryStore(db);
    });

    tearDown(() {
      if (!SqliteNative.available) return;
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('upsert cria e atualiza preservando id e tags', () {
      if (!SqliteNative.available) return;
      final a = store.upsert(
        workspaceId: '/ws',
        kind: 'fact',
        title: "preferência do d'água",
        body: 'usa aspas simples e UTF-8: ção é à vista',
        tags: ['style', 'quotes'],
      );
      expect(a.id, greaterThan(0));
      expect(a.tags, ['style', 'quotes']);
      final b = store.upsert(
        id: a.id,
        workspaceId: '/ws',
        kind: 'preference',
        title: 'atualizado',
        body: 'corpo novo',
      );
      expect(b.id, a.id);
      expect(b.kind, 'preference');
      expect(b.title, 'atualizado');
      expect(store.get(a.id)!.body, 'corpo novo');
    });

    test('search ranqueia título > tag > corpo e respeita pageSize', () {
      if (!SqliteNative.available) return;
      store.upsert(
          workspaceId: '/ws',
          kind: 'fact',
          title: 'flutter widgets tree',
          body: 'detalhe genérico',
          tags: ['ui']);
      store.upsert(
          workspaceId: '/ws',
          kind: 'procedure',
          title: 'build app',
          body: 'fale sobre flutter flutter flutter aqui',
          tags: []);
      store.upsert(
          workspaceId: '/ws',
          kind: 'decision',
          title: 'git flow',
          body: 'nada a ver',
          tags: ['flutterish']);

      final page = store.search(workspaceId: '/ws', query: 'flutter');
      expect(page.totalEstimate, 3); // todos casam de alguma forma
      expect(page.items.first.title, 'flutter widgets tree'); // match no título
      expect(page.items[1].title, 'build app'); // corpo (5 ocorrências cap)
      expect(page.hasMore, isFalse);
      expect(page.pageSize, 10);

      final limited =
          store.search(workspaceId: '/ws', query: 'flutter', pageSize: 2);
      expect(limited.items.length, 2);
      expect(limited.hasMore, isTrue);
      expect(limited.totalEstimate, 3);
    });

    test('recall reforça peso e marca timestamp; teto de 5.0', () {
      if (!SqliteNative.available) return;
      final r = store.upsert(
          workspaceId: '/ws',
          kind: 'fact',
          title: 'x',
          body: 'y',
          weight: 4.98);
      store.recall(r.id);
      store.recall(r.id);
      final after = store.get(r.id)!;
      expect(after.weight, closeTo(5.0, 1e-9)); // clamp no teto
      expect(after.lastRecalledAt, isNotNull);
    });

    test('stats agrupa por kind com contagem real', () {
      if (!SqliteNative.available) return;
      store.upsert(workspaceId: '/ws', kind: 'fact', title: 'a', body: 'b');
      store.upsert(workspaceId: '/ws', kind: 'fact', title: 'c', body: 'd');
      store.upsert(
          workspaceId: '/ws', kind: 'decision', title: 'e', body: 'f');
      final rows = store.stats(workspaceId: '/ws');
      final byKind = {for (final r in rows) r['kind'] as String: int.parse(r['count'] as String)};
      expect(byKind, {'fact': 2, 'decision': 1});
    });

    test('delete remove e retorna false para id inexistente', () {
      if (!SqliteNative.available) return;
      final r = store.upsert(
          workspaceId: '/ws', kind: 'fact', title: 'a', body: 'b');
      expect(store.delete(r.id), isTrue);
      expect(store.get(r.id), isNull);
      expect(store.delete(r.id), isFalse);
    });

    test('busca não vaza memórias de outro workspace', () {
      if (!SqliteNative.available) return;
      store.upsert(
          workspaceId: '/ws1', kind: 'fact', title: 'alpha', body: 'x');
      store.upsert(
          workspaceId: '/ws2', kind: 'fact', title: 'alpha', body: 'x');
      final page = store.search(workspaceId: '/ws1', query: 'alpha');
      expect(page.items.single.workspaceId, '/ws1');
    });

    test('query sem tokens ordena por peso puro', () {
      if (!SqliteNative.available) return;
      store.upsert(
          workspaceId: '/ws', kind: 'fact', title: 'low', body: 'b', weight: 1);
      store.upsert(
          workspaceId: '/ws', kind: 'fact', title: 'high', body: 'b', weight: 3);
      final page = store.search(workspaceId: '/ws', query: '', reinforce: false);
      expect(page.items.map((r) => r.title).toList(), ['high', 'low']);
    });
  });

  group('Memory tools via contrato VtTool', () {
    late Directory tmp;
    late SqliteDb db;
    late MemoryStore store;

    setUp(() {
      if (!SqliteNative.available) return;
      tmp = Directory.systemTemp.createTempSync('techvt_memtool_test_');
      db = SqliteNative.open('${tmp.path}/m.db');
      store = MemoryStore(db);
    });

    tearDown(() {
      if (!SqliteNative.available) return;
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('save -> search -> recall -> stats -> forget ciclo completo', () async {
      if (!SqliteNative.available) return;
      final ctx = _ctx('/ws');

      final save = MemorySaveTool(store);
      final saved = await save.execute(
          ctx, await save.parseInput({'title': 'api design', 'body': 'REST', 'tags': ['http']}));
      expect(saved, isA<ToolSuccess<TextOutput>>());
      final rec = jsonDecode((saved as ToolSuccess<TextOutput>).data.text)
          as Map<String, Object?>;
      final id = rec['id'] as int;

      final search = MemorySearchTool(store);
      final found = await search.execute(ctx, await search.parseInput({'query': 'api'}));
      final hits = jsonDecode((found as ToolSuccess<TextOutput>).data.text)
          as List<Object?>;
      expect(hits, hasLength(1));
      expect(found.citations.single.sourceRef, 'memory://$id');

      final recall = MemoryRecallTool(store);
      final back = await recall.execute(ctx, await recall.parseInput({'id': id}));
      final boosted = jsonDecode((back as ToolSuccess<TextOutput>).data.text)
          as Map<String, Object?>;
      expect(boosted['weight'], greaterThan(1.0));
      expect(boosted['lastRecalledAt'], isNotNull);

      final stats = MemoryStatsTool(store);
      final st = await stats.execute(ctx, await stats.parseInput({}));
      final rows =
          jsonDecode((st as ToolSuccess<TextOutput>).data.text) as List<Object?>;
      expect((rows.single as Map)['count'], 1);

      final forget = MemoryForgetTool(store);
      final gone = await forget.execute(ctx, await forget.parseInput({'id': id}));
      expect(gone, isA<ToolSuccess<TextOutput>>());
      expect(store.get(id), isNull);
    });

    test('validações reais: kind inválido e id inexistente viram ToolFailure',
        () async {
      if (!SqliteNative.available) return;
      final ctx = _ctx('/ws');
      final save = MemorySaveTool(store);
      final bad = await save.execute(ctx,
          await save.parseInput({'title': 't', 'body': 'b', 'kind': 'bogus'}));
      expect(bad, isA<ToolFailureResult<TextOutput>>());
      expect((bad as ToolFailureResult<TextOutput>).failure.code,
          VtErrorCode.validationFailed);

      final recall = MemoryRecallTool(store);
      final missing =
          await recall.execute(ctx, await recall.parseInput({'id': 99999}));
      expect(missing, isA<ToolFailureResult<TextOutput>>());

      // parseInput valida campos obrigatórios pelo schema declarado.
      expect(() => save.parseInput({'title': 'so titulo'}),
          throwsA(isA<VtFailure>()));
    });

    test('riscos e políticas seguem a spec (save=reviewEach, forget=explicit)',
        () {
      if (!SqliteNative.available) return;
      expect(MemorySaveTool(store).risk, RiskLevel.localWrite);
      expect(MemorySaveTool(store).defaultApproval,
          ApprovalPolicyMode.reviewEach);
      expect(MemoryForgetTool(store).risk, RiskLevel.destructive);
      expect(MemoryForgetTool(store).defaultApproval,
          ApprovalPolicyMode.explicitApproval);
      expect(MemorySearchTool(store).risk, RiskLevel.readOnly);
      expect(MemorySearchTool(store).capabilities, ['sqlite']);
    });
  });
}
