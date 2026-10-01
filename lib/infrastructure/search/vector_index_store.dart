/// Índice vetorial do workspace sobre o SQLite local (local-first).
///
/// Embeddings REAIS vêm de um [EmbeddingProvider] configurado — nunca são
/// fabricados. Sem provider verificado, [isReady] é false e a busca cai para
/// léxica pura ([CodeIndexStore.searchSymbols]) com `mode: "lexical"` honesto.
///
/// Similaridade = cosseno calculado em Dart sobre BLOBs little-endian float32
/// (portável, sem extensão SQLite). Escala local (milhares de chunks) não
/// precisa de ANN; se precisar, troca-se só esta classe.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../native/sqlite_native.dart';
import '../provider/provider_contract.dart';
import 'code_index_store.dart';

const kVectorSchema = '''
CREATE TABLE IF NOT EXISTS vec_chunks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  document_id INTEGER NOT NULL REFERENCES idx_documents(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  text TEXT NOT NULL,
  embedding BLOB NOT NULL,
  model_id TEXT NOT NULL,
  dims INTEGER NOT NULL,
  UNIQUE(document_id, ordinal)
);
CREATE INDEX IF NOT EXISTS vec_chunks_model ON vec_chunks(model_id);
CREATE TABLE IF NOT EXISTS vec_meta (
  document_id INTEGER PRIMARY KEY REFERENCES idx_documents(id) ON DELETE CASCADE,
  hash TEXT NOT NULL,
  model_id TEXT NOT NULL
);
''';

class SemanticHit {
  const SemanticHit({
    required this.documentPath,
    required this.ordinal,
    required this.text,
    required this.similarity,
    required this.lexicalScore,
    required this.blend,
  });

  final String documentPath;
  final int ordinal;
  final String text;

  /// similaridade de cosseno no espaço do modelo de embedding (0..1 após clamp)
  final double similarity;

  /// score léxico original do índice de símbolos (escala própria)
  final double lexicalScore;

  /// pontuação combinada usada na ordenação final
  final double blend;

  Map<String, Object?> toJson() => {
        'path': documentPath,
        'ordinal': ordinal,
        'similarity': double.parse(similarity.toStringAsFixed(4)),
        'lexical': double.parse(lexicalScore.toStringAsFixed(2)),
        'blend': double.parse(blend.toStringAsFixed(4)),
        'excerpt': text.length > 240 ? '${text.substring(0, 240)}…' : text,
      };
}

/// Chunking simples e determinístico por linha (janela deslizante com
/// overlap). Determinístico importa: mesmo arquivo → mesmos chunks →
/// embeddings reutilizáveis por hash.
List<String> chunkByLines(String content,
    {int maxLines = 40, int overlapLines = 8}) {
  final lines = const LineSplitter().convert(content);
  if (lines.isEmpty) return const [];
  if (lines.length <= maxLines) return [content];
  final out = <String>[];
  final step = math.max(1, maxLines - overlapLines);
  for (var i = 0; i < lines.length; i += step) {
    final end = math.min(i + maxLines, lines.length);
    out.add(lines.sublist(i, end).join('\n'));
    if (end == lines.length) break;
  }
  return out;
}

Uint8List encodeVector(List<double> v) {
  final bd = ByteData(v.length * 4);
  for (var i = 0; i < v.length; i++) {
    bd.setFloat32(i * 4, v[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

List<double> decodeVector(Uint8List blob) {
  final bd = ByteData.sublistView(blob);
  return List.generate(bd.lengthInBytes ~/ 4, (i) => bd.getFloat32(i * 4, Endian.little), growable: false);
}

double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

class VectorIndexStore {
  VectorIndexStore(this.db, this.symbols) {
    db.execute(kVectorSchema);
  }

  final SqliteDb db;
  final CodeIndexStore symbols;

  /// Modelo de embedding efetivo já persistido no índice (ou null = vazio).
  String? get indexedModel {
    final r = db.query(
        'SELECT model_id FROM vec_chunks LIMIT 1');
    return r.isEmpty ? null : r.first['model_id'] as String;
  }

  int get chunkCount {
    final r =
        db.query('SELECT COUNT(*) AS n FROM vec_chunks').single['n'] as String;
    return int.parse(r);
  }

  bool get hasVectors => chunkCount > 0;

  /// Reindexa semanticamente os documentos alterados/removidos desde o último
  /// embedWorkspace. Retorna estatísticas reais.
  Future<Map<String, Object?>> embedWorkspace({
    required String workspaceId,
    required EmbeddingProvider embedder,
    int maxChunksPerFile = 64,
    int maxChunkBytes = 16 * 1024,
  }) async {
    final sw = Stopwatch()..start();
    final caps = embedder.embeddingCapabilities.dimensions != null
        ? embedder.embeddingCapabilities
        : await embedder.verifyEmbeddings();
    final model = embedder.embeddingModelId;

    // documentos novos/alterados (hash ≠ hash embutido) ou órfãos de modelo
    final docs = db.query(
      'SELECT id, path, hash FROM idx_documents WHERE workspace_id = ?',
      [workspaceId],
    );
    final stale = <Map<String, Object?>>[];
    for (final d in docs) {
      final embedded = db.query(
        'SELECT hash, model_id FROM vec_meta WHERE document_id = ?',
        ['${d['id']}'],
      );
      if (embedded.isEmpty ||
          embedded.single['hash'] != d['hash'] ||
          embedded.single['model_id'] != model) {
        stale.add(d);
      }
    }
    db.execute('DELETE FROM vec_meta', const []);
    for (final d in docs) {
      db.execute(
        'INSERT OR REPLACE INTO vec_meta (document_id, hash, model_id) VALUES (?,?,?)',
        ['${d['id']}', d['hash'] as String, model],
      );
    }

    var filesEmbedded = 0, chunksEmbedded = 0;
    for (final d in stale) {
      final docId = int.parse(d['id'] as String);
      final full = _readFile(workspaceId, d['path'] as String);
      db.execute('DELETE FROM vec_chunks WHERE document_id = ?', ['$docId']);
      if (full == null) continue;
      var chunks = chunkByLines(full);
      if (chunks.length > maxChunksPerFile) {
        chunks = chunks.sublist(0, maxChunksPerFile);
      }
      chunks = chunks
          .where((c) => c.trim().isNotEmpty && c.length <= maxChunkBytes)
          .toList();
      if (chunks.isEmpty) continue;
      final vectors = await embedder.embed(texts: chunks);
      for (var i = 0; i < chunks.length; i++) {
        db.execute(
          'INSERT INTO vec_chunks (document_id, ordinal, text, embedding, model_id, dims) '
          'VALUES (?,?,?,?,?,?)',
          [
            '$docId',
            '$i',
            chunks[i],
            base64.encode(encodeVector(vectors[i])),
            model,
            '${caps.dimensions}',
          ],
        );
      }
      filesEmbedded++;
      chunksEmbedded += chunks.length;
    }

    // remove chunks de documentos que saíram do índice
    db.execute(
      'DELETE FROM vec_chunks WHERE document_id NOT IN '
      '(SELECT id FROM idx_documents WHERE workspace_id = ?)',
      [workspaceId],
    );

    sw.stop();
    return {
      'model': model,
      'dimensions': caps.dimensions,
      'staleFiles': stale.length,
      'filesEmbedded': filesEmbedded,
      'chunksEmbedded': chunksEmbedded,
      'totalChunks': chunkCount,
      'elapsedMs': sw.elapsedMilliseconds,
    };
  }

  String? _readFile(String workspaceRoot, String relPath) {
    try {
      return File('${workspaceRoot.replaceAll(RegExp(r'/+$'), '')}/$relPath')
          .readAsStringSync();
    } catch (_) {
      return null; // arquivo sumido/inacessível → sem chunks (nunca finge)
    }
  }

  /// Busca HÍBRIDA: fusão ponderada de cosseno (semântica) + ranking léxico
  /// de símbolos. Se o índice vetorial está vazio/modelo trocado, degrada
  /// para modo lexical puro, reportado honestamente em `mode`.
  Future<Map<String, Object?>> hybridSearch({
    required String workspaceId,
    required String query,
    EmbeddingProvider? embedder,
    int topK = 15,
    String? kind,
    double vectorWeight = 0.6,
    double lexicalWeight = 0.4,
  }) async {
    final lexPage = symbols.searchSymbols(
      workspaceId: workspaceId,
      query: query,
      kind: kind,
      pageSize: topK * 2,
    );
    final lexMax = lexPage.items
        .map((h) => h.score)
        .fold<double>(0, (m, s) => s > m ? s : m);

    var mode = 'lexical';
    final byPath = <String, double>{}; // melhor cosseno por documento
    if (embedder != null && hasVectors) {
      final ok = embedder.embeddingModelId == indexedModel;
      if (ok) {
        final qv = (await embedder.embed(texts: [query])).first;
        for (final r in db.query(
          'SELECT embedding, document_id FROM vec_chunks WHERE model_id = ?',
          [embedder.embeddingModelId],
        )) {
          final sim = cosineSimilarity(qv, decodeVector(
              base64.decode(r['embedding'] as String)));
          final path = db.query(
            'SELECT path FROM idx_documents WHERE id = ?',
            ['${r['document_id']}'],
          ).single['path'] as String;
          if ((sim.clamp(0, 1)) > (byPath[path] ?? -1)) {
            byPath[path] = sim.clamp(0, 1);
          }
        }
        mode = 'hybrid';
      }
      // modelo trocado → mantém lexical puro (reindex necessário), reportado
    }

    final hits = <SemanticHit>[];
    final seen = <String>{};
    for (final h in lexPage.items) {
      final lex = lexMax > 0 ? h.score / lexMax : 0.0;
      final vec = byPath[h.documentPath] ?? 0.0;
      hits.add(SemanticHit(
        documentPath: h.documentPath,
        ordinal: h.line,
        text: h.signature,
        similarity: vec,
        lexicalScore: h.score,
        blend: vectorWeight * vec + lexicalWeight * lex,
      ));
      seen.add(h.documentPath);
    }
    // documentos semanticamente fortes mas sem match léxico nenhum
    final extra = byPath.entries
        .where((e) => !seen.contains(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in extra.take(topK)) {
      hits.add(SemanticHit(
        documentPath: e.key,
        ordinal: 0,
        text: '',
        similarity: e.value,
        lexicalScore: 0,
        blend: vectorWeight * e.value,
      ));
    }
    hits.sort((a, b) => b.blend.compareTo(a.blend));
    return {
      'mode': mode, // hybrid | lexical (honesto sobre o que realmente rodou)
      'query': query,
      'results': hits.take(topK).map((h) => h.toJson()).toList(),
      'vectorCandidates': byPath.length,
      'lexicalCandidates': lexPage.items.length,
    };
  }

  void purgeAll() {
    db.execute('DELETE FROM vec_chunks', const []);
    db.execute('DELETE FROM vec_meta', const []);
  }
}
