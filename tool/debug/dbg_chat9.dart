import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main() {
  final path = '/tmp/techvt_dbg_chat9_${pid}.db';
  final db = SqliteNative.open(path);
  print('open ok');
  final repo = ChatRepository(db); // executa kChatSchema multi-statement
  print('schema multi ok');
  final now = DateTime.now().toUtc().toIso8601String();
  for (var i = 0; i < 3; i++) {
    final id = 'c$i';
    db.execute("INSERT INTO conversations (id, workspace_id, title, parent_id, status, created_at, updated_at)"
        " VALUES ('$id','ws','t',NULL,'active','$now','$now')");
    print('insert $i ok');
  }
  db.close();
  File(path).deleteSync();
  print('DONE');
}
