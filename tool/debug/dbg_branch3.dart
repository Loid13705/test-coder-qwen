import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

typedef _BindText16C = Int32 Function(
    Pointer<Void>, Int32, Pointer<Uint16>, Int32, Pointer<Void>);
typedef _BindText16Dart = int Function(
    Pointer<Void>, int, Pointer<Uint16>, int, Pointer<Void>);

// query alternativa que replica SqliteDb.query mas usa bind_text16 (UTF-16 real)
List<Map<String, Object?>> queryBound16(SqliteDb db, DynamicLibrary lib,
    String sql, List<String> params) {
  return using((arena) {
    final prepare = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>)>(
        'sqlite3_prepare_v2');
    final bind16 = lib.lookupFunction<_BindText16C, _BindText16Dart>('sqlite3_bind_text16');
    final step = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('sqlite3_step');
    final fin = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('sqlite3_finalize');
    final colText = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Int32),
        Pointer<Utf8> Function(Pointer<Void>, int)>('sqlite3_column_text');
    final colName = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Int32),
        Pointer<Utf8> Function(Pointer<Void>, int)>('sqlite3_column_name');
    final colCount = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('sqlite3_column_count');
    final stmtPtr = arena<Pointer<Void>>();
    // handle não exposto; truque: reabrir o mesmo arquivo? Não — usamos API pública para exec
    // e só testamos bind via db.query normal. Este helper fica sem handle => placeholder.
    throw UnimplementedError();
  });
}

void main(List<String> args) async {
  final branch = args.isEmpty ? 'A' : args.first;
  final db = SqliteNative.open('/tmp/dbg3_${branch}_$pid.db');
  db.execute(kChatSchema);
  print('[$branch] schema ok');
  switch (branch) {
    case 'P': // prepare com nBytes = length em UTF-8 EXPLICITO (não -1)
      // simula via query publica mas interceptando... mais simples: testar param string VAZIA
      final r = db.query("SELECT id FROM messages WHERE conversation_id=?", ['']);
      print('[$branch] empty-param query ok: ${r.length} rows');
    case 'Q': // param longo (> SQLITE_MAX_LENGTH? não, ~4KB)
      final long = 'x' * 4096;
      final r = db.query("SELECT id FROM messages WHERE conversation_id=?", [long]);
      print('[$branch] long-param query ok: ${r.length} rows');
    case 'R': // dois params
      final r = db.query("SELECT id FROM messages WHERE conversation_id=? AND role=?", ['c1', 'user']);
      print('[$branch] two-param query ok: ${r.length} rows');
  }
  sleep(const Duration(milliseconds: 50));
  print('[$branch] DONE alive');
  db.close();
  File('/tmp/dbg3_${branch}_$pid.db').deleteSync();
}
