import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main(List<String> args) async {
  final branch = args.isEmpty ? 'A' : args.first;
  final db = SqliteNative.open('/tmp/dbg_branch_${branch}_$pid.db');
  print('[$branch] open ok');
  db.execute(kChatSchema);
  print('[$branch] schema ok');
  // acentos + apóstrofos escapados, como no smoke (title/blocks reais)
  db.execute("INSERT INTO conversations (id, workspace_id, title, parent_id, status, created_at, updated_at)"
      " VALUES ('c1','ws','Olá! Sou o stream real.',NULL,'active','now','now')");
  print('[$branch] insert accents ok');
  final blocks = "it s + ${'x' * 300} + olá";
  db.execute("INSERT INTO messages (id, conversation_id, role, model_id, mode, blocks_json, status, usage_json, created_at)"
      " VALUES ('m1','c1','user',NULL,NULL,'$blocks','done',NULL,'now')");
  print('[$branch] insert big blocks ok');
  final rows = db.query("SELECT COUNT(*) AS c FROM messages WHERE conversation_id=?", ['c1']);
  print('[$branch] query ok: $rows');
  sleep(const Duration(milliseconds: 100));
  print('[$branch] DONE alive');
  db.close();
  File('/tmp/dbg_branch_${branch}_$pid.db').deleteSync();
}
