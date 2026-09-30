import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

void main() {
  final path = '/tmp/techvt_dbg_chat6_${pid}.db';
  final db = SqliteNative.open(path);
  print('open ok');
  final now = DateTime.now().toUtc().toIso8601String();
  db.execute("CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, title TEXT NOT NULL, parent_id TEXT, status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL, updated_at TEXT NOT NULL)");
  print('create table ok');
  db.execute("CREATE INDEX IF NOT EXISTS idx_conv_ws ON conversations(workspace_id, updated_at)");
  print('create index alone ok');
  db.execute("INSERT INTO conversations (id, workspace_id, title, parent_id, status, created_at, updated_at) VALUES ('c1','ws','t',NULL,'active','$now','$now')");
  print('insert after index ok');
  db.close();
  File(path).deleteSync();
  print('DONE');
}
