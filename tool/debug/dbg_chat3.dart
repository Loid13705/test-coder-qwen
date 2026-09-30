import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

void main() {
  final path = '/tmp/techvt_dbg_chat3_${pid}.db';
  final db = SqliteNative.open(path);
  db.execute("CREATE TABLE conversations (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, title TEXT NOT NULL, parent_id TEXT, status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL, updated_at TEXT NOT NULL)");
  print('create ok');
  final now = DateTime.now().toUtc().toIso8601String();
  for (var i = 0; i < 5; i++) {
    final id = 'c$i';
    db.execute("INSERT INTO conversations (id, workspace_id, title, parent_id, status, created_at, updated_at)"
        " VALUES ('$id','ws','${'t'*500}',NULL,'active','$now','$now')");
    print('insert $i ok (len=${(500).toString()} title chars)');
  }
  db.close();
  File(path).deleteSync();
  print('DONE');
}
