import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

void main() {
  for (final mode in ['memory', 'file']) {
    final p = mode == 'memory' ? ':memory:' : '${Directory.systemTemp.path}/dbg2_$pid.db';
    print('mode=$mode path=$p');
    final db = SqliteNative.open(p);
    db.execute('CREATE TABLE t (x TEXT)');
    db.execute("INSERT INTO t VALUES ('hi')");
    final rows = db.query('SELECT x FROM t');
    print('  rows=$rows changes=${db.changes}');
    db.close();
    if (mode == 'file') File(p).deleteSync();
    print('  OK');
  }
}
