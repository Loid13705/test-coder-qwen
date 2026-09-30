import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

void main() {
  print('available=${SqliteNative.available}');
  final p = '${Directory.systemTemp.path}/dbg_only_$pid.db';
  final db = SqliteNative.open(p);
  db.execute('CREATE TABLE t (x TEXT)');
  db.execute("INSERT INTO t VALUES ('hi')");
  final rows = db.query('SELECT x FROM t');
  print('rows=$rows changes=${db.changes}');
  db.close();
  File(p).deleteSync();
  print('SQLITE-ONLY OK');
}
