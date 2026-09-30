import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main() {
  final db = SqliteNative.open(':memory:');
  db.execute(kChatSchema);
  db.execute("INSERT INTO messages (id, conversation_id, role, model_id, mode,"
      " blocks_json, status, usage_json, created_at)"
      " VALUES ('m1','c1','user',NULL,NULL,'[]','done',NULL,'2026-01-01')");
  final rows = db.query(
      "SELECT id, role, model_id, mode, blocks_json, status, usage_json, created_at"
      " FROM messages WHERE conversation_id=? ORDER BY id DESC LIMIT 21",
      ['c1']);
  print('rows=${rows.length}');
  for (final r in rows) {
    print('keys=${r.keys.toList()}');
    print('map=$r');
  }
  db.close();
}
