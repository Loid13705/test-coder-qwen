import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main(List<String> args) {
  final db = SqliteNative.open('/tmp/dbg5_$pid.db');
  db.execute(kChatSchema);
  print('schema ok');
  // SELECT com bind, SQL SEM colunas nomeadas (1 param, 0 rows) — crash?
  final r1 = db.query("SELECT ? AS v", ['abc']);
  print('select-param-const ok: $r1');
  sleep(const Duration(milliseconds: 30));
  print('alive after select-param-const');
  final r2 = db.query("SELECT id FROM messages WHERE conversation_id=?", ['c1']);
  print('bound select ok: ${r2.length}');
  db.close();
  File('/tmp/dbg5_$pid.db').deleteSync();
}
