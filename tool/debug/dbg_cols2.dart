import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main() {
  final p = '${Directory.systemTemp.path}/dbg_cols2_${pid}.db';
  final db = SqliteNative.open(p);
  db.execute(kChatSchema);
  final repo = ChatRepository(db);
  final convId = repo.createConversation(workspaceId: 'ws1', title: "teste d'água");
  repo.insertMessage(
    id: 'm1', conversationId: convId, role: 'user',
    blocksJson: '[{"type":"text","text":"olá mundo"}]',
    status: 'complete', createdAt: DateTime.now().toUtc().toIso8601String());
  // SELECT com params igual pageMessages
  final rows = db.query(
      "SELECT id, role, model_id, mode, blocks_json, status, usage_json, created_at"
      " FROM messages WHERE conversation_id=?", [convId]);
  print('rows=${rows.length}');
  print('keys=${rows.isNotEmpty ? rows.first.keys.toList() : "EMPTY"}');
  try {
    final page = repo.pageMessages(convId);
    print('page items=${page.items.length}');
  } catch (e) {
    print('pageMessages ERRO: $e');
  }
  db.close();
  File(p).deleteSync();
}
