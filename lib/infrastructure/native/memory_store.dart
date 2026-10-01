/// Memória local-first do techVT (spec: "memórias" em SQLite).
///
/// Armazena memórias de longo prazo por workspace com busca lexical ponderada
/// (tokens da query × título/palavras-chave/corpo) e reforço de recall: cada
/// vez que uma memória é recuperada, seu peso de relevância aumenta com
/// decaimento temporal — recall ranking heurístico real, sem embeddings
/// fingidos. Toda persistência passa pelo [SqliteDb] nativo; sem fallback em
/// memória.
library;

import 'dart:convert';

import '../../domain/models/pagination.dart';
import 'sqlite_native.dart';

const kMemorySchema = '''
CREATE TABLE IF NOT EXISTS memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  workspace_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  tags TEXT NOT NULL DEFAULT '[]',
  weight REAL NOT NULL DEFAULT 1.0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_recalled_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_memories_ws ON memories(workspace_id);
''';

class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.workspaceId,
    required this.kind,
    required this.title,
    required this.body,
    required this.tags,
    required this.weight,
    required this.createdAt,
    required this.updatedAt,
    this.lastRecalledAt,
  });

  final int id;
  final String workspaceId;
  final String kind; // fact|preference|procedure|decision
  final String title;
  final String body;
  final List<String> tags;
  final double weight;
  final String createdAt;
  final String updatedAt;
  final String? lastRecalledAt;

  static MemoryRecord fromRow(Map<String, Object?> row) => MemoryRecord(
        id: int.parse(row['id'] as String),
        workspaceId: row['workspace_id'] as String,
        kind: row['kind'] as String,
        title: row['title'] as String,
        body: row['body'] as String,
        tags: (jsonDecode(row['tags'] as String? ?? '[]') as List)
            .cast<String>(),
        weight: double.parse((row['weight'] as String?) ?? '1'),
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
        lastRecalledAt: row['last_recalled_at'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'workspaceId': workspaceId,
        'kind': kind,
        'title': title,
        'body': body,
        'tags': tags,
        'weight': weight,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'lastRecalledAt': lastRecalledAt,
      };
}

/// Tokenização lexical mínima: minúsculas, alfanumérico, descarta stopwords
/// curtas demais. Realista para busca em nomes/símbolos de código.
List<String> tokenizeLexical(String text) {
  return text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9_]+'))
      .where((t) => t.length >= 2)
      .toList(growable: false);
}

class MemoryStore {
  MemoryStore(this.db) {
    db.execute(kMemorySchema);
  }

  final SqliteDb db;

  static String _isoNow() => DateTime.now().toUtc().toIso8601String();

  /// Cria ou atualiza (quando [id] informado) uma memória. Retorna o registro.
  MemoryRecord upsert({
    int? id,
    required String workspaceId,
    required String kind,
    required String title,
    required String body,
    List<String> tags = const [],
    double weight = 1.0,
  }) {
    final now = _isoNow();
    if (id == null) {
      db.execute(
        'INSERT INTO memories (workspace_id, kind, title, body, tags, weight, '
        'created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)',
        [
          workspaceId,
          kind,
          title,
          body,
          jsonEncode(tags),
          weight.toString(),
          now,
          now,
        ],
      );
      final rows = db.query('SELECT last_insert_rowid() AS id');
      return get(int.parse(rows.single['id'] as String))!;
    }
    final existing = get(id);
    if (existing == null) {
      throw SqliteException(1, 'memória $id não existe');
    }
    db.execute(
      'UPDATE memories SET kind=?, title=?, body=?, tags=?, weight=?, '
      'updated_at=? WHERE id=?',
      [
        kind,
        title,
        body,
        jsonEncode(tags),
        weight.toString(),
        now,
        id.toString(),
      ],
    );
    return get(id)!;
  }

  MemoryRecord? get(int id) {
    final rows = db.query('SELECT * FROM memories WHERE id=?', ['$id']);
    return rows.isEmpty ? null : MemoryRecord.fromRow(rows.first);
  }

  bool delete(int id) {
    db.execute('DELETE FROM memories WHERE id=?', ['$id']);
    return db.changes > 0;
  }

  /// Busca lexical com score composto (Page do modelo único de paginação):
  /// - match exato de token no título: +3.0, substring: +1.5
  /// - match em tag: +2.0
  /// - match no corpo: +1.0 por ocorrência (cap 5)
  /// - multiplicado pelo peso salvo; bônus de reforço de recall recente.
  /// Atualiza `last_recalled_at` e reforça o peso das retornadas.
  Page<MemoryRecord> search({
    required String workspaceId,
    String query = '',
    String? kind,
    int pageSize = 10,
    bool reinforce = true,
  }) {
    final where = <String>['workspace_id = ?'];
    final params = <String>[workspaceId];
    if (kind != null) {
      where.add('kind = ?');
      params.add(kind);
    }
    final rows = db.query(
      'SELECT * FROM memories WHERE ${where.join(' AND ')}',
      params,
    );
    final tokens = tokenizeLexical(query);
    final scored = <(MemoryRecord, double)>[];
    for (final row in rows) {
      final rec = MemoryRecord.fromRow(row);
      var score = 0.0;
      if (tokens.isEmpty) {
        score = rec.weight; // sem query: ordena por peso puro
      } else {
        final titleLower = rec.title.toLowerCase();
        final bodyLower = rec.body.toLowerCase();
        final tagText = rec.tags.join(' ').toLowerCase();
        for (final t in tokens) {
          if (titleLower.split(RegExp(r'[^a-z0-9_]+')).contains(t)) {
            score += 3.0;
          } else if (titleLower.contains(t)) {
            score += 1.5;
          }
          if (tagText.contains(t)) score += 2.0;
          final bodyHits = RegExp(RegExp.escape(t)).allMatches(bodyLower).length;
          if (bodyHits > 0) score += bodyHits.clamp(1, 5) * 1.0;
        }
        score *= rec.weight;
        // Reforço de recall: acessos recentes elevam levemente o ranking.
        if (rec.lastRecalledAt != null) {
          final ageH = _hoursSince(rec.lastRecalledAt!);
          if (ageH != null && ageH < 24 * 30) {
            score *= 1.0 + 0.2 / (1.0 + ageH / 24.0);
          }
        }
      }
      if (score > 0 || tokens.isEmpty) scored.add((rec, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final items =
        scored.take(pageSize).map((e) => e.$1).toList(growable: false);
    if (reinforce && items.isNotEmpty) {
      final now = _isoNow();
      for (final rec in items) {
        // Reforço assintótico: peso cresce até teto 5.0 (+0.05 por recall).
        final w = (rec.weight + 0.05).clamp(0.0, 5.0);
        db.execute(
          'UPDATE memories SET weight=?, last_recalled_at=? WHERE id=?',
          [w.toString(), now, '${rec.id}'],
        );
      }
    }
    return Page(
      items: items,
      pageSize: pageSize,
      prevCursor: null,
      nextCursor: null, // ranking por score não é paginável por cursor
      hasMore: scored.length > items.length,
      totalEstimate: scored.length,
    );
  }

  /// Reforço de recall pontual: +peso (teto 5.0) e timestamp de acesso.
  void recall(int id) {
    final rec = get(id);
    if (rec == null) return;
    final w = (rec.weight + 0.05).clamp(0.0, 5.0);
    db.execute(
      'UPDATE memories SET weight=?, last_recalled_at=? WHERE id=?',
      [w.toString(), _isoNow(), '$id'],
    );
  }

  /// Estatísticas por kind: contagem e peso médio do workspace.
  List<Map<String, Object?>> stats({required String workspaceId}) => db.query(
        'SELECT kind, COUNT(*) AS count, AVG(weight) AS avg_weight '
        'FROM memories WHERE workspace_id=? GROUP BY kind ORDER BY count DESC',
        [workspaceId],
      );

  static double? _hoursSince(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return null;
    return DateTime.now().toUtc().difference(t).inMinutes / 60.0;
  }
}
