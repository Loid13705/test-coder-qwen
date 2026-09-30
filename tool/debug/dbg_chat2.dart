import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

void main() {
  final path = '/tmp/techvt_dbg_chat2_${pid}.db';
  final db = SqliteNative.open(path);
  print('opened');
  db.execute("CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, title TEXT NOT NULL, parent_id TEXT, status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL, updated_at TEXT NOT NULL)");
  print('create1 ok');
  db.execute("CREATE INDEX IF NOT EXISTS idx_conv_ws ON conversations(workspace_id, updated_at)");
  print('index1 ok');
  db.execute("CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL, model_id TEXT, mode TEXT, blocks_json TEXT NOT NULL, status TEXT NOT NULL, usage_json TEXT, created_at TEXT NOT NULL)");
  print('create2 ok');
  db.execute("CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id, id)");
  print('index2 ok');
  final now = DateTime.now().toUtc().toIso8601String();
  db.execute("INSERT INTO conversations (id, workspace_id, title, parent_id, status, created_at, updated_at) VALUES ('c1','ws','t',NULL,'active','$now','$now')");
  print('insert conv ok');
  db.close();
  File(path).deleteSync();
  print('DONE');
}
