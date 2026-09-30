import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main(List<String> args) {
  final branch = args.isEmpty ? 'B' : args.first;
  final db = SqliteNative.open('/tmp/dbg2_${branch}_$pid.db');
  print('[$branch] open ok');
  db.execute(kChatSchema);
  print('[$branch] schema ok');
  switch (branch) {
    case 'B': // query SEM bind params
      final r = db.query("SELECT COUNT(*) AS c FROM messages");
      print('[$branch] no-param query ok: $r');
    case 'C': // query COM bind param — suspected crash path
      final r = db.query(
          "SELECT id, role FROM messages WHERE conversation_id=?", ['c1']);
      print('[$branch] bound query ok: ${r.length} rows');
  }
  sleep(const Duration(milliseconds: 50));
  print('[$branch] DONE alive');
  db.close();
  File('/tmp/dbg2_${branch}_$pid.db').deleteSync();
}
