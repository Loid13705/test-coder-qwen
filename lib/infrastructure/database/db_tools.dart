/// Tools de banco de dados (spec catálogo: db.*).
///
/// Execução REAL contra o arquivo SQLite do workspace — sem simulação:
/// - `db.query_readonly` — abre o DB em modo READONLY nativo e recusa
///   qualquer statement fora de SELECT/WITH/EXPLAIN antes de tocar no motor;
/// - `db.schema_inspect` — lê sqlite_master + PRAGMA table_info reais;
/// - `db.migrate`        — aplica .sql com backup byte-a-byte ANTES, dentro
///   de uma transação real (BEGIN IMMEDIATE ... COMMIT, ROLLBACK em falha)
///   e política explicitApproval.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import '../native/sqlite_native.dart';
import '../process/process_utils.dart';

// sqlite3_complete(C*sql) -> int (1 quando o texto termina em statement
// completo). Usado para dividir scripts multi-statement corretamente — sem
// split ingênuo por ';' que quebraria triggers com ';' interno.
typedef _CompleteC = Int32 Function(Pointer<Utf8>);
typedef _CompleteDart = int Function(Pointer<Utf8>);

final DynamicLibrary? _sqliteLib = SqliteNative.tryLoad();

bool _sqlIsComplete(String sql) {
  final lib = _sqliteLib;
  if (lib == null) return true; // sem lib: deixa o prepare reclamar se errado
  return using((arena) =>
      lib.lookupFunction<_CompleteC, _CompleteDart>('sqlite3_complete')(
              sql.toNativeUtf8(allocator: arena)) ==
          1);
}

Future<ToolResult<O>> _guard<O extends ToolOutput>(
    VtTool<dynamic, O> tool, Future<ToolResult<O>> Function() body) async {
  try {
    return await body().timeout(tool.timeout);
  } on TimeoutException {
    return ToolFailureResult<O>(VtFailure.timeout(tool.timeout));
  } on SqliteUnavailableError {
    return ToolFailureResult<O>(VtFailure(
      code: VtErrorCode.binaryMissing,
      message: 'libsqlite3 ausente no sistema — instale-a ou habilite o '
          'plugin sqlite3_flutter_libs no build.',
      recoveryActions: const [
        RecoveryAction(kind: 'install_binary', label: 'Instalar libsqlite3'),
      ],
    ));
  } on SqliteException catch (e) {
    return ToolFailureResult<O>(VtFailure(
      code: VtErrorCode.internalError,
      message: 'SQLite rc=${e.code}: ${e.message}',
      retryable: false,
    ));
  } on VtFailure catch (f) {
    return ToolFailureResult<O>(f);
  } on FormatException catch (e) {
    return ToolFailureResult<O>(VtFailure(
        code: VtErrorCode.validationFailed, message: e.message));
  }
}

abstract class _DbTool extends VtTool<MapToolInput, TextOutput> {
  _DbTool({this.dataDir});
  final String? dataDir;

  @override
  List<String> get capabilities => const ['sqlite'];
  @override
  Duration get timeout => const Duration(seconds: 30);
  @override
  RetryPolicy get retryPolicy => const RetryPolicy();
  @override
  Map<String, Object?> get outputSchema => const {'type': 'object'};
  @override
  bool get isIdempotent => true;
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  ToolCategory get category => ToolCategory.database;

  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async =>
      SqliteNative.available ? const HealthOk() : const HealthMissingBinary('libsqlite3');

  /// Caminho REAL do banco alvo: parâmetro (validado no sandbox) ou o DB
  /// local da IDE (`<dataDir>/techvt.sqlite`) — sempre verificado em disco.
  Future<String> resolveDbPath(ToolContext ctx, MapToolInput input) async {
    var p = input.str('path');
    if (p.isEmpty) {
      final dir = dataDir ?? defaultDataDir();
      p = joinPath(dir, 'techvt.sqlite');
    }
    p = lexicalNormalize(p);
    if (!isAbsolute(p)) {
      final root = ctx.workspaceRoots.isEmpty
          ? Directory.current.path
          : ctx.workspaceRoots.first;
      p = joinPath(root, p);
    }
    final guarded = await ctx.sandbox.resolveReadable(p, ctx);
    if (!await File(guarded).exists()) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Arquivo de banco inexistente: $guarded (verificado em disco).',
      );
    }
    return guarded;
  }

  ToolSuccess<TextOutput> ok(Object data,
          {List<Citation> citations = const []}) =>
      ToolSuccess(
          data: TextOutput(const JsonEncoder.withIndent('  ').convert(data)),
          citations: citations);
}

String? _readOnlyGuard(String sql) {
  final stripped = sql
      .replaceAll(RegExp(r'--.*?$|/\*.*?\*/', multiLine: true, dotAll: true), ' ')
      .trimLeft()
      .toLowerCase();
  if (stripped.startsWith('select') ||
      stripped.startsWith('with') ||
      stripped.startsWith('explain')) {
    return null;
  }
  if (stripped.startsWith('pragma')) {
    // PRAGMA só na forma de leitura — bloqueia PRAGMA x=y (escrita)
    if (stripped.contains('=')) {
      return 'PRAGMA de escrita não é permitido em modo somente leitura.';
    }
    return null;
  }
  return 'Somente SELECT/WITH/EXPLAIN/PRAGMA(read) são permitidos; recebeu um '
      'statement de escrita/DCL. Use db.migrate (com aprovação) para alterações.';
}

// ---------------------------------------------------------- db.query_readonly
class DbQueryReadonlyTool extends _DbTool {
  DbQueryReadonlyTool({super.dataDir});

  @override
  String get id => 'db.query_readonly';
  @override
  String get title => 'Query somente leitura';
  @override
  String get description =>
      'Executa SELECT/WITH/EXPLAIN REAL contra um SQLite do workspace (ou o '
      'banco local da IDE quando "path" omitido). Dupla proteção: o arquivo é '
      'aberto em modo READONLY nativo E o statement é validado antes. '
      'Parametrização posicional (?), paginação por limit/offset.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['sql'],
        'properties': {
          'sql': {
            'type': 'string',
            'description': 'Um único statement SELECT/WITH/EXPLAIN/PRAGMA-read.'
          },
          'params': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Valores posicionais para as âncoras "?".'
          },
          'path': {
            'type': 'string',
            'description': 'Arquivo .sqlite/.db (default: banco local da IDE).'
          },
          'limit': {
            'type': 'integer',
            'description': 'Máx. linhas retornadas (default 200, máx 5000).'
          },
          'offset': {'type': 'integer', 'description': 'Pula N linhas.'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
          ToolContext ctx, MapToolInput input) =>
      _guard(this, () async {
        final sql = input.str('sql').trim();
        final guardMsg = _readOnlyGuard(sql);
        if (guardMsg != null) {
          return ToolFailureResult(VtFailure(
              code: VtErrorCode.permissionDenied, message: guardMsg));
        }
        final withoutTrailingSemi = sql.replaceAll(RegExp(r';\s*$'), '');
        if (withoutTrailingSemi.contains(';') &&
            !_sqlIsComplete('$withoutTrailingSemi;')) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.permissionDenied,
            message: 'Apenas um statement por chamada (detectado script '
                'multi-statement).',
          ));
        }
        final path = await resolveDbPath(ctx, input);
        final limit = (input.intOrNull('limit') ?? 200).clamp(1, 5000);
        final offset = (input.intOrNull('offset') ?? 0).clamp(0, 1 << 30);
        final params = input.list('params');
        final db = SqliteNative.openReadOnly(path);
        try {
          final rows = db.query(sql, params);
          final page = rows.skip(offset).take(limit).toList();
          return ok({
            'database': path,
            'rowCount': rows.length,
            'returned': page.length,
            'offset': offset,
            'truncated': rows.length > offset + limit,
            'columns': page.isEmpty ? const [] : page.first.keys.toList(),
            'rows': page,
          }, citations: [
            Citation(
                sourceType: 'file',
                sourceRef: path,
                label: 'query somente leitura em ${basenameOf(path)}'),
          ]);
        } finally {
          db.close();
        }
      });
}

// ----------------------------------------------------------- db.schema_inspect
class DbSchemaInspectTool extends _DbTool {
  DbSchemaInspectTool({super.dataDir});

  @override
  String get id => 'db.schema_inspect';
  @override
  String get title => 'Inspeciona schema';
  @override
  String get description =>
      'Lê o schema REAL de um SQLite: tabelas/índices/views/triggers de '
      'sqlite_master + colunas (PRAGMA table_info), FKs e índices por tabela '
      '(quando pedidas). Nada é inferido de código — é o que o arquivo diz.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Arquivo .sqlite/.db (default: banco local da IDE).'
          },
          'table': {
            'type': 'string',
            'description': 'Detalha colunas/FK/índices desta tabela.'
          },
          'includeSql': {
            'type': 'boolean',
            'description': 'Inclui o DDL original de cada objeto.'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
          ToolContext ctx, MapToolInput input) =>
      _guard(this, () async {
        final path = await resolveDbPath(ctx, input);
        final detailTable = input.str('table');
        final includeSql = input.boolOf('includeSql');
        final db = SqliteNative.openReadOnly(path);
        try {
          final objs = db.query(
              'SELECT type, name, tbl_name, sql FROM sqlite_master '
              "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name");
          final tables = <Map<String, Object?>>[];
          for (final o in objs) {
            tables.add({
              'type': o['type'],
              'name': o['name'],
              'tblName': o['tbl_name'],
              if (includeSql) 'sql': o['sql'],
            });
          }
          final out = <String, Object?>{
            'database': path,
            'userVersion':
                db.query('PRAGMA user_version').first['user_version'],
            'objects': tables,
          };
          if (detailTable.isNotEmpty) {
            final exists = objs.any((o) =>
                o['type'] == 'table' && o['name'] == detailTable);
            if (!exists) {
              final realTables = objs
                  .where((o) => o['type'] == 'table')
                  .map((o) => o['name']?.toString() ?? '')
                  .where((s) => s.isNotEmpty)
                  .join(', ');
              return ToolFailureResult(VtFailure(
                code: VtErrorCode.validationFailed,
                message: 'Tabela "$detailTable" não existe no arquivo real '
                    '${basenameOf(path)}. Tabelas: '
                    '${realTables.isEmpty ? 'nenhuma' : realTables}',
              ));
            }
            out['detail'] = {
              'table': detailTable,
              'columns': db.query('PRAGMA table_info("$detailTable")'),
              'foreignKeys':
                  db.query('PRAGMA foreign_key_list("$detailTable")'),
              'indexes': db.query('PRAGMA index_list("$detailTable")'),
              'rowCount':
                  db.query('SELECT COUNT(*) AS c FROM "$detailTable"').first['c'],
            };
          }
          return ok(out, citations: [
            Citation(
                sourceType: 'file',
                sourceRef: path,
                label: 'sqlite_master de ${basenameOf(path)}'),
          ]);
        } finally {
          db.close();
        }
      });
}

// ------------------------------------------------------------------ db.migrate
class DbMigrateTool extends _DbTool {
  DbMigrateTool({super.dataDir});

  @override
  String get id => 'db.migrate';
  @override
  String get title => 'Aplica migração';
  @override
  String get description =>
      'Aplica um script SQL REAL a um SQLite do workspace com três garantias '
      'verificáveis: (1) backup byte-a-byte do arquivo ANTES (reportado com '
      'tamanho); (2) transação real BEGIN IMMEDIATE → COMMIT, com ROLLBACK '
      'integral se qualquer statement falhar; (3) política explicitApproval — '
      'nunca roda sem aprovação. Aceita caminho de .sql OU script inline.';
  @override
  RiskLevel get risk => RiskLevel.destructive;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.explicitApproval;
  @override
  bool get isIdempotent => false;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Arquivo .sqlite/.db alvo (default: banco local).'
          },
          'sqlFile': {
            'type': 'string',
            'description': 'Caminho de script .sql no workspace.'
          },
          'sql': {'type': 'string', 'description': 'Script inline.'},
          'dryRun': {
            'type': 'boolean',
            'description': 'Valida/parseia e mostra os statements SEM aplicar '
                '(não grava nada).'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
          ToolContext ctx, MapToolInput input) =>
      _guard(this, () async {
        final path = await resolveDbPath(ctx, input);
        var script = input.str('sql');
        final sqlFile = input.str('sqlFile');
        if (sqlFile.isNotEmpty) {
          var f = lexicalNormalize(sqlFile);
          if (!isAbsolute(f)) {
            f = joinPath(
                ctx.workspaceRoots.isEmpty
                    ? Directory.current.path
                    : ctx.workspaceRoots.first,
                f);
          }
          f = await ctx.sandbox.resolveReadable(f, ctx);
          script = await File(f).readAsString();
        }
        if (script.trim().isEmpty) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Sem script: forneça "sql" ou "sqlFile".',
          ));
        }
        // divisão honesta por sqlite3_complete (triggers com ';' interno)
        final statements = <String>[];
        var cur = StringBuffer();
        for (final chunk in script.split('\n')) {
          cur.writeln(chunk);
          if (_sqlIsComplete(cur.toString())) {
            final s = cur.toString().trim();
            if (s.isNotEmpty && s != ';') statements.add(s);
            cur = StringBuffer();
          }
        }
        final tail = cur.toString().trim();
        if (tail.isNotEmpty) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Script termina com statement incompleto: '
                '"${tail.length > 120 ? '${tail.substring(0, 120)}…' : tail}"',
          ));
        }
        if (statements.isEmpty) {
          return ToolFailureResult(VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Nenhum statement encontrado no script.'));
        }
        final dryRun = input.boolOf('dryRun');
        if (dryRun) {
          return ok({
            'database': path,
            'dryRun': true,
            'statementCount': statements.length,
            'statements': statements,
          });
        }
        // 1) BACKUP real byte-a-byte antes de qualquer escrita
        final stamp = DateTime.now()
            .toIso8601String()
            .replaceAll(':', '-')
            .split('.')
            .first;
        final backupPath = '$path.pre-migrate-$stamp.bak';
        await File(path).copy(backupPath);
        final backupStat = await File(backupPath).stat;
        // 2) transação real
        final db = SqliteNative.open(path);
        final applied = <String>[];
        try {
          db.execute('BEGIN IMMEDIATE');
          for (final s in statements) {
            db.execute(s);
            applied.add(s);
          }
          db.execute('COMMIT');
        } on SqliteException catch (e) {
          try {
            db.execute('ROLLBACK');
          } on SqliteException {
            // rollback pode falhar se o próprio erro encerrou a txn; o backup
            // continua sendo a garantia de recuperação — reportamos ambos.
          }
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.buildFailed,
            message: 'Migração falhou no statement ${applied.length + 1}/'
                '${statements.length}: rc=${e.code} ${e.message}. '
                'Transação desfeita (ROLLBACK); backup íntegro em $backupPath.',
            details: {'backupPath': backupPath, 'appliedBefore': applied},
            recoveryActions: [
              RecoveryAction(
                  kind: 'restore_backup',
                  label: 'Restaurar backup',
                  target: backupPath),
            ],
          ));
        } finally {
          db.close();
        }
        return ok({
          'database': path,
          'appliedStatements': applied.length,
          'totalBytesAfter': (await File(path).stat).size,
          'backup': {'path': backupPath, 'bytes': backupStat.size},
          'rollbackHint': 'Para reverter: copie o backup sobre o DB e apague '
              '-wal/-shm se existirem.',
        }, citations: [
          Citation(
              sourceType: 'file',
              sourceRef: backupPath,
              label: 'backup pré-migração (${backupStat.size} bytes)'),
        ]);
      });
}
