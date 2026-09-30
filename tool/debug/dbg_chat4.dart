import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

void main() {
  final path = '/tmp/techvt_dbg_chat4_${pid}.db';
  final db = SqliteNative.open(path);
  print('open1 ok');
  final db2 = SqliteNative.open(path);
  print('open2 ok');
  db2.execute("CREATE TABLE IF NOT EXISTS t (id TEXT PRIMARY KEY, a TEXT, b TEXT, c TEXT, d TEXT, e TEXT, f TEXT)");
  print('create ok');
  db2.execute("INSERT INTO t VALUES ('1','a','b',NULL,'d','e','f')");
  print('insert ok');
  db.close();
  db2.close();
  File(path).deleteSync();
  print('DONE');
}
