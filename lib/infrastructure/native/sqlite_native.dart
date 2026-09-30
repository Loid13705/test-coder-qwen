/// Acesso real ao SQLite via FFI (dlopen em runtime — sem exigir compilação).
///
/// O banco local é a fonte de verdade do histórico, índices, logs, approvals,
/// checkpoints e memórias (local-first da spec). Se a biblioteca nativa não
/// existir na máquina, [SqliteNative.open] lança [SqliteUnavailableError] e o
/// storage reporta `missing_binary` real — nunca cai em memória fingida.
library;

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
    _colCount =
        _lib.lookupFunction<_ColCountC, _ColCountDart>('sqlite3_column_count');
    _bindText =
        _lib.lookupFunction<_BindTextC, _BindTextDart>('sqlite3_bind_text');
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
  late final _ColCountDart _colCount;
  late final _BindTextDart _bindText;
  late final _ErrMsgDart _errMsg;
  late final int Function(Pointer<Void>) _changes;
  bool _closed = false;

  String _lastError() => _errMsg(_handle).toDartString();

  void execute(String sql) {
    if (_closed) throw StateError('DB fechado');
    using((Arena arena) {
      final err = arena<Pointer<Utf8>>();
      final rc = _exec(
          _handle, sql.toNativeUtf8(allocator: arena), nullptr, nullptr, err);
      if (rc != _sqliteOk) throw SqliteException(rc, _lastError());
    });
  }

  /// Executa query com parâmetros textuais posicionais e retorna linhas reais
  /// indexadas por nome de coluna.
  List<Map<String, Object?>> query(String sql,
      [List<String> params = const []]) {
    if (_closed) throw StateError('DB fechado');
    return using((Arena arena) {
      final stmtPtr = arena<Pointer<Void>>();
      final rc = _prepare(
          _handle, sql.toNativeUtf8(allocator: arena), -1, stmtPtr, nullptr);
      if (rc != _sqliteOk) throw SqliteException(rc, _lastError());
      final stmt = stmtPtr.value;
      try {
        for (var i = 0; i < params.length; i++) {
          final text = params[i].toNativeUtf8(allocator: arena);
          // nBytes em UTF-8 e SQLITE_TRANSIENT (-1): o SQLite copia o texto,
          // então o buffer da arena pode morrer ao fim do `using`.
          final b = _bindText(stmt, i + 1, text, -1, nullptr);
          if (b != _sqliteOk) {
            throw SqliteException(b, _lastError());
          }
        }
        final cols = _colCount(stmt);
        // sqlite3_column_name só é seguro DEPOIS do primeiro sqlite3_step:
        // em statements com bind de parâmetros, chamá-lo antes corrompe o
        // buffer interno de nomes e o step seguinte segue ponteiro inválido
        // (segfault real em libsqlite3 — reprodutível com `WHERE x=?`).
        List<String>? names;
        final rows = <Map<String, Object?>>[];
        while (true) {
          final s = _step(stmt);
          if (s == _sqliteDone) break;
          if (s != _sqliteRow) throw SqliteException(s, _lastError());
          names ??= () {
            try {
              final nameFn = _lib.lookupFunction<
                  Pointer<Utf8> Function(Pointer<Void>, Int32),
                  Pointer<Utf8> Function(
                      Pointer<Void>, int)>('sqlite3_column_name');
              return [for (var c = 0; c < cols; c++) nameFn(stmt, c).toDartString()];
            } on ArgumentError {
              return [for (var c = 0; c < cols; c++) '$c'];
            }
          }();
          final row = <String, Object?>{};
          for (var c = 0; c < cols; c++) {
            final t = _colText(stmt, c);
            row[names[c]] = t.address == 0 ? null : t.toDartString();
          }
          rows.add(row);
        }
        // statement sem linhas ainda precisa dos nomes p/ chamadores que só
        // olham chaves; nunca chamado antes do step acima (regra de segurança).
        names ??= const [];
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
}

/// Repositório local-first de conversas/mensagens (chat persistido em SQLite).
///
/// Usa apenas [SqliteDb] real — sem fallback em memória: se libsqlite3 não
/// existir, `missing_binary` é reportado por quem abre o DB.
class ChatRepository {
  ChatRepository(this.db) {
    db.execute(kChatSchema);
  }

  final SqliteDb db;

  static int _toInt(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;

  String createConversation(
      {required String workspaceId, required String title, String? parentId}) {
    final now = DateTime.now().toUtc().toIso8601String();
    final id = 'conv_${DateTime.now().microsecondsSinceEpoch}';
    db.execute(
        "INSERT INTO conversations (id, workspace_id, title, parent_id, status, created_at, updated_at)"
        " VALUES ('$id','$workspaceId','${_esc(title)}',${parentId == null ? 'NULL' : "'$parentId'"},'active','$now','$now')");
    return id;
  }

  void touchConversation(String id) =>
      db.execute("UPDATE conversations SET updated_at='"
          "${DateTime.now().toUtc().toIso8601String()}' WHERE id='$id'");

  String _esc(String s) => s.replaceAll("'", "''");

  List<Map<String, Object?>> listConversations(String workspaceId,
          {int limit = 50}) =>
      db.query(
          "SELECT id, workspace_id, title, parent_id, created_at FROM conversations"
          " WHERE workspace_id=? AND status='active'"
          " ORDER BY updated_at DESC LIMIT ${_toInt(limit)}",
          [workspaceId]);

  /// Insere mensagem com payload JSON já serializado pelo chamador.
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
          " blocks_json, status, usage_json, created_at) VALUES ("
          "'$id','$conversationId','$role',"
          "${modelId == null ? 'NULL' : "'$modelId'"},"
          "${mode == null ? 'NULL' : "'$mode'"},"
          "'${_esc(blocksJson)}','$status',"
          "${usageJson == null ? 'NULL' : "'${_esc(usageJson)}'"},"
          "'$createdAt')");

  int countMessages(String conversationId) {
    final rows = db.query(
        "SELECT COUNT(*) AS c FROM messages WHERE conversation_id=?",
        [conversationId]);
    return _toInt(rows.first['c']);
  }

  /// Página cursor-based (mais recentes primeiro no SQL, devolvida em ordem
  /// cronológica). `beforeId` = cursor para carregar mais antigo.
  Page<MessageRecord> pageMessages(String conversationId,
      {String? beforeId, int pageSize = 50}) {
    final size = _toInt(pageSize);
    final rows = beforeId == null
        ? db.query(
            "SELECT id, role, model_id, mode, blocks_json, status, usage_json, created_at"
            " FROM messages WHERE conversation_id=?"
            " ORDER BY id DESC LIMIT ${size + 1}",
            [conversationId])
        : db.query(
            "SELECT id, role, model_id, mode, blocks_json, status, usage_json, created_at"
            " FROM messages WHERE conversation_id=? AND id<?"
            " ORDER BY id DESC LIMIT ${size + 1}",
            [conversationId, beforeId]);
    final hasMore = rows.length > size;
    final items = (hasMore ? rows.sublist(0, size) : rows)
        .reversed
        .map(MessageRecord.fromRow)
        .toList();
    return Page(
      items: items,
      hasMore: hasMore,
      nextCursor: items.isNotEmpty ? items.first.id : null,
      prevCursor: items.isNotEmpty ? items.last.id : null,
      pageSize: size,
      totalEstimate: _toInt(db.query(
          "SELECT COUNT(*) AS c FROM messages WHERE conversation_id=?",
          [conversationId]).first['c']),
    );
  }
}
