import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/infrastructure/native/chat_records.dart';

void main() {
  final p = '${Directory.systemTemp.path}/dbg_sch_$pid.db';
  final db = SqliteNative.open(p);
  stderr.writeln('opened');
  // split multi-statement and run one by one via execute to find the culprit
  final stmts = kChatSchema
      .split(';')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  for (final s in stmts) {
    stderr.writeln('running: ${s.substring(0, 40)}...');
    db.execute(s);
    stderr.writeln('  ok');
  }
  db.close();
  File(p).deleteSync();
  stderr.writeln('SCHEMA OK');
}
