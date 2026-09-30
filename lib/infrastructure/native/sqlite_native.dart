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

// typedefs C -----------------------------------------------------------------
typedef _OpenV2C = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Void>>, Int32, Pointer<Pointer<Utf8>>);
typedef _OpenV2Dart = int Function(Pointer<Utf8>, Pointer<Pointer<Void>>, int, Pointer<Pointer<Utf8>>);
typedef _CloseC = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);
typedef _ExecC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<NativeFunction<_RowCb>>, Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _ExecDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<NativeFunction<_RowCb>>, Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _PrepareC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>);
typedef _PrepareDart = int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>);
typedef _StepC = Int32 Function(Pointer<Void>);
typedef _StepDart = int Function(Pointer<Void>);
typedef _FinalizeC = Int32 Function(Pointer<Void>);
typedef _FinalizeDart = int Function(Pointer<Void>);
typedef _ColTextC = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _ColTextDart = Pointer<Utf8> Function(Pointer<Void>, int);
typedef _ColCountC = Int32 Function(Pointer<Void>);
typedef _ColCountDart = int Function(Pointer<Void>);
typedef _BindTextC = Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>, Pointer<Void>);
typedef _BindTextDart = int Function(Pointer<Void>, int, Pointer<Utf8>, Pointer<Void>);
typedef _ErrMsgC = Pointer<Utf8> Function(Pointer<Void>);
typedef _ErrMsgDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _ChangesC = Int32 Function(Pointer<Void>);
typedef _ChangesDart = int Function(Pointer<Void>);
typedef _RowCb = Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>);

const _sqliteOk = 0;
const _sqliteRow = 100;
const _sqliteDone = 101;
const _sqliteTransient = 5;

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
    _prepare = _lib.lookupFunction<_PrepareC, _PrepareDart>('sqlite3_prepare_v2');
    _step = _lib.lookupFunction<_StepC, _StepDart>('sqlite3_step');
    _finalize = _lib.lookupFunction<_FinalizeC, _FinalizeDart>('sqlite3_finalize');
    _colText = _lib.lookupFunction<_ColTextC, _ColTextDart>('sqlite3_column_text');
    _colCount = _lib.lookupFunction<_ColCountC, _ColCountDart>('sqlite3_column_count');
    _bindText = _lib.lookupFunction<_BindTextC, _BindTextDart>('sqlite3_bind_text');
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
      final rc = _exec(_handle, sql.toNativeUtf8(allocator: arena), nullptr, nullptr, err);
      if (rc != _sqliteOk) throw SqliteException(rc, _lastError());
    });
  }

  /// Executa query com parâmetros textuais posicionais e retorna linhas reais
  /// indexadas por nome de coluna.
  List<Map<String, Object?>> query(String sql, [List<String> params = const []]) {
    if (_closed) throw StateError('DB fechado');
    return using((Arena arena) {
      final stmtPtr = arena<Pointer<Void>>();
      final rc =
          _prepare(_handle, sql.toNativeUtf8(allocator: arena), -1, stmtPtr, nullptr);
      if (rc != _sqliteOk) throw SqliteException(rc, _lastError());
      final stmt = stmtPtr.value;
      try {
        for (var i = 0; i < params.length; i++) {
          final b =
              _bindText(stmt, i + 1, params[i].toNativeUtf8(allocator: arena), nullptr);
          if (b != _sqliteOk && b != _sqliteTransient) throw SqliteException(b, _lastError());
        }
        final cols = _colCount(stmt);
        final names = <String>[];
        try {
          final nameFn = _lib
              .lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Int32),
                  Pointer<Utf8> Function(Pointer<Void>, int)>('sqlite3_column_name');
          for (var c = 0; c < cols; c++) {
            names.add(nameFn(stmt, c).toDartString());
          }
        } on ArgumentError {
          for (var c = 0; c < cols; c++) {
            names.add('$c');
          }
        }
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
      if (Platform.isWindows) ...['sqlite3.dll', 'SQLite3.dll', 'e_sqlite3.dll'],
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
      final rc = openV2(path.toNativeUtf8(allocator: arena), pp, 2 | 4 | 16, nullptr);
      if (rc != _sqliteOk) {
        throw SqliteException(rc, 'Falha ao abrir DB "$path" (rc=$rc)');
      }
      return SqliteDb._(lib, pp.value);
    });
  }
}
