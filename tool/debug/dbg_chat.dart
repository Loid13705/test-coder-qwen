import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main() {
  final path = '/tmp/techvt_dbg_chat_${pid}.db';
  final db = SqliteNative.open(path);
  print('opened');
  db.execute(kChatSchema);
  print('schema ok');
  final repo = ChatRepository(db);
  print('repo ok');
    final now0 = DateTime.now().toUtc().toIso8601String();
  for (var i = 0; i < 5; i++) {
    final id = 'conv_step_$i';
    db.execute("INSERT INTO conversations (id, workspace_id, title, parent_id, status, created_at, updated_at)"
        " VALUES ('$id','ws','t$i',NULL,'active','$now0','$now0')");
    print('step insert $i ok');
  }
print('about to call createConversation');
  final nowX = DateTime.now().toUtc().toIso8601String();
  final idX = 'conv_manual';
  db.execute("INSERT INTO conversations (id, workspace_id, title, parent_id, status, created_at, updated_at)"
      " VALUES ('$idX','ws','${"it's"}',NULL,'active','$nowX','$nowX')");
  print('manual apostrophe insert ok');
  final cid = repo.createConversation(workspaceId: 'ws', title: 'plain');
  print('conv $cid');
  repo.insertMessage(
      id: 'm1',
      conversationId: cid,
      role: 'user',
      blocksJson: '[]',
      status: 'done',
      createdAt: DateTime.now().toUtc().toIso8601String());
  print('insert ok, count=${repo.countMessages(cid)}');
  final page = repo.pageMessages(cid);
  print('page ok ${page.items.length}');
  db.close();
  File(path).deleteSync();
  print('DONE');
}
