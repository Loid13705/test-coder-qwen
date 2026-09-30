import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

void main() {
  final p = '${Directory.systemTemp.path}/dbg3_$pid.db';
  final db = SqliteNative.open(p);
  final repo = ChatRepository(db);
  final convId = repo.createConversation(workspaceId: 'ws1', title: "it's");
  print('conv=$convId');
  repo.insertMessage(
      id: 'm1', conversationId: convId, role: 'user',
      blocksJson: '[{"type":"text","text":"oi"}]', status: 'complete',
      createdAt: '2026-01-01');
  final rows = db.query("SELECT id, conversation_id FROM messages WHERE conversation_id=?", [convId]);
  print('rows=${rows.length} first=${rows.isEmpty ? null : rows.first}');
  final page = repo.pageMessages(convId);
  print('page items=${page.items.length} total=${page.totalEstimate}');
  db.close();
  File(p).deleteSync();
}
