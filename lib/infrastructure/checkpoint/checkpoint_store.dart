/// Sistema de checkpoints do techVT (spec catálogo: ToolCategory.checkpoint).
///
/// Rollback seguro para escritas destrutivas ANTES de qualquer git operação:
/// - snapshot real dos bytes do arquivo (cópia em `<dataDir>/checkpoints/<id>/`);
/// - metadados + hash SHA-256 pré/post no SQLite local (sem fallback em memória);
/// - restore atômico com verificação de drift: se o arquivo mudou desde o
///   snapshot, restaurar exige `force` explícito — nunca sobrescreve trabalho
///   alheio silenciosamente;
/// - arquivos que não existiam antes são removidos no restore (só quando o
///   conteúdo atual bate com o pós-write registrado ou o usuário assumiu o
///   risco com force).
///
/// O store NÃO conhece a UI nem o agent loop: é infraestrutura pura, usada
/// pelas tools `checkpoint.*` e invocável por qualquer caller (chat_service,
/// modo headless, testes).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../domain/errors/vt_failure.dart';
import '../native/sqlite_native.dart';
import '../process/process_utils.dart';

const kCheckpointSchema = '''
CREATE TABLE IF NOT EXISTS checkpoints (
  id TEXT PRIMARY KEY,
  workspace_root TEXT NOT NULL,
  rel_path TEXT NOT NULL,
  abs_path TEXT NOT NULL,
  existed_before INTEGER NOT NULL,
  sha256_before TEXT,
  sha256_after TEXT,
  snapshot_path TEXT NOT NULL,
  reason TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_checkpoints_ws ON checkpoints(workspace_root, rel_path);
''';

enum CheckpointDrift {
  /// Conteúdo atual == hash pós-write registrado (ou situação equivalente
  /// segura). Restore limpo.
  none,

  /// Arquivo mudou desde o checkpoint. Restore só com force.
  modified,

  /// Arquivo sumiu do disco embora devesse existir. Restore recria.
  missing,
}

class CheckpointRecord {
  const CheckpointRecord({
    required this.id,
    required this.workspaceRoot,
    required this.relPath,
    required this.absPath,
    required this.existedBefore,
    required this.sha256Before,
    required this.sha256After,
    required this.snapshotPath,
    required this.reason,
    required this.createdAt,
  });

  final String id;
  final String workspaceRoot;
  final String relPath;
  final String absPath;

  /// false => o arquivo foi CRIADO pelo write original (não existia antes).
  final bool existedBefore;
  final String? sha256Before;
  final String? sha256After;
  final String snapshotPath;
  final String reason;
  final String createdAt;

  static CheckpointRecord fromRow(Map<String, Object?> row) => CheckpointRecord(
        id: row['id'] as String,
        workspaceRoot: row['workspace_root'] as String,
        relPath: row['rel_path'] as String,
        absPath: row['abs_path'] as String,
        existedBefore: (row['existed_before'] as String?) == '1',
        sha256Before: _nullIfEmpty(row['sha256_before'] as String?),
        sha256After: _nullIfEmpty(row['sha256_after'] as String?),
        snapshotPath: row['snapshot_path'] as String,
        reason: (row['reason'] as String?) ?? '',
        createdAt: row['created_at'] as String,
      );

  static String? _nullIfEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

  Map<String, Object?> toJson() => {
        'id': id,
        'workspaceRoot': workspaceRoot,
        'path': relPath,
        'existedBefore': existedBefore,
        'sha256Before': sha256Before,
        'sha256After': sha256After,
        'reason': reason,
        'createdAt': createdAt,
      };
}

class CheckpointStore {
  CheckpointStore(this.db, {required this.dataDir}) {
    db.execute(kCheckpointSchema);
  }

  final SqliteDb db;
  final String dataDir;

  String get _rootDir => joinPath(dataDir, 'checkpoints');

  static String _isoNow() => DateTime.now().toUtc().toIso8601String();

  static String _hash(List<int> bytes) => sha256.convert(bytes).toString();

  /// Id de checkpoint ordenável no tempo (UTC compacto + sufixo variável).
  static String newId() {
    final now = DateTime.now().toUtc();
    final ts = now.toIso8601String().replaceAll(RegExp(r'[-:.TZ]'), '');
    final rnd = (now.microsecondsSinceEpoch % 0xFFFFFF).toRadixString(16);
    return 'ckpt-$ts-$rnd';
  }

  Future<CheckpointRecord> create({
    required String workspaceRoot,
    required String absPath,
    String reason = '',
    String? id,
  }) async {
    final ckptId = id ?? newId();
    final normalizedAbs = normalizeSlashes(absPath);
    final normalizedRoot = normalizeSlashes(workspaceRoot);
    final rel = relativePath(normalizedAbs, normalizedRoot);
    if (rel.startsWith('..')) {
      throw VtFailure.pathOutOfSandbox(absPath);
    }

    final file = File(normalizedAbs);
    final existed = await file.exists();
    final bytes = existed ? await file.readAsBytes() : null;
    final shaBefore = bytes == null ? null : _hash(bytes);

    final dir = Directory(joinPath(_rootDir, ckptId));
    await dir.create(recursive: true);
    final snapPath = joinPath(dir.path, 'before.bin');
    if (bytes != null) {
      await File(snapPath).writeAsBytes(bytes);
    }
    // manifest legível por humano ao lado dos bytes (forense de rollback).
    await File(joinPath(dir.path, 'manifest.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'id': ckptId,
        'workspaceRoot': normalizedRoot,
        'path': rel,
        'existedBefore': existed,
        'sha256Before': shaBefore,
        'reason': reason,
        'createdAt': _isoNow(),
      }),
    );

    db.execute(
      'INSERT INTO checkpoints (id, workspace_root, rel_path, abs_path, '
      'existed_before, sha256_before, sha256_after, snapshot_path, reason, '
      'created_at) VALUES (?,?,?,?,?,?,?,?,?,?)',
      [
        ckptId,
        normalizedRoot,
        rel,
        normalizedAbs,
        existed ? '1' : '0',
        shaBefore ?? '',
        shaBefore ?? '', // pós-inicial = pré até markAfter registrar o write
        snapPath,
        reason,
        _isoNow(),
      ],
    );

    return get(ckptId)!;
  }

  /// Registra o hash PÓS-write de um checkpoint existente (chamado pela tool
  /// de escrita logo após gravar). Id inexistente => no-op: registrar o "after"
  /// jamais pode quebrar um write já concluído.
  Future<void> markAfter(String id, {required String absPath}) async {
    final rec = get(id);
    if (rec == null) return;
    final f = File(normalizeSlashes(absPath));
    final sha = await f.exists() ? _hash(await f.readAsBytes()) : '';
    db.execute('UPDATE checkpoints SET sha256_after = ? WHERE id = ?',
        [sha, id]);
  }

  CheckpointRecord? get(String id) {
    final rows = db.query('SELECT * FROM checkpoints WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return CheckpointRecord.fromRow(rows.single);
  }

  List<CheckpointRecord> list({String? workspaceRoot, int limit = 50}) {
    final sql = workspaceRoot == null
        ? 'SELECT * FROM checkpoints ORDER BY created_at DESC LIMIT ?'
        : 'SELECT * FROM checkpoints WHERE workspace_root = ? '
            'ORDER BY created_at DESC LIMIT ?';
    final params = workspaceRoot == null
        ? ['$limit']
        : [normalizeSlashes(workspaceRoot), '$limit'];
    return db
        .query(sql, params)
        .map(CheckpointRecord.fromRow)
        .toList(growable: false);
  }

  CheckpointDrift checkDrift(CheckpointRecord rec) {
    final f = File(rec.absPath);
    if (!f.existsSync()) {
      if (!rec.existedBefore) return CheckpointDrift.none;
      return CheckpointDrift.missing;
    }
    final current = _hash(f.readAsBytesSync());
    if (current == rec.sha256After) return CheckpointDrift.none;
    return CheckpointDrift.modified;
  }

  /// Restaura o estado pré-write.
  ///
  /// [force] é obrigatório quando há drift `modified`: sem ele a falha é
  /// tipada (`checkpoint_failed`) — o usuário decide; o sistema nunca escolhe
  /// sozinho destruir edições posteriores.
  Future<RestoreOutcome> restore(String id, {bool force = false}) async {
    final rec = get(id);
    if (rec == null) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Checkpoint "$id" não existe no banco local.',
      );
    }
    final drift = checkDrift(rec);
    if (drift == CheckpointDrift.modified && !force) {
      throw VtFailure(
        code: VtErrorCode.checkpointFailed,
        message: 'O arquivo "${rec.relPath}" mudou desde o checkpoint '
            '(hash atual difere do registrado). Restaurar agora descartaria '
            'essas edições.',
        retryable: true,
        recoveryActions: const [
          RecoveryAction(
              kind: 'retry',
              label: 'Restaurar mesmo assim (force) — descarta edições'),
        ],
        details: {'drift': 'modified', 'checkpoint': rec.id},
      );
    }

    if (!rec.existedBefore) {
      // Arquivo criado pelo write original: o rollback correto é REMOVER.
      final f = File(rec.absPath);
      if (await f.exists()) await f.delete();
      _deleteSnapshotDir(rec);
      return RestoreOutcome(
        restored: rec,
        removedFile: true,
        wasDrifted: drift != CheckpointDrift.none,
      );
    }

    final snap = File(rec.snapshotPath);
    if (!await snap.exists()) {
      throw VtFailure(
        code: VtErrorCode.checkpointFailed,
        message: 'Snapshot em disco perdido ("${rec.snapshotPath}"). '
            'Sem os bytes originais não há rollback honesto — nada foi '
            'alterado no workspace.',
        recoveryActions: const [
          RecoveryAction(kind: 'open_logs', label: 'Abrir pasta de dados'),
        ],
      );
    }
    final bytes = await snap.readAsBytes();
    final target = File(rec.absPath);
    await target.parent.create(recursive: true);
    // Escrita temporária + rename = troca atômica (editores nunca veem meio
    // arquivo).
    final tmp = File('${rec.absPath}.techvt-restore.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(rec.absPath);

    _deleteSnapshotDir(rec);
    return RestoreOutcome(
      restored: rec,
      removedFile: false,
      wasDrifted: drift != CheckpointDrift.none,
    );
  }

  void _deleteSnapshotDir(CheckpointRecord rec) {
    try {
      Directory(dirname(rec.snapshotPath)).deleteSync(recursive: true);
    } on FileSystemException {
      // melhor esforço em disco; o registro do banco é removido sempre abaixo.
    }
    db.execute('DELETE FROM checkpoints WHERE id = ?', [rec.id]);
  }

  /// Remove registros + snapshots mais antigos que [maxAge]. Retorna quantos
  /// registros foram purgados.
  int purgeOlderThan(Duration maxAge) {
    final cutoff = DateTime.now().toUtc().subtract(maxAge).toIso8601String();
    final stale = db
        .query('SELECT * FROM checkpoints WHERE created_at < ?', [cutoff])
        .map(CheckpointRecord.fromRow)
        .toList(growable: false);
    for (final r in stale) {
      try {
        Directory(dirname(r.snapshotPath)).deleteSync(recursive: true);
      } on FileSystemException {
        continue;
      }
      db.execute('DELETE FROM checkpoints WHERE id = ?', [r.id]);
    }
    return stale.length;
  }
}

class RestoreOutcome {
  const RestoreOutcome({
    required this.restored,
    required this.removedFile,
    required this.wasDrifted,
  });
  final CheckpointRecord restored;

  /// true => o "restore" foi uma remoção (arquivo não existia antes do write).
  final bool removedFile;

  /// true => houve drift resolvido por force (edições posteriores perdidas).
  final bool wasDrifted;
}
