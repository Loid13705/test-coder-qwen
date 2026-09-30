import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

void main(List<String> args) {
  final db = SqliteNative.open('/tmp/dbg6_$pid.db');
  print('open ok');
  final r1 = db.query("SELECT ? AS v", ['abc']);
  print('param-only query ok: $r1');
  sleep(const Duration(milliseconds: 30));
  print('alive');
  db.close();
  File('/tmp/dbg6_$pid.db').deleteSync();
}
