import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main() {
  final db = SqliteNative.open(':memory:');
  db.execute(kChatSchema);
  final rows = db.query(
      "SELECT id, role, model_id, mode, blocks_json, status, usage_json, created_at"
      " FROM messages WHERE conversation_id=? ORDER BY id DESC LIMIT 21",
      ['nope']);
  print('rows=${rows.length} keys=${rows.isEmpty ? "n/a" : rows.first.keys.toList()}');
  db.close();
}
