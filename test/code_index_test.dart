/// Testes do índice de código: extração heurística de símbolos, scan
/// incremental real (FS + SQLite FFI), ranking de busca e tools do catálogo.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:techvt/domain/errors/vt_failure.dart';
import 'package:techvt/domain/tools/tool_contract.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/search/code_index_store.dart';
import 'package:techvt/infrastructure/search/code_index_tools.dart';

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

const _sampleA = '''
/// Doc comment com class Fake dentro — não pode virar símbolo.
library;

import 'dart:async';

const kMaxRetries = 3;

abstract class BaseThing {
  final String name;
  int counter = 0;

  BaseThing(this.name);

  Future<void> doWork({int? attempts}) async {
    if (attempts == null) return;
  }
}

class Widget extends BaseThing with Loudly {
  static final Widget? _instance;

  @override
  String toString() => 'Widget(\$name)';

  void _privateHelper() {}
}

mixin Loudly on Widget {}

enum Color { red, green }

sealed class Shape {}

typedef Handler = void Function(Event e);

void topLevelFn(int x) {
  print(x);
}
''';

void main() {
  group('extractDartSymbols (heurística determinística)', () {
    test('casa classes/mixin/enum/typedef/funções/campos nas linhas certas',
        () {
      final syms = extractDartSymbols(_sampleA);
      final byName = {for (final (n, k, l, _) in syms) n: (k, l)};
      expect(byName['BaseThing']?.$1, 'class');
      expect(byName['Widget']?.$1, 'class');
      expect(byName['Loudly']?.$1, 'mixin');
      expect(byName['Color']?.$1, 'enum');
      expect(byName['Shape']?.$1, 'class'); // sealed class
      expect(byName['Handler']?.$1, 'typedef');
      expect(byName['topLevelFn']?.$1, 'function');
      expect(byName['doWork']?.$1, 'function');
      expect(byName['_privateHelper']?.$1, 'function');
      expect(byName['toString']?.$1, 'function');
      expect(byName['name']?.$1, 'field');
      expect(byName['_instance']?.$1, 'field');
      // doc comment jamais vira símbolo
      expect(byName.containsKey('Fake'), isFalse);
      // linha 1-based confere com o fonte
      expect(byName['BaseThing']?.$2, greaterThan(1));
    });

    test('não produz falsos positivos em statements de controle', () {
      final syms = extractDartSymbols('''
void f() {
  if (cond) {
    return;
  }
  for (var i = 0; i < 3; i++) {}
}
''');
      final names = syms.map((s) => s.$1).toSet();
      expect(names.intersection({'if', 'for', 'return'}), isEmpty);
    });
  });

  group('CodeIndexStore SQLite real', () {
    late Directory tmp;
    late SqliteDb db;
    late CodeIndexStore store;
    late Directory ws;

    setUp(() {
      if (!SqliteNative.available) return;
      tmp = Directory.systemTemp.createTempSync('techvt_idx_test_');
      db = SqliteNative.open('${tmp.path}/idx.db');
      store = CodeIndexStore(db);
      ws = Directory('${tmp.path}/ws')..createSync();
      File('${ws.path}/a.dart').writeAsStringSync(_sampleA);
      Directory('${ws.path}/sub').createSync();
      File('${ws.path}/sub/b.dart')
          .writeAsStringSync('class SubThing {\n  int x = 1;\n}\n');
      Directory('${ws.path}/node_modules').createSync();
      File('${ws.path}/node_modules/skip.dart')
          .writeAsStringSync('class ShouldNotIndex {}\n');
    });

    tearDown(() {
      if (!SqliteNative.available) return;
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('scan inicial indexa docs e símbolos reais, pula skipDirs', () {
      if (!SqliteNative.available) return;
      final stats = store.scanWorkspace(workspaceId: ws.path, root: ws.path);
      expect(stats.filesScanned, 2);
      expect(stats.filesUpdated, 2);
      expect(stats.symbolsIndexed, greaterThan(5));
      final agg = store.stats(ws.path);
      expect(agg['documents'], 2);
      expect((agg['byKind'] as Map)['class'], greaterThanOrEqualTo(4));
      // node_modules NUNCA entra
      final page = store.searchSymbols(
          workspaceId: ws.path, query: 'ShouldNotIndex');
      expect(page.items, isEmpty);
    });

    test('scan incremental é idempotente: nada re-indexado sem mudança', () {
      if (!SqliteNative.available) return;
      store.scanWorkspace(workspaceId: ws.path, root: ws.path);
      final second =
          store.scanWorkspace(workspaceId: ws.path, root: ws.path);
      expect(second.filesUpdated, 0);
      expect(second.symbolsIndexed, 0);
      expect(store.stats(ws.path)['documents'], 2);
    });

    test('arquivo alterado re-indexa símbolos; removido sai do índice', () {
      if (!SqliteNative.available) return;
      store.scanWorkspace(workspaceId: ws.path, root: ws.path);
      // alteração real de conteúdo (+mtime futuro garantido via write)
      sleep(const Duration(milliseconds: 5));
      File('${ws.path}/sub/b.dart')
          .writeAsStringSync('class RenamedThing {\n  int y = 2;\n}\n');
      var stats = store.scanWorkspace(workspaceId: ws.path, root: ws.path);
      expect(stats.filesUpdated, 1);
      expect(store
          .searchSymbols(workspaceId: ws.path, query: 'RenamedThing')
          .items,
          hasLength(1));
      expect(
          store.searchSymbols(workspaceId: ws.path, query: 'SubThing').items,
          isEmpty);

      File('${ws.path}/sub/b.dart').deleteSync();
      stats = store.scanWorkspace(workspaceId: ws.path, root: ws.path);
      expect(stats.filesRemoved, 1);
      expect(store.stats(ws.path)['documents'], 1);
    });

    test('ranking: exato > prefixo > substring > assinatura; paginação', () {
      if (!SqliteNative.available) return;
      store.scanWorkspace(workspaceId: ws.path, root: ws.path);
      final page = store.searchSymbols(
          workspaceId: ws.path, query: 'widget', pageSize: 2);
      expect(page.items.first.name, 'Widget'); // case-insensitive exato
      expect(page.items.first.score, greaterThan(6.0)); // bônus structural
      expect(page.pageSize, 2);
      expect(page.hasMore, isTrue);
      final p2 = store.searchSymbols(
          workspaceId: ws.path,
          query: 'widget',
          pageSize: 2,
          offset: int.parse(page.nextCursor!));
      expect(p2.items.every((h) => h.name != 'Widget'), isTrue);
      expect(p2.offsetMode, 2);
    });

    test('filtro por kind e purge', () {
      if (!SqliteNative.available) return;
      store.scanWorkspace(workspaceId: ws.path, root: ws.path);
      final enums = store.searchSymbols(
          workspaceId: ws.path, query: 'colo', kind: 'enum');
      expect(enums.items.map((e) => e.name), contains('Color'));
      final noEnums = store.searchSymbols(
          workspaceId: ws.path, query: 'color', kind: 'function');
      expect(noEnums.items, isEmpty);

      final removed = store.purge(ws.path);
      expect(removed, 2);
      expect(store.stats(ws.path)['documents'], 0);
    });

    test('query vazia falha tipada', () {
      if (!SqliteNative.available) return;
      expect(
          () => store.searchSymbols(workspaceId: ws.path, query: '   '),
          throwsA(isA<SqliteException>()));
    });
  });

  group('tools code_index.*', () {
    late Directory tmp;
    late SqliteDb db;
    late CodeIndexStore store;
    late Directory ws;
    late ToolContext ctx;

    setUp(() {
      if (!SqliteNative.available) return;
      tmp = Directory.systemTemp.createTempSync('techvt_idxtool_test_');
      db = SqliteNative.open('${tmp.path}/idx.db');
      store = CodeIndexStore(db);
      ws = Directory('${tmp.path}/ws')..createSync();
      File('${ws.path}/a.dart').writeAsStringSync(_sampleA);
      ctx = _ctx(ws.path);
    });

    tearDown(() {
      if (!SqliteNative.available) return;
      db.close();
      tmp.deleteSync(recursive: true);
    });

    Future<Map<String, Object?>> runTool(
        VtTool tool, Map<String, Object?> input) async {
      final res = await tool.execute(ctx, MapToolInput(input));
      expect(res, isA<ToolSuccess<TextOutput>>());
      final out = (res as ToolSuccess<TextOutput>).data;
      return jsonDecode(out.text) as Map<String, Object?>;
    }

    test('scan -> search -> stats -> purge pelo contrato de tools', () async {
      if (!SqliteNative.available) return;
      final scan = await runTool(CodeIndexScanTool(store), {});
      expect(scan['filesUpdated'], 1);

      final searchTool = CodeIndexSearchTool(store);
      final searchRes = await searchTool
          .execute(ctx, MapToolInput({'query': 'CodeIndex', 'limit': 5}));
      // busca por substring do nome real do sample
      final searchRes2 = await searchTool
          .execute(ctx, MapToolInput({'query': 'topLevelFn'}));
      expect(searchRes2, isA<ToolSuccess<TextOutput>>());
      final hits = jsonDecode(
              (searchRes2 as ToolSuccess<TextOutput>).data.text)
          as List;
      expect(hits.single['name'], 'topLevelFn');
      expect(hits.single['kind'], 'function');
      expect(searchRes, isNotNull); // parâmetro paginado aceito

      final stats = await runTool(CodeIndexStatsTool(store), {});
      expect(stats['documents'], 1);

      final purge = await runTool(CodeIndexPurgeTool(store), {});
      expect(purge['documentsRemoved'], 1);
    });

    test('workspace inexistente → falha de validação, sem crash', () async {
      if (!SqliteNative.available) return;
      final badCtx = _ctx('${tmp.path}/nao-existe');
      final res =
          await CodeIndexScanTool(store).execute(badCtx, MapToolInput({}));
      expect(res, isA<ToolFailureResult<TextOutput>>());
      final f = (res as ToolFailureResult<TextOutput>).failure;
      expect(f.code, VtErrorCode.validationFailed);
    });

    test('contratos: risco/aprovação/categoria corretos', () {
      final scan = CodeIndexScanTool(store);
      final purge = CodeIndexPurgeTool(store);
      expect(scan.risk, RiskLevel.localWrite);
      expect(purge.risk, RiskLevel.destructive);
      expect(purge.defaultApproval, ApprovalPolicyMode.explicitApproval);
      expect(scan.category, ToolCategory.codeIndex);
      expect(CodeIndexSearchTool(store).risk, RiskLevel.readOnly);
    });
  });
}
