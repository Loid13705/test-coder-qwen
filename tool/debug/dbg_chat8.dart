import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

void main() {
  final path = '/tmp/techvt_dbg_chat8_${pid}.db';
  final db = SqliteNative.open(path);
  print('open ok');
  final now = DateTime.now().toUtc().toIso8601String();
  db.execute("CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, title TEXT NOT NULL, parent_id TEXT, status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL, updated_at TEXT NOT NULL)");
  print('create table ok');
  db.execute("INSERT INTO conversations (id, workspace_id, title, parent_id, status, created_at, updated_at) VALUES ('c1','ws','t1',NULL,'active','$now','$now')");
  print('insert c1 ok');
  db.execute("INSERT INTO conversations (id, workspace_id, title, parent_id, status, created_at, updated_at) VALUES ('c2','ws','t2',NULL,'active','$now','$now')");
  print('insert c2 ok');
  // agora o CREATE INDEX multi-statement (como no schema real)
  db.execute('''
CREATE INDEX IF NOT EXISTS idx_conv_ws ON conversations(workspace_id, updated_at);
''');
  print('multi-create-index ok');
  db.execute("INSERT INTO conversations (id, workspace_id, title, parent_id, status, created_at, updated_at) VALUES ('c3','ws','t3',NULL,'active','$now','$now')");
  print('insert c3 after multi ok');
  db.close();
  File(path).deleteSync();
  print('DONE');
}
