import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

Future<void> main() async {
  final dbPath = '/tmp/repro_sqlite_${pid}.db';
  final db = SqliteNative.open(dbPath);
  print('db open ok');

  // servidor SSE real (como o fixture do smoke)
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final req in server) {
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.write('data: {"ok":true}\n\n');
      await req.response.close();
    }
  }());
  final url = Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions');

  // stream ativo via HttpClient cru (sem fechar a conexão antes do sqlite)
  final httpClient = HttpClient();
  final req = await httpClient.openUrl('POST', url);
  req.headers.contentType = ContentType.json;
  req.write('{}');
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  print('http status ${resp.statusCode}, body len ${body.length}');
  httpClient.close(force: true);

  db.execute('CREATE TABLE t(a TEXT)');
  db.execute("INSERT INTO t VALUES ('x')");
  final rows = db.query('SELECT a FROM t');
  print('sqlite query ok: $rows');

  await Future.delayed(const Duration(milliseconds: 500));
  print('after delay ok');
  db.close();
  await server.close(force: true);
  File(dbPath).deleteSync();
  print('DONE');
}
