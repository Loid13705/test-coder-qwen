import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main() {
  final path = '/tmp/techvt_dbg_chat5_${pid}.db';
  final db = SqliteNative.open(path);
  print('open ok');
  db.execute("CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, title TEXT NOT NULL, parent_id TEXT, status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL, updated_at TEXT NOT NULL)");
  print('create conv table ok');
  final repo = ChatRepository(db);
  print('repo ok');
  final cid = repo.createConversation(workspaceId: 'ws', title: 'smoke');
  print('conv ok: $cid');
  final now = DateTime.now().toUtc().toIso8601String();
  db.execute("INSERT INTO messages (id, conversation_id, role, model_id, mode, blocks_json, status, usage_json, created_at)"
      " VALUES ('m1','$cid','user',NULL,NULL,'[]','done',NULL,'$now')");
  print('insert msg direct ok');
  repo.insertMessage(id:'m2', conversationId: cid, role:'assistant', blocksJson:'[]', status:'done', createdAt: now);
  print('insert msg repo ok');
  db.close();
  File(path).deleteSync();
  print('DONE');
}
