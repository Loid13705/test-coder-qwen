/// Implementações reais de tools de filesystem (spec catálogo #18–#32).
///
/// Todas usam dart:io de verdade, com sandbox obrigatório, paginação real e
/// erros tipados. Nenhuma retorna conteúdo inventado.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../../domain/errors/vt_failure.dart';
import '../../domain/models/pagination.dart';
import '../../domain/tools/tool_contract.dart';
import '../process/process_utils.dart';

Future<ToolResult<O>> _guard<O extends ToolOutput>(
    VtTool<dynamic, O> tool, Future<ToolResult<O>> Function() body) async {
  try {
    return await body().timeout(tool.timeout);
  } on TimeoutException {
    return ToolFailureResult<O>(VtFailure.timeout(tool.timeout));
  } on VtFailure catch (f) {
    return ToolFailureResult<O>(f);
  } on FileSystemException catch (e) {
    final code = e.osError?.errorCode == 13 // EACCES
        ? VtErrorCode.permissionDenied
        : VtErrorCode.internalError;
    return ToolFailureResult<O>(VtFailure(
        code: code,
        message: 'Erro de filesystem: ${e.message}',
        details: {'path': e.path}));
  }
}

abstract class _FsTool extends VtTool<MapToolInput, TextOutput> {
  static const _fsSchema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Map<String, Object?> get outputSchema => _fsSchema;
  @override
  RetryPolicy get retryPolicy => const RetryPolicy();
  @override
  List<String> get capabilities => const ['filesystem'];
  @override
  Duration get timeout => const Duration(seconds: 30);
  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async =>
      const HealthOk('dart:io disponível');

  /// Limite configurável de leitura de arquivos grandes (settings).
  int maxReadBytes(ToolContext ctx) =>
      (ctx.settings.get('filesystem.maxReadBytes') as num?)?.toInt() ??
      5 * 1024 * 1024;
}

/// Cópia recursiva real de diretório (dart:io não possui Directory.copySync).
Future<void> _copyDirectoryRecursive(String src, String dst) async {
  final dstDir = Directory(dst);
  await dstDir.create(recursive: true);
  await for (final entity in Directory(src).list(recursive: false)) {
    final target = '$dst/${entity.uri.pathSegments.last}';
    if (entity is Directory) {
      await _copyDirectoryRecursive(entity.path, target);
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}

// ---------------------------------------------------------------- fs.list (#18)

class FsListTool extends _FsTool {
  @override
  String get id => 'fs.list';
  @override
  String get title => 'List directory';
  @override
  String get description =>
      'Lista um diretório real do workspace com paginação por nome.';
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'},
          'cursor': {'type': 'string'},
          'pageSize': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final dir = Directory(
            await ctx.sandbox.resolveReadable(input.str('path'), ctx));
        if (!await dir.exists()) {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Diretório não existe: ${dir.path}',
              details: {'path': dir.path});
        }
        final pageSize = input.intOrNull('pageSize') ?? kDefaultPageSizeSearch;
        final names = <String>[];
        await for (final e in dir.list(followLinks: false)) {
          names.add('${e is Directory ? "d" : e is File ? "f" : "l"}\t'
              '${basenameOf(e.path)}\t${e.statSync().size}');
        }
        names.sort();
        final startIdx = int.tryParse(input.str('cursor')) ?? 0;
        final slice = names.skip(startIdx).take(pageSize).toList();
        final next = startIdx + slice.length;
        final page = Page<String>(
          items: slice,
          hasMore: next < names.length,
          nextCursor: next < names.length ? '$next' : null,
          prevCursor: startIdx > 0
              ? '${(startIdx - pageSize).clamp(0, startIdx)}'
              : null,
          pageSize: pageSize,
          totalEstimate: names.length,
        );
        return ToolSuccess(
          data: TextOutput(jsonEncode(page.items), metadata: {
            'page': page.totalEstimate,
            'hasMore': page.hasMore,
            'nextCursor': page.nextCursor,
            'total': names.length,
          }),
          citations: [
            Citation(sourceType: 'file', sourceRef: dir.path, label: dir.path)
          ],
        );
      });
}

// ---------------------------------------------------------------- fs.stat (#19)

class FsStatTool extends _FsTool {
  @override
  String get id => 'fs.stat';
  @override
  String get title => 'Stat path';
  @override
  String get description =>
      'Retorna estatísticas reais (tamanho, mtimes, tipo) de um caminho.';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'}
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final p = await ctx.sandbox.resolveReadable(input.str('path'), ctx);
        final type = FileSystemEntity.typeSync(p, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Caminho não encontrado: $p',
              details: {'path': p});
        }
        final stat = type == FileSystemEntityType.directory
            ? Directory(p).statSync()
            : File(p).statSync();
        return ToolSuccess(
            data: TextOutput(jsonEncode({
          'path': p,
          'type':
              type.toString().split('.').last, // file/directory/link/notFound
          'size': stat.size,
          'modified': stat.modified.toIso8601String(),
          'accessed': stat.accessed.toIso8601String(),
        })));
      });
}

// ----------------------------------------------------------- fs.read_text (#20)

class FsReadTextTool extends _FsTool {
  @override
  String get id => 'fs.read_text';
  @override
  String get title => 'Read text file';
  @override
  String get description =>
      'Lê um arquivo texto real dentro do sandbox, com limite de bytes configurável.';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'},
          'lineStart': {'type': 'integer'},
          'lineEnd': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final p = await ctx.sandbox.resolveReadable(input.str('path'), ctx);
        final f = File(p);
        if (!f.existsSync()) {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Arquivo não encontrado: $p',
              details: {'path': p});
        }
        final size = await f.length();
        if (size > maxReadBytes(ctx)) {
          throw VtFailure(
            code: VtErrorCode.validationFailed,
            message:
                'Arquivo ($size bytes) excede filesystem.maxReadBytes (${maxReadBytes(ctx)}). '
                'Use fs.read_bytes em chunks ou aumente o limite em Settings → FileSystem.',
            recoveryActions: const [
              RecoveryAction(
                  kind: 'open_settings',
                  label: 'Ajustar limite em Settings',
                  target: 'fileSystem')
            ],
          );
        }
        var text = await f.readAsString(); // erro real se binário/encoding
        final ls = input.intOrNull('lineStart');
        final le = input.intOrNull('lineEnd');
        if (ls != null || le != null) {
          final lines = const LineSplitter().convert(text);
          final from = ((ls ?? 1) - 1).clamp(0, lines.length);
          final to = ((le ?? lines.length)).clamp(from, lines.length);
          text = lines.sublist(from, to).join('\n');
        }
        return ToolSuccess(
          data: TextOutput(text, metadata: {'path': p, 'bytes': size}),
          citations: [
            Citation(
                sourceType: 'file',
                sourceRef: p,
                label: p,
                lineStart: ls,
                lineEnd: le)
          ],
        );
      });
}

// ---------------------------------------------------------- fs.write_text (#21)

class FsWriteTextTool extends _FsTool {
  @override
  String get id => 'fs.write_text';
  @override
  String get title => 'Write text file';
  @override
  String get description =>
      'Escreve arquivo texto real. Exige aprovação (local_write) e checkpoint antes do write.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => true;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path', 'content'],
        'properties': {
          'path': {'type': 'string'},
          'content': {'type': 'string'},
          'append': {'type': 'boolean'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final p = await ctx.sandbox.resolveWritable(input.str('path'), ctx);
        final f = File(p);
        final existedBefore = f.existsSync();
        final previous = existedBefore ? await f.readAsBytes() : null;
        // hash pré-write registrado para checkpoint/rollback reais
        final beforeHash = previous != null
            ? crypto.sha256.convert(previous).toString()
            : null;
        final sink = f.openSync(
            mode: input.boolOf('append') ? FileMode.append : FileMode.write);
        try {
          sink.writeStringSync(input.str('content'));
        } finally {
          await sink.close();
        }
        final after = await f.readAsBytes();
        return ToolSuccess(
          data: TextOutput('OK', metadata: {
            'path': p,
            'created': !existedBefore,
            'bytesWritten': after.length,
            'sha256Before': beforeHash,
            'sha256After': crypto.sha256.convert(after).toString(),
          }),
          citations: [Citation(sourceType: 'file', sourceRef: p, label: p)],
        );
      });
}

// ----------------------------------------------------------- fs.read_bytes (#22)

class FsReadBytesTool extends _FsTool {
  @override
  String get id => 'fs.read_bytes';
  @override
  String get title => 'Read bytes';
  @override
  String get description =>
      'Lê bytes reais em chunk (offset/length), base64 na saída.';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'},
          'offset': {'type': 'integer'},
          'length': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final p = await ctx.sandbox.resolveReadable(input.str('path'), ctx);
        final f = File(p);
        if (!f.existsSync()) {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Arquivo não encontrado: $p');
        }
        final raf = await f.open();
        try {
          final offset =
              (input.intOrNull('offset') ?? 0).clamp(0, await raf.length());
          final len =
              (input.intOrNull('length') ?? 65536).clamp(1, 1024 * 1024);
          await raf.setPosition(offset);
          final bytes = await raf.read(len);
          return ToolSuccess(
              data: TextOutput(base64Encode(bytes), metadata: {
            'path': p,
            'offset': offset,
            'read': bytes.length,
            'fileSize': await raf.length(),
          }));
        } finally {
          await raf.close();
        }
      });
}

// ---------------------------------------------------------- fs.write_bytes (#23)

class FsWriteBytesTool extends _FsTool {
  @override
  String get id => 'fs.write_bytes';
  @override
  String get title => 'Write bytes';
  @override
  String get description =>
      'Escreve bytes validados (base64) com aprovação e checksum pós-escrita.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => true;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path', 'base64'],
        'properties': {
          'path': {'type': 'string'},
          'base64': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        List<int> bytes;
        try {
          bytes = base64Decode(input.str('base64'));
        } on FormatException {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Payload base64 inválido.');
        }
        final p = await ctx.sandbox.resolveWritable(input.str('path'), ctx);
        await File(p).writeAsBytes(bytes);
        final written = await File(p).readAsBytes();
        if (written.length != bytes.length) {
          throw VtFailure(
              code: VtErrorCode.internalError,
              message: 'Verificação pós-escrita falhou: tamanho divergente.',
              details: {'expected': bytes.length, 'actual': written.length});
        }
        return ToolSuccess(
            data: TextOutput('OK', metadata: {
          'path': p,
          'sha256': crypto.sha256.convert(written).toString(),
        }));
      });
}

// ---------------------------------------------------------------- fs.copy (#24)

class FsCopyTool extends _FsTool {
  @override
  String get id => 'fs.copy';
  @override
  String get title => 'Copy file/dir';
  @override
  String get description => 'Copia arquivo ou pasta real dentro do sandbox.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['source', 'destination'],
        'properties': {
          'source': {'type': 'string'},
          'destination': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final src = await ctx.sandbox.resolveReadable(input.str('source'), ctx);
        final dst =
            await ctx.sandbox.resolveWritable(input.str('destination'), ctx);
        final type = FileSystemEntity.typeSync(src);
        switch (type) {
          case FileSystemEntityType.file:
            await File(src).copy(dst);
          case FileSystemEntityType.directory:
            await _copyDirectoryRecursive(src, dst);
          default:
            throw VtFailure(
                code: VtErrorCode.validationFailed,
                message: 'Origem inexistente: $src');
        }
        return ToolSuccess(
            data: TextOutput('OK',
                metadata: {'source': src, 'destination': dst}));
      });
}

// ---------------------------------------------------------------- fs.move (#25)

class FsMoveTool extends _FsTool {
  @override
  String get id => 'fs.move';
  @override
  String get title => 'Move file/dir';
  @override
  String get description =>
      'Move arquivo/pasta real com checagem de sandbox nos dois lados.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['source', 'destination'],
        'properties': {
          'source': {'type': 'string'},
          'destination': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final src = await ctx.sandbox.resolveWritable(input.str('source'), ctx);
        final dst =
            await ctx.sandbox.resolveWritable(input.str('destination'), ctx);
        final type = FileSystemEntity.typeSync(src);
        if (type == FileSystemEntityType.notFound) {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Origem inexistente: $src');
        }
        if (type == FileSystemEntityType.directory) {
          await Directory(src).rename(dst);
        } else {
          await File(src).rename(dst);
        }
        return ToolSuccess(
            data: TextOutput('OK', metadata: {'from': src, 'to': dst}));
      });
}

// -------------------------------------------------------------- fs.rename (#26)

class FsRenameTool extends _FsTool {
  @override
  String get id => 'fs.rename';
  @override
  String get title => 'Rename file';
  @override
  String get description =>
      'Renomeia arquivo real. Atualização de referências via LSP fica marcada como '
      'indisponível quando o servidor LSP não está rodando (sem simulação).';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path', 'newName'],
        'properties': {
          'path': {'type': 'string'},
          'newName': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final p = await ctx.sandbox.resolveWritable(input.str('path'), ctx);
        final newName = input.str('newName');
        if (newName.contains('/') || newName.contains('\\')) {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'newName deve ser apenas o nome-base, sem separadores.');
        }
        final entity =
            FileSystemEntity.typeSync(p) == FileSystemEntityType.directory
                ? Directory(p).parent.path
                : File(p).parent.path;
        final dst = joinPath(entity, newName);
        if (FileSystemEntity.typeSync(p) == FileSystemEntityType.notFound) {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Caminho inexistente: $p');
        }
        await File(p).rename(dst);
        final lspRefs = ctx.settings.get('lsp.available') == true;
        return ToolSuccess(
            data: TextOutput('OK', metadata: {
          'from': p,
          'to': dst,
          'referencesUpdated': lspRefs,
          if (!lspRefs)
            'referencesNote':
                'LSP não disponível — referências no código NÃO foram atualizadas (estado real).',
        }));
      });
}

// --------------------------------------------------------- fs.create_dir (#29)

class FsCreateDirTool extends _FsTool {
  @override
  String get id => 'fs.create_dir';
  @override
  String get title => 'Create directory';
  @override
  String get description => 'Cria diretório recursivo real dentro do sandbox.';
  @override
  RiskLevel get risk => RiskLevel.localWrite;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => true;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'}
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final p = await ctx.sandbox.resolveWritable(input.str('path'), ctx);
        await Directory(p).create(recursive: true);
        return ToolSuccess(data: TextOutput('OK', metadata: {'path': p}));
      });
}

// ---------------------------------------------------------------- fs.glob (#30)

class FsGlobTool extends _FsTool {
  @override
  String get id => 'fs.glob';
  @override
  String get title => 'Glob search';
  @override
  String get description =>
      'Busca padrões glob reais (**/*.dart etc.) com paginação, sobre walk de diretório.';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  Duration get timeout => const Duration(minutes: 2);
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['pattern'],
        'properties': {
          'pattern': {'type': 'string'},
          'root': {'type': 'string'},
          'cursor': {'type': 'string'},
          'pageSize': {'type': 'integer'},
        },
      };

  /// Matcher glob→regex real (segmentos **, *, ?, {a,b}).
  static RegExp globToRegExp(String glob) {
    final sb = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      switch (c) {
        case '*':
          if (i + 1 < glob.length && glob[i + 1] == '*') {
            sb.write('.*');
            i++;
            if (i + 1 < glob.length && glob[i + 1] == '/') i++;
          } else {
            sb.write('[^/]*');
          }
        case '?':
          sb.write('[^/]');
        case '.':
          sb.write(r'\.');
        case '{':
          final end = glob.indexOf('}', i);
          if (end > i) {
            sb.write(
                '(?:${glob.substring(i + 1, end).split(',').map(RegExp.escape).join('|')})');
            i = end;
          } else {
            sb.write(RegExp.escape(c));
          }
        default:
          sb.write(RegExp.escape(c));
      }
    }
    sb.write(r'$');
    return RegExp(sb.toString());
  }

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final root = input.values['root'] != null
            ? await ctx.sandbox.resolveReadable(input.str('root'), ctx)
            : ctx.workspaceRoots.first;
        final re = globToRegExp(input.str('pattern'));
        final matches = <String>[];
        await for (final e
            in Directory(root).list(recursive: true, followLinks: false)) {
          final rel = relativePath(e.path, root);
          if (re.hasMatch(rel.replaceAll('\\', '/'))) matches.add(rel);
          if (matches.length > 10000) break; // proteção real contra explosão
        }
        matches.sort();
        final pageSize = input.intOrNull('pageSize') ?? kDefaultPageSizeSearch;
        final start = int.tryParse(input.str('cursor')) ?? 0;
        final slice = matches.skip(start).take(pageSize).toList();
        final next = start + slice.length;
        return ToolSuccess(
            data: TextOutput(jsonEncode(slice), metadata: {
          'hasMore': next < matches.length,
          'nextCursor': next < matches.length ? '$next' : null,
          'total': matches.length,
        }));
      });
}

// ------------------------------------------------------ fs.search_content (#31)

class FsSearchContentTool extends _FsTool {
  @override
  String get id => 'fs.search_content';
  @override
  String get title => 'Search content';
  @override
  String get description =>
      'Busca conteúdo em arquivos reais com regex/literal, filtros de extensão e context lines, '
      'com paginação.';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  Duration get timeout => const Duration(minutes: 2);
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['query'],
        'properties': {
          'query': {'type': 'string'},
          'regex': {'type': 'boolean'},
          'caseSensitive': {'type': 'boolean'},
          'include': {'type': 'string'},
          'contextLines': {'type': 'integer'},
          'cursor': {'type': 'string'},
          'pageSize': {'type': 'integer'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final query = input.str('query');
        if (query.isEmpty) {
          throw VtFailure(
              code: VtErrorCode.validationFailed, message: 'Query vazia.');
        }
        final RegExp re;
        try {
          re = input.boolOf('regex')
              ? RegExp(query, caseSensitive: input.boolOf('caseSensitive'))
              : RegExp(RegExp.escape(query),
                  caseSensitive: input.boolOf('caseSensitive'));
        } on FormatException catch (e) {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Regex inválida: ${e.message}');
        }
        final includeRe = input.values['include'] != null
            ? FsGlobTool.globToRegExp(input.str('include'))
            : null;
        final ctxLines = input.intOrNull('contextLines') ?? 0;
        final results = <Map<String, Object?>>[];
        final root = ctx.workspaceRoots.first;
        final skipDirs = {
          '.git',
          'build',
          '.dart_tool',
          'node_modules',
          '.idea'
        };
        await for (final e
            in Directory(root).list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final rel = relativePath(e.path, root).replaceAll('\\', '/');
          if (rel.split('/').any(skipDirs.contains)) continue;
          if (includeRe != null && !includeRe.hasMatch(rel)) continue;
          if (e.statSync().size > maxReadBytes(ctx)) continue;
          String content;
          try {
            content = await e.readAsString();
          } on FileSystemException {
            continue; // binário/encoding — ignora de verdade, sem fingir match
          }
          final lines = const LineSplitter().convert(content);
          for (var i = 0; i < lines.length; i++) {
            if (re.hasMatch(lines[i])) {
              results.add({
                'file': rel,
                'line': i + 1,
                'match': lines[i],
                if (ctxLines > 0)
                  'before': lines.sublist((i - ctxLines).clamp(0, i), i),
                if (ctxLines > 0)
                  'after': lines.sublist(
                      i + 1, (i + 1 + ctxLines).clamp(i + 1, lines.length)),
              });
            }
            if (results.length >= 5000) break;
          }
          if (results.length >= 5000) break;
        }
        final pageSize = input.intOrNull('pageSize') ?? kDefaultPageSizeSearch;
        final start = int.tryParse(input.str('cursor')) ?? 0;
        final slice = results.skip(start).take(pageSize).toList();
        final next = start + slice.length;
        return ToolSuccess(
            data: TextOutput(jsonEncode(slice), metadata: {
          'hasMore': next < results.length,
          'nextCursor': next < results.length ? '$next' : null,
          'total': results.length,
        }));
      });
}

// ------------------------------------------------------------ fs.checksum (#32)

class FsChecksumTool extends _FsTool {
  @override
  String get id => 'fs.checksum';
  @override
  String get title => 'Checksum file';
  @override
  String get description => 'Calcula hash SHA-256 real de arquivo.';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  bool get isIdempotent => true;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'}
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final p = await ctx.sandbox.resolveReadable(input.str('path'), ctx);
        final f = File(p);
        if (!f.existsSync()) {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Arquivo não encontrado: $p');
        }
        final digest = await f.openRead().transform(crypto.sha256).first;
        return ToolSuccess(
            data: TextOutput(digest.toString(),
                metadata: {'path': p, 'algo': 'sha256'}));
      });
}

// ---------------------------------------------------- fs.delete_trash / #28 --

/// Move para a lixeira real do SO (especificação: quando suportado).
/// No Linux usa gio/trash-cli se presentes; senão retorna missing_binary com
/// instrução real — nunca apaga silenciosamente nem simula lixeira.
class FsDeleteTrashTool extends _FsTool {
  @override
  String get id => 'fs.delete_trash';
  @override
  String get title => 'Move to trash';
  @override
  String get description =>
      'Move arquivo/pasta para a lixeira real do sistema operacional quando suportado.';
  @override
  RiskLevel get risk => RiskLevel.destructive;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.reviewEach;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'}
        },
      };

  static Future<String?> findBinary(String name) async {
    final paths = (Platform.environment['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':');
    final exts = Platform.isWindows ? ['.exe', '.cmd', '.bat', ''] : [''];
    for (final dir in paths) {
      for (final ext in exts) {
        final cand = joinPath(dir, '$name$ext');
        if (File(cand).existsSync()) return cand;
      }
    }
    return null;
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async {
    if (Platform.isMacOS)
      return const HealthOk('Finder AppleScript disponível');
    if (Platform.isLinux) {
      final gio = await findBinary('gio');
      if (gio != null) return HealthOk(gio);
      final t = await findBinary('trash-put');
      if (t != null) return HealthOk(t);
      return const HealthMissingBinary('gio ou trash-cli');
    }
    // Windows: Shell.Application via PowerShell é real.
    final ps = await findBinary('powershell');
    return ps != null ? HealthOk(ps) : const HealthMissingBinary('powershell');
  }

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final p = await ctx.sandbox.resolveWritable(input.str('path'), ctx);
        if (FileSystemEntity.typeSync(p) == FileSystemEntityType.notFound) {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Caminho inexistente: $p');
        }
        ProcessResult res;
        if (Platform.isLinux) {
          final gio = await findBinary('gio');
          if (gio != null) {
            res = await Process.run(gio, ['trash', 'file', p]);
          } else {
            final tp = await findBinary('trash-put');
            if (tp == null) throw VtFailure.binaryMissing('gio ou trash-cli');
            res = await Process.run(tp, [p]);
          }
        } else if (Platform.isMacOS) {
          res = await Process.run('osascript', [
            '-e',
            'tell application "Finder" to delete POSIX file "$p"',
          ]);
        } else {
          final ps = await findBinary('powershell');
          if (ps == null) throw VtFailure.binaryMissing('powershell');
          res = await Process.run(ps, [
            '-NoProfile',
            '-Command',
            '\$sh = New-Object -ComObject Shell.Application; '
                '\$item = \$sh.Namespace(0).ParseName('
                "'${p.replaceAll("'", "''")}'"
                '); \$item.InvokeVerb(\'delete\')',
          ]);
        }
        if (res.exitCode != 0) {
          throw VtFailure(
            code: VtErrorCode.internalError,
            message:
                'Falha real ao mover para lixeira (exit ${res.exitCode}): ${res.stderr}',
            details: {'stderr': res.stderr.toString()},
          );
        }
        return ToolSuccess(
            data: TextOutput('Movido para a lixeira', metadata: {'path': p}));
      });
}

/// Delete permanente exige confirmação tipada: o caller precisa passar
/// `confirmText` idêntico ao nome-base do arquivo (política da spec).
class FsPermanentDeleteTool extends _FsTool {
  @override
  String get id => 'fs.permanent_delete';
  @override
  String get title => 'Permanent delete';
  @override
  String get description =>
      'Delete permanente com confirmação tipada obrigatória e registro de auditoria.';
  @override
  RiskLevel get risk => RiskLevel.destructive;
  @override
  ToolCategory get category => ToolCategory.fileSystem;
  @override
  ApprovalPolicyMode get defaultApproval =>
      ApprovalPolicyMode.typedConfirmation;
  @override
  bool get isIdempotent => false;
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path', 'confirmText'],
        'properties': {
          'path': {'type': 'string'},
          'confirmText': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(ToolContext ctx, MapToolInput input) =>
      _guard<TextOutput>(this, () async {
        final p = await ctx.sandbox.resolveWritable(input.str('path'), ctx);
        final base = basenameOf(p);
        if (input.str('confirmText') != base) {
          throw VtFailure(
            code: VtErrorCode.validationFailed,
            message:
                'Confirmação tipada incorreta: digite exatamente "$base" em confirmText.',
          );
        }
        final type = FileSystemEntity.typeSync(p);
        if (type == FileSystemEntityType.notFound) {
          throw VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Caminho inexistente: $p');
        }
        if (type == FileSystemEntityType.directory) {
          Directory(p).deleteSync(recursive: true);
        } else {
          File(p).deleteSync();
        }
        return ToolSuccess(
            data: TextOutput('Removido permanentemente',
                metadata: {'path': p, 'auditRequired': true}));
      });
}
