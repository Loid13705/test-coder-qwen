/// Acesso real ao SQLite via FFI (dlopen em runtime — sem exigir compilação).
///
/// O banco local é a fonte de verdade do histórico, índices, logs, approvals,
/// checkpoints e memórias (local-first da spec). Se a biblioteca nativa não
/// existir na máquina, [SqliteNative.open] lança [SqliteUnavailableError] e o
/// storage reporta `missing_binary` real — nunca cai em memória fingida.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../domain/models/pagination.dart';
import 'chat_records.dart';

// typedefs C -----------------------------------------------------------------
typedef _OpenV2C = Int32 Function(
    Pointer<Utf8>, Pointer<Pointer<Void>>, Int32, Pointer<Pointer<Utf8>>);
typedef _OpenV2Dart = int Function(
    Pointer<Utf8>, Pointer<Pointer<Void>>, int, Pointer<Pointer<Utf8>>);
typedef _CloseC = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);
// Callback de sqlite3_exec: a assinatura nativa é (ptr, int, char**, char**)
// em C — 4 argumentos. Declarar com 5 (bug antigo) gera ABI mismatch e
// segfault real quando o SQLite invoca o callback no fim da stream de
// resultados (ex.: multi-statement DDL). `nullptr` como callback nunca invoca.
typedef _RowCb = Int32 Function(
    Pointer<Void>, Int32, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>);
typedef _ExecC = Int32 Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<NativeFunction<_RowCb>>, Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _ExecDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<NativeFunction<_RowCb>>, Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _PrepareC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32,
    Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>);
typedef _PrepareDart = int Function(Pointer<Void>, Pointer<Utf8>, int,
    Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>);
typedef _StepC = Int32 Function(Pointer<Void>);
typedef _StepDart = int Function(Pointer<Void>);
typedef _FinalizeC = Int32 Function(Pointer<Void>);
typedef _FinalizeDart = int Function(Pointer<Void>);
typedef _ColTextC = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _ColTextDart = Pointer<Utf8> Function(Pointer<Void>, int);
typedef _ColCountC = Int32 Function(Pointer<Void>);
typedef _ColCountDart = int Function(Pointer<Void>);
// sqlite3_bind_text(stmt, idx, text, nBytes, destruct) — o 4º parâmetro é o
// destructor (SQLite_TRANSIENT = -1 como ponteiro), NÃO um argumento a menos.
// Omiti-lo corrompia a pilha em chamadas FFI e causava segfault dentro de
// libsqlite3 no primeiro step com parâmetros vinculados.
typedef _BindTextC = Int32 Function(
    Pointer<Void>, Int32, Pointer<Utf8>, Int32, Pointer<Void>);
typedef _BindTextDart = int Function(
    Pointer<Void>, int, Pointer<Utf8>, int, Pointer<Void>);
typedef _BindInt64C = Int32 Function(Pointer<Void>, Int32, Int64);
typedef _BindInt64Dart = int Function(Pointer<Void>, int, int);
typedef _BindDoubleC = Int32 Function(Pointer<Void>, Int32, Double);
typedef _BindDoubleDart = int Function(Pointer<Void>, int, double);
typedef _BindNullC = Int32 Function(Pointer<Void>, Int32);
typedef _BindNullDart = int Function(Pointer<Void>, int);
typedef _ErrMsgC = Pointer<Utf8> Function(Pointer<Void>);
typedef _ErrMsgDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _ChangesC = Int32 Function(Pointer<Void>);
typedef _ChangesDart = int Function(Pointer<Void>);

const _sqliteOk = 0;
const _sqliteRow = 100;
const _sqliteDone = 101;

class SqliteException implements Exception {
  const SqliteException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'SqliteException($code): $message';
}

class SqliteUnavailableError implements Exception {
  const SqliteUnavailableError();
  @override
  String toString() =>
      'libsqlite3 não encontrada no sistema — instale a biblioteca ou habilite '
      'o plugin sqlite3_flutter_libs no build Flutter (estado real: missing_binary).';
}

class SqliteDb {
  SqliteDb._(this._lib, this._handle) {
    _close = _lib.lookupFunction<_CloseC, _CloseDart>('sqlite3_close_v2');
    _exec = _lib.lookupFunction<_ExecC, _ExecDart>('sqlite3_exec');
    _prepare =
        _lib.lookupFunction<_PrepareC, _PrepareDart>('sqlite3_prepare_v2');
    _step = _lib.lookupFunction<_StepC, _StepDart>('sqlite3_step');
    _finalize =
        _lib.lookupFunction<_FinalizeC, _FinalizeDart>('sqlite3_finalize');
    _colText =
        _lib.lookupFunction<_ColTextC, _ColTextDart>('sqlite3_column_text');
    _colName =
        _lib.lookupFunction<_ColTextC, _ColTextDart>('sqlite3_column_name');
    _colCount =
        _lib.lookupFunction<_ColCountC, _ColCountDart>('sqlite3_column_count');
    _bindText =
        _lib.lookupFunction<_BindTextC, _BindTextDart>('sqlite3_bind_text');
    _bindInt64 =
        _lib.lookupFunction<_BindInt64C, _BindInt64Dart>('sqlite3_bind_int64');
    _bindDouble = _lib
        .lookupFunction<_BindDoubleC, _BindDoubleDart>('sqlite3_bind_double');
    _bindNull =
        _lib.lookupFunction<_BindNullC, _BindNullDart>('sqlite3_bind_null');
    _errMsg = _lib.lookupFunction<_ErrMsgC, _ErrMsgDart>('sqlite3_errmsg');
    _changes = _lib.lookupFunction<_ChangesC, _ChangesDart>('sqlite3_changes');
  }

  final DynamicLibrary _lib;
  final Pointer<Void> _handle;
  late final _CloseDart _close;
  late final _ExecDart _exec;
  late final _PrepareDart _prepare;
  late final _StepDart _step;
  late final _FinalizeDart _finalize;
  late final _ColTextDart _colText;
  late final Pointer<Utf8> Function(Pointer<Void>, int) _colName;
  late final _ColCountDart _colCount;
  late final _BindTextDart _bindText;
  late final _BindInt64Dart _bindInt64;
  late final _BindDoubleDart _bindDouble;
  late final _BindNullDart _bindNull;
  late final _ErrMsgDart _errMsg;
  late final int Function(Pointer<Void>) _changes;
  bool _closed = false;

  String _lastError() => _errMsg(_handle).toDartString();

  void execute(String sql, [List<Object?> params = const []]) {
    if (_closed) throw StateError('DB fechado');
    // Sem parâmetros: caminho rápido via sqlite3_exec.
    if (params.isEmpty) {
      using((Arena arena) {
        final err = arena<Pointer<Utf8>>();
        final rc = _exec(
            _handle, sql.toNativeUtf8(allocator: arena), nullptr, nullptr, err);
        if (rc != _sqliteOk) throw SqliteException(rc, _lastError());
      });
      return;
    }
    // Com parâmetros: prepare/bind/step — nunca interpolar texto na SQL.
    query(sql, params);
  }

  /// Executa query com parâmetros textuais posicionais e retorna linhas reais
  /// indexadas por nome de coluna.
  List<Map<String, Object?>> query(String sql,
      [List<Object?> params = const []]) {
    if (_closed) throw StateError('DB fechado');
    return using((Arena arena) {
      final stmtPtr = arena<Pointer<Void>>();
      final rc = _prepare(
          _handle, sql.toNativeUtf8(allocator: arena), -1, stmtPtr, nullptr);
      if (rc != _sqliteOk) throw SqliteException(rc, _lastError());
      final stmt = stmtPtr.value;
      try {
        for (var i = 0; i < params.length; i++) {
          final value = params[i];
          final int b;
          if (value == null) {
            b = _bindNull(stmt, i + 1);
          } else if (value is bool) {
            b = _bindInt64(stmt, i + 1, value ? 1 : 0);
          } else if (value is int) {
            b = _bindInt64(stmt, i + 1, value);
          } else if (value is double) {
            b = _bindDouble(stmt, i + 1, value);
          } else {
            final text = value.toString().toNativeUtf8(allocator: arena);
            // A arena permanece viva até o statement ser executado abaixo.
            b = _bindText(stmt, i + 1, text, -1, nullptr);
          }
          if (b != _sqliteOk) {
            throw SqliteException(b, _lastError());
          }
        }
        final cols = _colCount(stmt);
        // Nomes de coluna: sqlite3_column_name é estável após prepare e pode
        // ser lido uma única vez antes do loop de steps (a string pertence ao
        // statement e vive até finalize). Ler por step era o que deixava o
        // mapa vazio em queries sem linhas (ex.: COUNT sobre tabela vazia).
        final names = [
          for (var c = 0; c < cols; c++) _colName(stmt, c).toDartString()
        ];
        final rows = <Map<String, Object?>>[];
        while (true) {
          final s = _step(stmt);
          if (s == _sqliteDone) break;
          if (s != _sqliteRow) throw SqliteException(s, _lastError());
          final row = <String, Object?>{};
          for (var c = 0; c < cols; c++) {
            final t = _colText(stmt, c);
            row[names[c]] = t.address == 0 ? null : t.toDartString();
          }
          rows.add(row);
        }
        return rows;
      } finally {
        _finalize(stmt);
      }
    });
  }

  int get changes => _changes(_handle);

  void close() {
    if (!_closed) {
      _close(_handle);
      _closed = true;
    }
  }
}

class SqliteNative {
  /// Tenta carregar libsqlite3 do sistema. Retorna null quando ausente →
  /// chamador reporta missing_binary real.
  static DynamicLibrary? tryLoad() {
    final candidates = <String>[
      if (Platform.isWindows) ...[
        'sqlite3.dll',
        'SQLite3.dll',
        'e_sqlite3.dll'
      ],
      if (Platform.isMacOS) ...[
        '/usr/lib/libsqlite3.dylib',
        'libsqlite3.dylib',
        '/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib',
      ],
      if (Platform.isLinux) ...[
        'libsqlite3.so.0',
        'libsqlite3.so',
        '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
      ],
    ];
    for (final name in candidates) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static bool get available => tryLoad() != null;

  static SqliteDb open(String path) {
    final lib = tryLoad();
    if (lib == null) throw const SqliteUnavailableError();
    final openV2 = lib.lookupFunction<_OpenV2C, _OpenV2Dart>('sqlite3_open_v2');
    return using((Arena arena) {
      final pp = arena<Pointer<Void>>();
      // SQLITE_OPEN_READWRITE(2) | CREATE(4) | FULLMUTEX(16)
      final rc =
          openV2(path.toNativeUtf8(allocator: arena), pp, 2 | 4 | 16, nullptr);
      if (rc != _sqliteOk) {
        throw SqliteException(rc, 'Falha ao abrir DB "$path" (rc=$rc)');
      }
      return SqliteDb._(lib, pp.value);
    });
  }

  /// Abre em modo READONLY nativo (SQLITE_OPEN_READONLY=1): qualquer escrita
  /// falha no próprio motor com SQLITE_READONLY — proteção real, não por
  /// convenção de código. Usado por db.query_readonly.
  static SqliteDb openReadOnly(String path) {
    final lib = tryLoad();
    if (lib == null) throw const SqliteUnavailableError();
    final openV2 = lib.lookupFunction<_OpenV2C, _OpenV2Dart>('sqlite3_open_v2');
    return using((Arena arena) {
      final pp = arena<Pointer<Void>>();
      // SQLITE_OPEN_READONLY(1) | FULLMUTEX(16) — sem CREATE: arquivo
      // inexistente retorna erro do motor, não um DB vazio falso.
      final rc =
          openV2(path.toNativeUtf8(allocator: arena), pp, 1 | 16, nullptr);
      if (rc != _sqliteOk) {
        throw SqliteException(
            rc, 'Falha ao abrir DB "$path" em readonly (rc=$rc)');
      }
      return SqliteDb._(lib, pp.value);
    });
  }
}

/// Repositório local-first de conversas/mensagens (chat persistido em SQLite).
///
/// Usa apenas [SqliteDb] real — sem fallback em memória: se libsqlite3 não
/// existir, `missing_binary` é reportado por quem abre o DB.
class ChatRepository {
  ChatRepository(this.db) {
    // FK só é imposta se habilitada por PRAGMA por conexão; sem isto o
    // REFERENCES do schema é decorativo.
    db.execute('PRAGMA foreign_keys = ON');
    db.execute(kChatSchema);
    // Migra colunas de metadados (pinned/tags/folder/archived_at/deleted_at)
    // em bancos criados por versões antigas do schema. Cada ALTER falha se a
    // coluna já existe — o erro é engolido POR ESSE MOTIVO verificado, não
    // para esconder falha real: no fim, um SELECT que toque todas as colunas
    // prova que o schema ficou completo (senão a exceção original propaga).
    for (final m in kChatMigrations) {
      try {
        db.execute(m);
      } catch (e) {
        try {
          db.query('SELECT pinned, tags, folder, archived_at, deleted_at'
              ' FROM conversations LIMIT 0');
        } catch (_) {
          throw e;
        }
      }
    }
  }

  final SqliteDb db;

  static int _toInt(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;

  static String _now() => DateTime.now().toUtc().toIso8601String();

  String createConversation(
      {required String workspaceId,
      required String title,
      String? parentId,
      String folder = ''}) {
    final now = _now();
    final id = 'conv_${DateTime.now().microsecondsSinceEpoch}';
    // Bind paramétrico: texto do usuário NUNCA é interpolado na SQL.
    db.execute(
        "INSERT INTO conversations (id, workspace_id, title, parent_id,"
        " folder, status, created_at, updated_at)"
        " VALUES (?,?,?,?,?,?,?,?)",
        [id, workspaceId, title, parentId ?? '', folder, 'active', now, now]);
    return id;
  }

  void touchConversation(String id) => db.execute(
      "UPDATE conversations SET updated_at=? WHERE id=?", [_now(), id]);

  /// Lista conversas ATIVAS de um workspace (ou todas, com `includeAllWs`),
  /// pinadas primeiro, depois por atividade. `deleted_at IS NULL` também é
  /// imposto defensivamente: o CHECK de status cobre, mas dados antigos de
  /// outras versões não podem vazar para a lixeira da UI.
  List<Map<String, Object?>> listConversations(String? workspaceId,
          {int limit = 200, bool includeAllWs = false}) =>
      db.query(
          "SELECT id, workspace_id, title, parent_id, pinned, tags, folder,"
          " created_at, updated_at FROM conversations"
          " WHERE status='active' AND deleted_at IS NULL"
          " ${includeAllWs || workspaceId == null ? '' : 'AND workspace_id=?'}"
          " ORDER BY pinned DESC, updated_at DESC LIMIT ${_toInt(limit)}",
          includeAllWs || workspaceId == null ? const [] : [workspaceId]);

  List<Map<String, Object?>> listArchivedConversations(String? workspaceId,
          {int limit = 200, bool includeAllWs = false}) =>
      db.query(
          "SELECT id, workspace_id, title, parent_id, pinned, tags, folder,"
          " created_at, updated_at, archived_at FROM conversations"
          " WHERE status='archived' AND deleted_at IS NULL"
          " ${includeAllWs || workspaceId == null ? '' : 'AND workspace_id=?'}"
          " ORDER BY archived_at DESC LIMIT ${_toInt(limit)}",
          includeAllWs || workspaceId == null ? const [] : [workspaceId]);

  List<Map<String, Object?>> listDeletedConversations(String? workspaceId,
          {int limit = 200, bool includeAllWs = false}) =>
      db.query(
          "SELECT id, workspace_id, title, parent_id, pinned, tags, folder,"
          " created_at, updated_at, deleted_at FROM conversations"
          " WHERE status='deleted'"
          " ${includeAllWs || workspaceId == null ? '' : 'AND workspace_id=?'}"
          " ORDER BY deleted_at DESC LIMIT ${_toInt(limit)}",
          includeAllWs || workspaceId == null ? const [] : [workspaceId]);

  // ---------- Metadados reais (pin / tags / folder / rename) ----------

  void setPinned(String id, bool pinned) => db.execute(
      'UPDATE conversations SET pinned=?, updated_at=? WHERE id=?',
      [pinned ? 1 : 0, _now(), id]);

  void setFolder(String id, String folder) => db.execute(
      'UPDATE conversations SET folder=?, updated_at=? WHERE id=?',
      [folder, _now(), id]);

  void setTags(String id, List<String> tags) => db.execute(
      'UPDATE conversations SET tags=?, updated_at=? WHERE id=?',
      [jsonEncode(tags), _now(), id]);

  void renameConversation(String id, String title) => db.execute(
      'UPDATE conversations SET title=?, updated_at=? WHERE id=?',
      [title, _now(), id]);

  // ---------- Archive / soft-delete / restore ----------

  void setStatus(String id, String status) {
    assert(const {'active', 'archived', 'deleted'}.contains(status));
    // archived_at/deleted_at registram QUANDO cada coisa aconteceu (spec:
    // restore mostra a data de arquivamento/exclusão na lixeira).
    db.execute(
        'UPDATE conversations SET status=?,'
        ' archived_at=? , deleted_at=?, updated_at=? WHERE id=?',
        [
          status,
          status == 'archived' ? _now() : null,
          status == 'deleted' ? _now() : null,
          _now(),
          id,
        ]);
  }

  void archiveConversation(String id) => setStatus(id, 'archived');
  void softDeleteConversation(String id) => setStatus(id, 'deleted');
  void restoreConversation(String id) {
    db.execute(
        "UPDATE conversations SET status='active', archived_at=NULL,"
        " deleted_at=NULL, updated_at=? WHERE id=?",
        [_now(), id]);
  }

  /// EXCLUSÃO PERMANENTE real (apaga a conversa e, via FK ON DELETE CASCADE
  /// com `PRAGMA foreign_keys=ON` ativado nesta conexão, as mensagens dela).
  void purgeConversation(String id) =>
      db.execute('DELETE FROM conversations WHERE id=?', [id]);

  /// Insere mensagem com payload JSON já serializado pelo chamador.
  /// Bind paramétrico em todos os campos — nada de interpolação na SQL.
  void insertMessage({
    required String id,
    required String conversationId,
    required String role,
    String? modelId,
    String? mode,
    required String blocksJson,
    required String status,
    String? usageJson,
    required String createdAt,
  }) =>
      db.execute(
          "INSERT INTO messages (id, conversation_id, role, model_id, mode,"
          " blocks_json, status, usage_json, created_at)"
          " VALUES (?,?,?,?,?,?,?,?,?)",
          [
            id,
            conversationId,
            role,
            modelId ?? '',
            mode ?? '',
            blocksJson,
            status,
            usageJson ?? '',
            createdAt,
          ]);

  int countMessages(String conversationId) {
    final rows = db.query(
        "SELECT COUNT(*) AS c FROM messages WHERE conversation_id=?",
        [conversationId]);
    return _toInt(rows.first['c']);
  }

  /// Atualiza blocos/status de uma mensagem persistida (usado pelo tool loop
  /// para gravar o status REAL de cada tool call no histórico — sem isso o
  /// card persistido ficaria eternamente 'pending'). Bind paramétrico.
  void updateMessageBlocks(String id,
      {required String blocksJson, String? status}) {
    if (status == null) {
      db.execute(
          "UPDATE messages SET blocks_json=? WHERE id=?", [blocksJson, id]);
    } else {
      db.execute("UPDATE messages SET blocks_json=?, status=? WHERE id=?",
          [blocksJson, status, id]);
    }
  }

  /// Página cursor-based (mais recentes primeiro no SQL, devolvida em ordem
  /// cronológica). `beforeId` = cursor para carregar mais antigo.
  Page<MessageRecord> pageMessages(String conversationId,
      {String? beforeId, int pageSize = 50}) {
    final size = _toInt(pageSize);
    // `conversation_id` é obrigatório em MessageRecord.fromRow — precisa estar
    // no SELECT (já esteve ausente, causando cast de Null para String).
    const cols = 'id, conversation_id, role, model_id, mode, blocks_json,'
        ' status, usage_json, created_at';
    final rows = beforeId == null
        ? db.query(
            "SELECT $cols FROM messages WHERE conversation_id=?"
            " ORDER BY id DESC LIMIT ${size + 1}",
            [conversationId])
        : db.query(
            "SELECT $cols FROM messages WHERE conversation_id=? AND id<?"
            " ORDER BY id DESC LIMIT ${size + 1}",
            [conversationId, beforeId]);
    final hasMore = rows.length > size;
    final items = (hasMore ? rows.sublist(0, size) : rows)
        .reversed
        .map(MessageRecord.fromRow)
        .toList();
    return Page(
      items: items,
      // Sem `beforeId` não existe página mais nova; o cursor de "mais antigo"
      // é o id do item mais antigo da página (items.first em ordem
      // cronológica), que casa com o filtro `id < beforeId` acima.
      nextCursor: beforeId == null ? null : items.first.id,
      prevCursor: items.isNotEmpty ? items.first.id : null,
      pageSize: size,
      totalEstimate: _toInt(db.query(
          "SELECT COUNT(*) AS c FROM messages WHERE conversation_id=?",
          [conversationId]).first['c']),
    );
  }
}
