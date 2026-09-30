import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main() {
  final p = '${Directory.systemTemp.path}/dbg_chat_$pid.db';
  final db = SqliteNative.open(p);
  stderr.writeln('opened');
  db.execute(kChatSchema);
  stderr.writeln('schema ok');
  final repo = ChatRepository(db);
  final id = repo.createConversation(workspaceId: 'ws1', title: 'smoke');
  stderr.writeln('conv=$id');
  repo.insertMessage(
      id: 'm1', conversationId: id, role: 'user',
      blocksJson: '[]', status: 'complete',
      createdAt: DateTime.now().toUtc().toIso8601String());
  stderr.writeln('inserted count=${repo.countMessages(id)}');
  final page = repo.pageMessages(id);
  stderr.writeln('page items=${page.items.length} total=${page.totalEstimate}');
  db.close();
  File(p).deleteSync();
  stderr.writeln('CHAT-DB OK');
}
