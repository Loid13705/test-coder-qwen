/// Ferramentas de editor/Dart reais (spec §EDITOR): diagnósticos via
/// `dart analyze --format=machine`, formatação via `dart format` e snippets
/// do catálogo. Sem binário `dart`: falha tipada `binary_missing` com
/// instrução real — NUNCA diagnostics simulados.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import '../process/process_utils.dart';

Future<String?> resolveDart(ToolContext ctx) async {
  final custom = ctx.settings.get('dart.binaryPath') as String?;
  if (custom != null && File(custom).existsSync()) return custom;
  return findBinaryInPath('dart');
}

abstract class _EditorTool extends VtTool<MapToolInput, TextOutput> {
  @override
  ToolCategory get category => ToolCategory.editor;
  @override
  List<String> get capabilities => const ['filesystem'];
  @override
  Duration get timeout => const Duration(seconds: 120);
  @override
  RetryPolicy get retryPolicy => const RetryPolicy();
  @override
  bool get isIdempotent => true;
  @override
  Map<String, Object?> get outputSchema => const {'type': 'object'};

  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async {
    final dart = await resolveDart(ctx);
    return dart == null
        ? const HealthMissingBinary('dart')
        : const HealthOk('dart SDK encontrado');
  }

  /// Raiz do projeto Dart: sobe até achar pubspec.yaml; senão workspace root.
  String projectRoot(ToolContext ctx, String filePath) {
    var dir = dirname(filePath);
    for (var i = 0; i < 12 && dir.isNotEmpty && dir != '/'; i++) {
      if (File(joinPath(dir, 'pubspec.yaml')).existsSync()) return dir;
      final parent = dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
    return ctx.workspaceRoots.isEmpty ? '.' : ctx.workspaceRoots.first;
  }

  static String relativeTo(String root, String target) =>
      target.startsWith(root)
          ? target.substring(root.length).replaceFirst(RegExp(r'^[/\\]'), '')
          : target;
}

/// #editor.diagnostics — roda `dart analyze --format=machine` no alvo e
/// devolve linhas SEVERITY|TYPE|FILE|LINE|COL|LENGTH|MESSAGE como JSON.
class EditorDiagnosticsTool extends _EditorTool {
  @override
  String get id => 'editor.diagnostics';
  @override
  String get title => 'Dart diagnostics (dart analyze)';
  @override
  String get description =>
      'Executa "dart analyze --format=machine" REAL no arquivo/pasta e '
      'retorna diagnostics estruturados. Sem dart no PATH: binary_missing '
      'com instrução — nunca inventa problemas.';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'},
        },
      };

  static final _lineRe = RegExp(
      r'^([A-Z][A-Z_]*)\|[A-Z ]*\|([^|]*)\|(\d+)\|(\d+)\|(\d+)\|(.*)$');

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final dart = await resolveDart(ctx);
    if (dart == null) {
      return ToolFailureResult(VtFailure.binaryMissing('dart',
          hint: 'Instale o Dart SDK ou defina "dart.binaryPath" em Settings.'));
    }
    try {
      final target = await ctx.sandbox.resolveReadable(input.str('path'), ctx);
      final root = projectRoot(ctx, target);
      final relative = relativeTo(root, target);
      ProcessResult res;
      try {
        res = await Process.run(
                dart, ['analyze', '--format=machine', relative],
                workingDirectory: root)
            .timeout(timeout);
      } on ProcessException catch (e) {
        return ToolFailureResult(VtFailure(
            code: VtErrorCode.binaryMissing,
            message: 'Falha ao iniciar "dart": ${e.message}'));
      } on TimeoutException {
        return ToolFailureResult(VtFailure.timeout(timeout));
      }
      final items = <Map<String, Object?>>[];
      for (final raw in const LineSplitter().convert(res.stdout as String)) {
        final m = _lineRe.firstMatch(raw.trim());
        if (m == null) continue;
        items.add({
          'severity': switch (m.group(1)) {
            'ERROR' => 'error',
            'WARNING' => 'warning',
            _ => 'info',
          },
          'file': m.group(2)!.trim(),
          'line': int.parse(m.group(3)!),
          'column': int.parse(m.group(4)!),
          'length': int.parse(m.group(5)!),
          'message': m.group(6)!.trim(),
        });
      }
      return ToolSuccess(
          data: TextOutput(
        jsonEncode({'target': target, 'count': items.length, 'items': items}),
        metadata: {'exitCode': res.exitCode, 'count': items.length},
      ));
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    }
  }
}

/// #editor.format — `dart format -o show` e devolve o texto formatado; o
/// editor aplica como edição normal (undo-friendly), sem tocar no disco.
class EditorFormatTool extends _EditorTool {
  @override
  String get id => 'editor.format';
  @override
  String get title => 'Format file (dart format)';
  @override
  String get description =>
      'Roda "dart format -o show" REAL no arquivo e retorna o conteúdo '
      'formatado para o editor aplicar como edição (Ctrl+Shift+L).';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final dart = await resolveDart(ctx);
    if (dart == null) {
      return ToolFailureResult(VtFailure.binaryMissing('dart',
          hint: 'Instale o Dart SDK ou defina "dart.binaryPath" em Settings.'));
    }
    try {
      final target = await ctx.sandbox.resolveReadable(input.str('path'), ctx);
      final root = projectRoot(ctx, target);
      final relative = relativeTo(root, target);
      ProcessResult res;
      try {
        res = await Process.run(dart, ['format', '-o', 'show', relative],
                workingDirectory: root)
            .timeout(timeout);
      } on ProcessException catch (e) {
        return ToolFailureResult(VtFailure(
            code: VtErrorCode.binaryMissing,
            message: 'Falha ao iniciar "dart": ${e.message}'));
      } on TimeoutException {
        return ToolFailureResult(VtFailure.timeout(timeout));
      }
      if (res.exitCode != 0) {
        return ToolFailureResult(VtFailure(
            code: VtErrorCode.internalError,
            message: 'dart format falhou (exit ${res.exitCode}): '
                '${(res.stderr as String?)?.trim() ?? ''}',
            details: {'stderr': res.stderr}));
      }
      final out = res.stdout as String;
      // `-o show` imprime o conteúdo formatado (com header "Formatted ..."
      // em algumas versões): remove o header se presente.
      final body = out.replaceFirst(RegExp(r'^Formatted \d+ files?[^\n]*\n'), '');
      if (body.trim().isEmpty) {
        // fallback honesto: dart format já escreveu no arquivo; relê o real.
        final formatted = await File(target).readAsString();
        return ToolSuccess(data: TextOutput(formatted));
      }
      return ToolSuccess(data: TextOutput(body));
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    } on FileSystemException catch (e) {
      return ToolFailureResult(VtFailure(
          code: VtErrorCode.internalError,
          message: 'Erro lendo formato: ${e.message}'));
    }
  }
}

/// #editor.snippets — lista snippets REAIS da linguagem (built-in + settings
/// `editor.snippets.<lang>`), fonte que a UI consome para autocomplete.
class EditorSnippetsTool extends _EditorTool {
  @override
  String get id => 'editor.snippets';
  @override
  String get title => 'List editor snippets';
  @override
  String get description =>
      'Retorna os snippets disponíveis para uma linguagem (built-in + '
      'settings editor.snippets.<lang>).';
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;
  @override
  List<String> get capabilities => const [];

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'language': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final lang = input.str('language');
    final builtin = _builtinByLang(lang);
    final custom = ctx.settings.get('editor.snippets.$lang');
    final merged = <Map<String, Object?>>[
      ...builtin,
      if (custom is Map)
        for (final e in custom.entries)
          if (e.value is Map || e.value is List)
            {
              'prefix': e.key,
              'body': e.value is Map
                  ? ((e.value as Map)['body'] ?? e.value)
                  : e.value,
              'source': 'settings',
            },
    ];
    return ToolSuccess(
        data: TextOutput(jsonEncode({'language': lang, 'snippets': merged})));
  }

  static List<Map<String, Object?>> _builtinByLang(String lang) {
    if (lang != 'dart') return const [];
    return const [
      {'prefix': 'main', 'body': ['void main() {', '  ', '}'], 'source': 'builtin'},
      {
        'prefix': 'test',
        'body': ["test('', () async {", '  ', '});'],
        'source': 'builtin'
      },
      {
        'prefix': 'widget',
        'body': [
          'class MyWidget extends StatelessWidget {',
          '  const MyWidget({super.key});',
          '',
          '  @override',
          '  Widget build(BuildContext context) {',
          '    return ',
          '  }',
          '}',
        ],
        'source': 'builtin'
      },
    ];
  }
}
