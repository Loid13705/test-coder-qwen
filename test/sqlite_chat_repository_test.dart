import 'dart:io';

import 'package:test/test.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

/// Regressão para os bugs encontrados no smoke de streaming:
/// 1) SELECT de pageMessages não incluía `conversation_id`, quebrando o cast
///    em MessageRecord.fromRow (Null -> String).
/// 2) bind_text com assinatura ABI errada causava segfault — agora coberto
///    por queries parametrizadas com aspas e UTF-8.
void main() {
  group('ChatRepository SQLite real', () {
    late Directory tmp;
    late SqliteDb db;
    late ChatRepository repo;

    setUp(() {
      if (!SqliteNative.available) return;
      tmp = Directory.systemTemp.createTempSync('techvt_repo_test_');
      db = SqliteNative.open('${tmp.path}/test.db');
      repo = ChatRepository(db);
    });

    tearDown(() {
      if (!SqliteNative.available) return;
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('insert + pageMessages preserva conversation_id e paginação', () {
      if (!SqliteNative.available) return;
      final convId = repo.createConversation(workspaceId: 'ws1', title: "d'água");
      final now = DateTime.now().toUtc().toIso8601String();
      for (var i = 0; i < 3; i++) {
        repo.insertMessage(
          id: 'm$i',
          conversationId: convId,
          role: i.isEven ? 'user' : 'assistant',
          blocksJson: '[{"type":"text","text":"olá mundo #$i"}]',
          status: 'complete',
          createdAt: now,
        );
      }
      final page = repo.pageMessages(convId, pageSize: 2);
      expect(page.items.length, 2);
      expect(page.hasMore, isTrue);
      expect(page.totalEstimate, 3);
      // A página inicial traz os MAIS RECENTES em ordem cronológica.
      // (Nota de design: com ids lexicográficos 'm0'..'m9' vs 'm10',
      // ORDER BY id não é estável por tempo — ver TODO abaixo.)
      expect(page.items.map((m) => m.id).toList(), ['m1', 'm2']);
      expect(page.items.first.role, 'assistant');
      expect(page.items.last.role, 'user');
      expect(page.items.first.conversationId, convId);
      expect(page.items.first.blocks.single['text'], contains('olá'));
      // cursor para mais antigo
      final older =
          repo.pageMessages(convId, beforeId: page.prevCursor, pageSize: 2);
      expect(older.items.map((m) => m.id).toList(), ['m0']);
      expect(repo.countMessages(convId), 3);
    });

    test('valores com apóstrofos e UTF-8 sobrevivem ao round-trip', () {
      if (!SqliteNative.available) return;
      final convId =
          repo.createConversation(workspaceId: 'ws1', title: "It's 日本語!");
      final now = DateTime.now().toUtc().toIso8601String();
      repo.insertMessage(
        id: 'q1',
        conversationId: convId,
        role: 'user',
        blocksJson:
            '[{"type":"text","text":"ela disse \'oi\' e olhou — acentuado"}]',
        status: 'complete',
        createdAt: now,
      );
      final page = repo.pageMessages(convId);
      expect(page.items.single.blocks.single['text'],
          "ela disse 'oi' e olhou — acentuado");
      final convs = repo.listConversations('ws1');
      expect(convs.first['title'], "It's 日本語!");
    });

    test('query parametrizada retorna linhas vazias sem crashar', () {
      if (!SqliteNative.available) return;
      final rows = db.query(
          "SELECT id, conversation_id, role FROM messages WHERE conversation_id=?",
          ['nao-existe']);
      expect(rows, isEmpty);
      expect(repo.pageMessages('nao-existe').items, isEmpty);
    });
  });
}
