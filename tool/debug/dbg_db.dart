import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

void main() {
  final path = '/tmp/techvt_dbg_${pid}.db';
  print('available=${SqliteNative.available}');
  final db = SqliteNative.open(path);
  print('opened');
  db.execute('CREATE TABLE t (id TEXT)');
  print('create ok');
  db.execute("INSERT INTO t VALUES ('a')");
  print('insert ok');
  final rows = db.query('SELECT id FROM t');
  print('query ok: $rows');
  print('changes=${db.changes}');
  db.close();
  print('closed');
  File(path).deleteSync();
  print('DONE');
}
