import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main() {
  final p = '${Directory.systemTemp.path}/dbg_cols_${pid}.db';
  final db = SqliteNative.open(p);
  db.execute(kChatSchema);
  final rows = db.query(
      "SELECT id, role, model_id, mode, blocks_json, status, usage_json, created_at"
      " FROM messages WHERE conversation_id=?", ['conv_x']);
  print('rows=${rows.length}');
  print('keys=${rows.isNotEmpty ? rows.first.keys.toList() : "EMPTY"}');
  final all = db.query("SELECT id, conversation_id, role FROM messages");
  print('all keys=${all.isNotEmpty ? all.first.keys.toList() : "no rows"}');
  db.close();
  File(p).deleteSync();
}
