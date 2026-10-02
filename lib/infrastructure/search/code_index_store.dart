/// Índice de código do workspace (spec catálogo: codeIndex).
///
/// Varredura real do filesystem com índice incremental em SQLite:
/// - hash SHA-256 por arquivo; só re-analisa o que mudou entre scans;
/// - símbolos extraídos por heurística determinística de Dart
///   (classes/mixin/enum/função/campo/top-level), sem parser fingido
///   e sem LSP — quando o LSP entrar, ele alimenta a mesma tabela;
/// - busca lexical ponderada (nome do símbolo > assinatura) com paginação
///   no modelo único de paginação [Page].
///
/// Toda persistência passa pelo [SqliteDb] nativo; sem fallback em memória.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../domain/models/pagination.dart';
import '../native/sqlite_native.dart';

const kCodeIndexSchema = '''
CREATE TABLE IF NOT EXISTS idx_documents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  workspace_id TEXT NOT NULL,
  path TEXT NOT NULL,
  hash TEXT NOT NULL,
  size INTEGER NOT NULL,
  mtime_ms INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(workspace_id, path)
);
CREATE TABLE IF NOT EXISTS idx_symbols (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  document_id INTEGER NOT NULL REFERENCES idx_documents(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  line INTEGER NOT NULL,
  signature TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_symbols_doc ON idx_symbols(document_id);
CREATE INDEX IF NOT EXISTS idx_symbols_name ON idx_symbols(name);
''';

class IndexedDocument {
  const IndexedDocument({
    required this.id,
    required this.path,
    required this.hash,
    required this.size,
    required this.mtimeMs,
  });

  final int id;
  final String path; // relativo à raiz, sempre com '/'
  final String hash;
  final int size;
  final int mtimeMs;

  static IndexedDocument fromRow(Map<String, Object?> row) => IndexedDocument(
        id: int.parse(row['id'] as String),
        path: row['path'] as String,
        hash: row['hash'] as String,
        size: int.parse(row['size'] as String),
        mtimeMs: int.parse(row['mtime_ms'] as String),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'path': path,
        'hash': hash,
        'size': size,
        'mtimeMs': mtimeMs,
      };
}

class SymbolHit {
  const SymbolHit({
    required this.name,
    required this.kind,
    required this.line,
    required this.signature,
    required this.documentPath,
    required this.score,
  });

  final String name;
  final String kind;
  final int line;
  final String signature;
  final String documentPath;
  final double score;

  Map<String, Object?> toJson() => {
        'name': name,
        'kind': kind,
        'line': line,
        'signature': signature,
        'file': documentPath,
        'score': score,
      };
}

class ScanStats {
  const ScanStats({
    required this.filesScanned,
    required this.filesUpdated,
    required this.filesRemoved,
    required this.symbolsIndexed,
    required this.elapsed,
  });

  final int filesScanned;
  final int filesUpdated;
  final int filesRemoved;
  final int symbolsIndexed;
  final Duration elapsed;

  Map<String, Object?> toJson() => {
        'filesScanned': filesScanned,
        'filesUpdated': filesUpdated,
        'filesRemoved': filesRemoved,
        'symbolsIndexed': symbolsIndexed,
        'elapsedMs': elapsed.inMilliseconds,
      };
}

/// Símbolos reconhecidos por heurística de linhas em arquivos `.dart`.
/// Padrões ancorados no início da linha (com recuo opcional); um símbolo
/// por linha — a forma canônica do `dart format`. Semântica de escopo não
/// é resolvida aqui: isso é trabalho do LSP, não deste índice lexical.
final List<(RegExp, String)> kDartSymbolPatterns = [
  // declarações estruturais SEMPRE primeiro: `class BaseThing {` casa no
  // padrão de construtor (`Nome(` + `{`) se este vier depois — ordem é
  // precedência.
  (RegExp(r'^\s*abstract\s+class\s+([A-Za-z_$][\w$]*)'), 'class'),
  (RegExp(r'^\s*(?:base\s+|final\s+|sealed\s+|interface\s+)*class\s+([A-Za-z_$][\w$]*)'),
      'class'),
  (RegExp(r'^\s*mixin\s+class\s+([A-Za-z_$][\w$]*)'), 'class'),
  (RegExp(r'^\s*mixin\s+([A-Za-z_$][\w$]*)'), 'mixin'),
  (RegExp(r'^\s*enum\s+([A-Za-z_$][\w$]*)'), 'enum'),
  (RegExp(r'^\s*extension(?:\s+type)?\s+([A-Za-z_$][\w$]*)'), 'extension'),
  (RegExp(r'^\s*typedef\s+([A-Za-z_$][\w$]*)'), 'typedef'),
  // construtor com inicializadores `this.`: `BaseThing(this.name);` — o
  // padrão genérico de função abaixo capturaria o parâmetro (`name`) como
  // nome; este padrão mais específico roda antes dele e devolve o nome real
  // da classe, classificando corretamente como constructor.
  (RegExp(r'^\s*([A-Z][\w$]*)\s*\(\s*this\.[^)]*\)\s*[{:;=]'), 'constructor'),
  // função/método/construtor: nome seguido de lista de parâmetros até ')'
  (
    RegExp(
        r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:static\s+|final\s+|const\s+|late\s+|factory\s+|external\s+)?\s*'
        r'(?:[\w<>?, .]+\s+)?([A-Za-z_$][\w$]*)\s*\((.*)\)\s*(?:async\s*)?[{;=]',
        multiLine: false),
    'function'
  ),

  // campo/variável top-level ou de instância: `Tipo nome = ...;` ou `Tipo nome;`
  (
    RegExp(
        r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:static\s+|final\s+|const\s+|late\s+)*'
        r'[A-Za-z_$][\w$<>, .?]*\s+([A-Za-z_$][\w$]*)\s*(?:=\s*[^;]*)?;\s*$'),
    'field'
  ),
];

/// Extrai símbolos de um conteúdo Dart. Retorna tuplas
/// `(name, kind, line1based, signature)`.
List<(String, String, int, String)> extractDartSymbols(String content) {
  final lines = const LineSplitter().convert(content);
  final out = <(String, String, int, String)>[];
  final seen = <String>{};
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimRight();
    if (line.isEmpty) continue;
    final t = line.trimLeft();
    if (t.startsWith('//') || t.startsWith('///') || t.startsWith('/*')) {
      continue;
    }
    // linha de statement puro (`print(x);`, `return;`) não define símbolo —
    // sem isso, chamadas com identificador único casam no padrão de função.
    if (_isStatementLine(t)) continue;
    for (final (re, kind) in kDartSymbolPatterns) {
      final m = re.firstMatch(line);
      if (m == null) continue;
      final name = m.group(1)!;
      // filtro anti-ruído: keywords/control-flow nunca são nomes reais aqui
      if (_kReserved.contains(name)) break;
      var sig = t;
      if (sig.length > 200) sig = '${sig.substring(0, 200)}…';
      final key = '$kind:$name:$sig';
      if (seen.add(key)) {
        out.add((name, kind, i + 1, sig));
      }
      break; // primeiro padrão que casa vence (mais específico primeiro)
    }
  }
  return out;
}

/// Linhas que são *uso* de código, não definição: statements de controle,
/// chamadas soltas (`print(x);`) e blocos vazios de fechamento. Um único
/// identificador seguido de `(` nestas linhas nunca é nome de símbolo —
/// sem este filtro, `print(x);` viraria uma "função" chamada `print`.
final _kStatementHeads = RegExp(
  r'^(?:if|else|for|while|do|switch|case|default|return|break|continue|try|catch|finally|throw|yield|await)\b'
  r'|^[a-z_$][\w$]*\s*\([^()]*\)\s*;\s*$',
);

bool _isStatementLine(String t) => _kStatementHeads.hasMatch(t);

const _kReserved = {
  'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'default', 'return',
  'break', 'continue', 'try', 'catch', 'finally', 'throw', 'new', 'in', 'is',
  'as', 'await', 'async', 'yield', 'assert', 'void', 'var', 'this', 'super',
  'get', 'set', 'operator', 'library', 'part', 'export', 'import', 'show',
  'hide', 'with', 'on', 'rethrow', 'required',
};

class CodeIndexStore {
  CodeIndexStore(this.db) {
    db.execute(kCodeIndexSchema);
  }

  final SqliteDb db;

  static String _isoNow() => DateTime.now().toUtc().toIso8601String();

  /// Versão do extrator — embutida no hash para invalidar índices antigos
  /// quando os padrões mudarem (reindex automático no primeiro scan).
  static const extractorVersion = "v2";

  /// Scan incremental de [root] (somente `.dart` por ora): indexa apenas
  /// documentos novos/alterados (por mtime + SHA-256) e remove documentos
  /// cujos arquivos sumiram. Estatísticas reais, zero simulação.
  ScanStats scanWorkspace({
    required String workspaceId,
    required String root,
    Set<String> skipDirs = const {
      '.git', 'build', '.dart_tool', 'node_modules', '.idea'
    },
    int maxFileBytes = 2 * 1024 * 1024,
  }) {
    final sw = Stopwatch()..start();
    final existing = {
      for (final r in db.query(
        'SELECT id, path, hash, mtime_ms FROM idx_documents WHERE workspace_id = ?',
        [workspaceId],
      ))
        r['path'] as String: (
          id: int.parse(r['id'] as String),
          hash: r['hash'] as String,
          mtimeMs: int.parse(r['mtime_ms'] as String),
        ),
    };
    var scanned = 0, updated = 0, removed = 0, symbols = 0;
    final seenPaths = <String>{};

    void indexFile(File f, String rel) {
      scanned++;
      seenPaths.add(rel);
      final stat = f.statSync();
      if (stat.size > maxFileBytes) return; // pula gigantes de verdade
      final prev = existing[rel];
      // curto-circuito barato: mtime igual E já indexado → sem re-hash
      if (prev != null &&
          prev.mtimeMs == stat.modified.millisecondsSinceEpoch) {
        return;
      }
      final String content;
      try {
        content = f.readAsStringSync();
      } catch (_) {
        return; // binário/inacessível/encoding — nunca finge sucesso
      }
      final hash =
          '$extractorVersion:${sha256.convert(utf8.encode(content)).toString()}';
      final docId = prev?.id;
      if (prev != null && prev.hash == hash) {
        // conteúdo idêntico (touch): só atualiza mtime p/ acelerar próximo scan
        db.execute(
          'UPDATE idx_documents SET mtime_ms = ?, updated_at = ? WHERE id = ?',
          ['${stat.modified.millisecondsSinceEpoch}', _isoNow(), '${prev.id}'],
        );
        return;
      }
      if (docId == null) {
        db.execute(
          'INSERT INTO idx_documents (workspace_id, path, hash, size, mtime_ms, updated_at) '
          'VALUES (?,?,?,?,?,?)',
          [
            workspaceId,
            rel,
            hash,
            '${stat.size}',
            '${stat.modified.millisecondsSinceEpoch}',
            _isoNow(),
          ],
        );
        final newId = int.parse(
            db.query('SELECT last_insert_rowid() AS id').single['id'] as String);
        symbols += _indexSymbols(newId, content);
      } else {
        db.execute(
          'UPDATE idx_documents SET hash=?, size=?, mtime_ms=?, updated_at=? WHERE id=?',
          [
            hash,
            '${stat.size}',
            '${stat.modified.millisecondsSinceEpoch}',
            _isoNow(),
            '$docId',
          ],
        );
        db.execute('DELETE FROM idx_symbols WHERE document_id = ?', ['$docId']);
        symbols += _indexSymbols(docId, content);
      }
      updated++;
    }

    for (final e in Directory(root)
        .listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (!e.path.endsWith('.dart')) continue;
      final rel = _relative(e.path, root);
      if (rel == null) continue;
      if (rel.split('/').any(skipDirs.contains)) continue;
      indexFile(e, rel);
    }

    // remove documentos cujos arquivos sumiram do disco
    for (final p in existing.keys) {
      if (!seenPaths.contains(p)) {
        db.execute(
          'DELETE FROM idx_documents WHERE workspace_id = ? AND path = ?',
          [workspaceId, p],
        );
        removed++;
      }
    }

    sw.stop();
    return ScanStats(
      filesScanned: scanned,
      filesUpdated: updated,
      filesRemoved: removed,
      symbolsIndexed: symbols,
      elapsed: sw.elapsed,
    );
  }

  int _indexSymbols(int docId, String content) {
    final syms = extractDartSymbols(content);
    for (final (name, kind, line, sig) in syms) {
      db.execute(
        'INSERT INTO idx_symbols (document_id, name, kind, line, signature) '
        'VALUES (?,?,?,?,?)',
        ['$docId', name, kind, '$line', sig],
      );
    }
    return syms.length;
  }

  /// Busca lexical de símbolos com ranking ponderado:
  /// - nome exato (case-insensitive): +6.0
  /// - prefixo do nome: +4.0
  /// - substring do nome: +2.5
  /// - match na assinatura: +0.5
  /// - bônus tipo estrutural (class/enum/mixin/extension/typedef): +0.5
  Page<SymbolHit> searchSymbols({
    required String workspaceId,
    required String query,
    String? kind,
    int pageSize = 25,
    int offset = 0,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      throw SqliteException(1, 'query vazia');
    }
    final where = <String>['d.workspace_id = ?'];
    final params = <String>[workspaceId];
    if (kind != null) {
      where.add('s.kind = ?');
      params.add(kind);
    }
    final rows = db.query(
      'SELECT s.name AS name, s.kind AS kind, s.line AS line, '
      's.signature AS signature, d.path AS path '
      'FROM idx_symbols s JOIN idx_documents d ON d.id = s.document_id '
      'WHERE ${where.join(' AND ')}',
      params,
    );
    final scored = <SymbolHit>[];
    for (final r in rows) {
      final name = (r['name'] as String).toLowerCase();
      var score = 0.0;
      if (name == q) {
        score += 6.0;
      } else if (name.startsWith(q)) {
        score += 4.0;
      } else if (name.contains(q)) {
        score += 2.5;
      } else if ((r['signature'] as String).toLowerCase().contains(q)) {
        score += 0.5;
      } else {
        continue;
      }
      final kindOf = r['kind'] as String;
      if (kindOf == 'class' ||
          kindOf == 'enum' ||
          kindOf == 'mixin' ||
          kindOf == 'extension' ||
          kindOf == 'typedef') {
        score += 0.5;
      }
      scored.add(SymbolHit(
        name: r['name'] as String,
        kind: kindOf,
        line: int.parse(r['line'] as String),
        signature: r['signature'] as String,
        documentPath: r['path'] as String,
        score: score,
      ));
    }
    scored.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      return a.documentPath.compareTo(b.documentPath);
    });
    final slice = scored.skip(offset).take(pageSize).toList();
    final next = offset + slice.length;
    return Page(
      items: slice,
      hasMore: next < scored.length,
      nextCursor: next < scored.length ? '$next' : null,
      pageSize: pageSize,
      totalEstimate: scored.length,
      offsetMode: offset,
    );
  }

  /// Estatísticas agregadas reais do índice (tool `code_index.stats`).
  Map<String, Object?> stats(String workspaceId) {
    final docs = db.query(
      'SELECT COUNT(*) AS n FROM idx_documents WHERE workspace_id = ?',
      [workspaceId],
    ).single['n'];
    final syms = db.query(
      'SELECT COUNT(*) AS n FROM idx_symbols s JOIN idx_documents d ON d.id = s.document_id '
      'WHERE d.workspace_id = ?',
      [workspaceId],
    ).single['n'];
    final byKind = {
      for (final r in db.query(
        'SELECT s.kind AS kind, COUNT(*) AS n FROM idx_symbols s '
        'JOIN idx_documents d ON d.id = s.document_id WHERE d.workspace_id = ? '
        'GROUP BY s.kind',
        [workspaceId],
      ))
        r['kind'] as String: int.parse(r['n'] as String),
    };
    return {
      'documents': int.parse(docs as String),
      'symbols': int.parse(syms as String),
      'byKind': byKind,
    };
  }

  /// Remove todo o índice de um workspace (reindex limpo).
  int purge(String workspaceId) {
    db.execute(
        'DELETE FROM idx_documents WHERE workspace_id = ?', [workspaceId]);
    return db.changes;
  }

  static String? _relative(String path, String root) {
    final p = path.replaceAll('\\', '/');
    var r = root.replaceAll('\\', '/');
    if (!r.endsWith('/')) r = '$r/';
    if (!p.startsWith(r)) return null;
    return p.substring(r.length);
  }
}
