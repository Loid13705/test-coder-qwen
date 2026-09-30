import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main(List<String> args) {
  final branch = args.first;
  final db = SqliteNative.open('/tmp/dbg4_${branch}_$pid.db');
  db.execute(kChatSchema);
  print('[$branch] schema ok');
  switch (branch) {
    case 'S': // SELECT com bind, SEM usar o resultado (query executada e descartada)
      db.query("SELECT id FROM messages WHERE conversation_id=?", ['c1']);
      print('[$branch] bound select discarded ok');
    case 'T': // INSERT via exec + SELECT COUNT sem bind
      db.execute("INSERT INTO messages (id, conversation_id, role, blocks_json, status, created_at)"
          " VALUES ('m1','c1','user','[]','done','now')");
      final r = db.query("SELECT COUNT(*) AS c FROM messages");
      print('[$branch] insert+count ok: $r');
    case 'U': // INSERT via exec + SELECT colunas TEXT sem bind
      db.execute("INSERT INTO messages (id, conversation_id, role, blocks_json, status, created_at)"
          " VALUES ('m2','c1','user','[]','done','now')");
      final r = db.query("SELECT id, role, blocks_json FROM messages");
      print('[$branch] text-cols ok: $r');
    case 'V': // INSERT via exec + SELECT com bind retornando linhas
      db.execute("INSERT INTO messages (id, conversation_id, role, blocks_json, status, created_at)"
          " VALUES ('m3','c1','user','[]','done','now')");
      final r = db.query("SELECT id, role FROM messages WHERE conversation_id=?", ['c1']);
      print('[$branch] bound select w/ rows ok: $r');
  }
  sleep(const Duration(milliseconds: 50));
  print('[$branch] DONE alive');
  db.close();
  File('/tmp/dbg4_${branch}_$pid.db').deleteSync();
}
