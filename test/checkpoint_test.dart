/// Testes do sistema de checkpoint: snapshot real em disco + SQLite, trava de
/// drift, restore atômico e rollback de arquivo novo (remoção).
library;

import 'dart:io';

import 'package:path/path.dart';

import 'package:test/test.dart';
import 'package:techvt/domain/errors/vt_failure.dart';
import 'package:techvt/infrastructure/checkpoint/checkpoint_store.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';

void main() {
  late Directory tmp;
  late SqliteDb db;
  late CheckpointStore store;
  late Directory ws;

  setUp(() {
    if (!SqliteNative.available) return;
    tmp = Directory.systemTemp.createTempSync('ckpt_test_');
    db = SqliteNative.open('${tmp.path}/test.db');
    store = CheckpointStore(db, dataDir: tmp.path);
    ws = Directory('${tmp.path}/ws')..createSync();
  });

  tearDown(() {
    if (!SqliteNative.available) return;
    db.close();
    tmp.deleteSync(recursive: true);
  });

  File seed(String rel, String content) {
    final f = File('${ws.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  group('CheckpointStore.create', () {
    test('snapshot real: bytes copiados, hash registrado, manifest escrito',
        () async {
      if (!SqliteNative.available) return;
      final f = seed('lib/a.dart', 'void main() {}');
      final rec = await store.create(
          workspaceRoot: ws.path, absPath: f.path, reason: 'antes do refactor');

      expect(rec.existedBefore, isTrue);
      expect(rec.sha256Before, isNotNull);
      expect(rec.relPath, contains('a.dart'));
      // bytes no snapshot == bytes originais (cópia REAL, não referência)
      final snap = File(rec.snapshotPath);
      expect(snap.existsSync(), isTrue);
      expect(snap.readAsStringSync(), 'void main() {}');
      expect(File('${dirname(snap.path)}/manifest.json').existsSync(), isTrue);

      // apagar o original não afeta o snapshot (independência total)
      f.deleteSync();
      expect(snap.existsSync(), isTrue);
    });

    test('arquivo inexistente => existedBefore=false, sem before.bin',
        () async {
      if (!SqliteNative.available) return;
      final rec = await store.create(
          workspaceRoot: ws.path, absPath: '${ws.path}/novo.dart');
      expect(rec.existedBefore, isFalse);
      expect(rec.sha256Before, isNull);
      expect(File(rec.snapshotPath).existsSync(), isFalse);
    });

    test('caminho fora do workspace => falha tipada, nada gravado', () async {
      if (!SqliteNative.available) return;
      Object? err;
      try {
        await store.create(
            workspaceRoot: ws.path, absPath: '${tmp.path}/outside/x.txt');
      } on VtFailure catch (e) {
        err = e;
      }
      expect(err, isA<VtFailure>());
      expect((err as VtFailure).code, VtErrorCode.pathOutOfSandbox);
      expect(store.list().where((r) => r.relPath.contains('outside')), isEmpty);
    });
  });

  group('restore', () {
    test('rollback limpo restaura bytes exatos e remove registro+snapshot',
        () async {
      if (!SqliteNative.available) return;
      final f = seed('b.txt', 'CONTEUDO-ORIGINAL');
      final rec = await store.create(workspaceRoot: ws.path, absPath: f.path);
      // "write destrutivo" do mundo real:
      f.writeAsStringSync('CORROMPIDO-PELO-AGENT');
      await store.markAfter(rec.id, absPath: f.path);

      final out = await store.restore(rec.id);
      expect(f.readAsStringSync(), 'CONTEUDO-ORIGINAL');
      expect(out.removedFile, isFalse);
      expect(out.wasDrifted, isFalse);
      expect(store.get(rec.id), isNull); // consumido: não há duplo rollback
      expect(Directory(dirname(rec.snapshotPath)).existsSync(), isFalse);
    });

    test('drift sem force => VtFailure checkpoint_failed, arquivo intocado',
        () async {
      if (!SqliteNative.available) return;
      final f = seed('c.txt', 'v1');
      final rec = await store.create(workspaceRoot: ws.path, absPath: f.path);
      await store.markAfter(rec.id, absPath: f.path);
      f.writeAsStringSync('v1'); // write idempotente, after == v1
      // usuário/editor mudou depois disso:
      f.writeAsStringSync('EDICAO-HUMANA-PRECIOSA');

      Object? err;
      try {
        await store.restore(rec.id);
      } on VtFailure catch (e) {
        err = e;
      }
      expect(err, isA<VtFailure>());
      expect((err as VtFailure).code, VtErrorCode.checkpointFailed);
      expect(err.recoveryActions, isNotEmpty);
      // NADA foi tocado sem decisão explícita:
      expect(f.readAsStringSync(), 'EDICAO-HUMANA-PRECIOSA');
      expect(store.get(rec.id), isNotNull);
    });

    test('drift com force assume o risco e restaura mesmo assim', () async {
      if (!SqliteNative.available) return;
      final f = seed('d.txt', 'original');
      final rec = await store.create(workspaceRoot: ws.path, absPath: f.path);
      await store.markAfter(rec.id, absPath: f.path);
      f.writeAsStringSync('mudanca-posterior');

      final out = await store.restore(rec.id, force: true);
      expect(f.readAsStringSync(), 'original');
      expect(out.wasDrifted, isTrue);
    });

    test('arquivo criado pelo write: restore REMOVE (rollback completo)',
        () async {
      if (!SqliteNative.available) return;
      final path = '${ws.path}/gerado.dart';
      final rec = await store.create(workspaceRoot: ws.path, absPath: path);
      File(path).writeAsStringSync('coisa que o agent inventou');
      await store.markAfter(rec.id, absPath: path);

      final out = await store.restore(rec.id);
      expect(File(path).existsSync(), isFalse);
      expect(out.removedFile, isTrue);
    });

    test('checkpoint inexistente => validationFailed', () async {
      if (!SqliteNative.available) return;
      Object? err;
      try {
        await store.restore('ckpt-nao-existe');
      } on VtFailure catch (e) {
        err = e;
      }
      expect((err as VtFailure).code, VtErrorCode.validationFailed);
    });

    test('snapshot perdido em disco => falha honesta, alvo intocado', () async {
      if (!SqliteNative.available) return;
      final f = seed('e.txt', 'precioso');
      final rec = await store.create(workspaceRoot: ws.path, absPath: f.path);
      await store.markAfter(rec.id, absPath: f.path);
      f.writeAsStringSync('estragado');
      File(rec.snapshotPath).deleteSync(); // corrupção externa do snapshot

      Object? err;
      try {
        await store.restore(rec.id);
      } on VtFailure catch (e) {
        err = e;
      }
      expect((err as VtFailure).code, VtErrorCode.checkpointFailed);
      expect(f.readAsStringSync(), 'estragado'); // nada destruído por engano
    });
  });

  group('list / purge', () {
    test('lista mais recentes primeiro e filtra por workspace', () async {
      if (!SqliteNative.available) return;
      final f = seed('x.txt', 'x');
      await store.create(workspaceRoot: ws.path, absPath: f.path, id: 'ck1');
      await store.create(
          workspaceRoot: ws.path, absPath: f.path, id: 'ck2', reason: 'r2');
      final all = store.list(workspaceRoot: ws.path);
      expect(all.length, 2);
      expect(all.map((r) => r.id).toSet(), {'ck1', 'ck2'});
      expect(store.list(workspaceRoot: '/outra-raiz'), isEmpty);
    });

    test('purgeOlderThan remove registros antigos + snapshots, mantém novos',
        () async {
      if (!SqliteNative.available) return;
      final f = seed('y.txt', 'y');
      final old = await store.create(workspaceRoot: ws.path, absPath: f.path);
      // envelhece artificialmente o registro antigo:
      db.execute('UPDATE checkpoints SET created_at = ? WHERE id = ?',
          ['2000-01-01T00:00:00.000Z', old.id]);
      final fresh = await store.create(workspaceRoot: ws.path, absPath: f.path);

      final purged = store.purgeOlderThan(const Duration(days: 7));
      expect(purged, 1);
      expect(store.get(old.id), isNull);
      expect(Directory(dirname(old.snapshotPath)).existsSync(), isFalse);
      expect(store.get(fresh.id), isNotNull);
    });
  });

  group('markAfter', () {
    test('id desconhecido é no-op silencioso (nunca quebra um write já feito)',
        () async {
      if (!SqliteNative.available) return;
      await store.markAfter('ckpt-fantasma', absPath: '${ws.path}/nada.txt');
      expect(store.get('ckpt-fantasma'), isNull);
    });

    test('após write, drift some (after == conteúdo atual)', () async {
      if (!SqliteNative.available) return;
      final f = seed('z.txt', 'antes');
      final rec = await store.create(workspaceRoot: ws.path, absPath: f.path);
      f.writeAsStringSync('depois');
      await store.markAfter(rec.id, absPath: f.path);
      expect(store.checkDrift(store.get(rec.id)!), CheckpointDrift.none);
    });
  });
}
