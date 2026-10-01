/// Funcionalidades de linguagem do Editor real (spec §EDITOR) — tudo derivado
/// do texto efetivo, NUNCA simulando semântica de LSP.
///
/// - [languageForPath]: mapeamento honesto por extensão (label usada na UI);
///   quando não há analyzer/LSP ativo a UI rotula como "sintaxe lexical".
/// - [outlineOf] / [symbolNameAt]: outline e go-to-symbol por heurística
///   léxica clara (linhas que PARECEM declarações), com linha exata do texto.
/// - [bracketPairFor]: auto-close com balanceamento real (skip de close).
/// - [wrappedRanges]: soft-wrap pré-computado para virtualização por viewport.
/// - [kSnippets]/[Snippet.expand]: snippets reais com placeholders ${1:...}.
/// - [emmetExpand]: Emmet-like opcional (div.card>ul>li*3 → HTML real).
library;

import 'dart:convert';

class OutlineEntry {
  const OutlineEntry({
    required this.name,
    required this.kind,
    required this.line,
    required this.indent,
  });
  final String name;
  final String kind; // class|mixin|enum|extension|typedef|function|field|section|heading
  /// Linha zero-based no buffer canônico (LF).
  final int line;
  final int indent;

  String get display => kind == 'class' ? '$name (classe)' : name;
}

bool isProbablyTextFile(String path) {
  final lower = path.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot < 0) {
    final base = lower.split('/').last;
    return base.startsWith('dockerfile') ||
        base.startsWith('makefile') ||
        base.contains('readme') ||
        base.contains('license');
  }
  return kTextExtensions.contains(lower.substring(dot));
}

String languageForPath(String path) {
  final lower = path.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot < 0) {
    final base = lower.split('/').last;
    if (base.startsWith('dockerfile')) return 'dockerfile';
    if (base.startsWith('makefile')) return 'makefile';
    if (base.startsWith('gemfile')) return 'ruby';
    return 'plaintext';
  }
  final ext = lower.substring(dot);
  return switch (ext) {
    '.dart' => 'dart',
    '.ts' || '.tsx' => 'typescript',
    '.js' || '.jsx' || '.mjs' || '.cjs' => 'javascript',
    '.py' => 'python',
    '.rs' => 'rust',
    '.go' => 'go',
    '.java' => 'java',
    '.kt' || '.kts' => 'kotlin',
    '.swift' => 'swift',
    '.c' || '.h' => 'c',
    '.cpp' || '.hpp' || '.cc' => 'cpp',
    '.cs' => 'csharp',
    '.rb' => 'ruby',
    '.php' => 'php',
    '.html' || '.htm' || '.vue' || '.svelte' => 'html',
    '.css' || '.scss' || '.sass' || '.less' => 'css',
    '.json' || '.avsc' => 'json',
    '.yaml' || '.yml' => 'yaml',
    '.toml' => 'toml',
    '.xml' => 'xml',
    '.md' || '.markdown' => 'markdown',
    '.sh' || '.bash' || '.zsh' || '.fish' => 'shell',
    '.ps1' => 'powershell',
    '.sql' => 'sql',
    '.graphql' || '.gql' => 'graphql',
    '.proto' => 'protobuf',
    '.gradle' => 'groovy',
    '.tf' => 'terraform',
    '.lua' => 'lua',
    _ => 'plaintext',
  };
}

// ------------------------------------------------------------------ outline

final _declarationRes = <RegExp, String>{
  RegExp(r'^\s*(?:abstract\s+)?(?:sealed\s+)?(?:base\s+)?(?:final\s+)?class\s+([A-Za-z_$][\w$]*)'): 'class',
  RegExp(r'^\s*mixin\s+([A-Za-z_$][\w$]*)'): 'mixin',
  RegExp(r'^\s*enum\s+([A-Za-z_$][\w$]*)'): 'enum',
  RegExp(r'^\s*typedef\s+([A-Za-z_$][\w$]*)'): 'typedef',
};

final _fnRe = RegExp(
    r'^\s*(?:@override\s*)?(?:static\s+|final\s+|const\s+|late\s+)*'
    r'(?:Future<[^<>]*(?:<[^<>]*>)?>\s+|void\s+|String\s+|int\s+|double\s+|bool\s+)?'
    r'([A-Za-z_$][\w$]*)\s*\([^;=]*\)\s*(?:async\s*)?\{\s*$');
final _fieldRe = RegExp(
    r'^\s*(?:static\s+|final\s+|late\s+)*(?:[A-Z][\w<>, ?]*\s+)?'
    r'([a-z_$][\w$]*)\s*[=;]\s*.*$');

final _sectionRe = RegExp(r'^(#{1,6})\s+(.+)$');
final _commentBannerRe =
    RegExp(r'^\s*/[/*]+\s*=+\s*(.+?)\s*=+\s*[/*]+\s*$|^\s*//\s*-{4,}\s*(.*)');
final _jsClassRe =
    RegExp(r'^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)');
final _jsFnRe = RegExp(r'^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)');
final _jsArrowRe =
    RegExp(r'^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?[(\w]+\s*(=>|\()');
final _pyDefRe = RegExp(r'^\s*(?:async\s+)?def\s+([A-Za-z_][\w]*)');
final _pyClassRe = RegExp(r'^\s*class\s+([A-Za-z_][\w]*)');
final _rustFnRe = RegExp(r'^\s*(?:pub\s+)?(?:async\s+)?fn\s+([A-Za-z_][\w]*)');
final _rustImplRe =
    RegExp(r'^\s*(?:pub\s+)?(?:unsafe\s+)?impl(?:<[^>]*>)?\s+([A-Za-z_][\w:<>, ]*)');
final _goFnRe = RegExp(r'^func\s+(?:\([^)]*\)\s+)?([A-Za-z_][\w]*)');
final _cssRuleRe = RegExp(r'^([.#][A-Za-z_][\w-]*)\s*[,{]');

/// Outline léxico REAL do conteúdo (sem LSP): linhas que são declaração.
List<OutlineEntry> outlineOf(String text, String language) {
  final lines = const LineSplitter().convert(text);
  final out = <OutlineEntry>[];
  for (var i = 0; i < lines.length && out.length < 5000; i++) {
    final line = lines[i];
    if (line.isEmpty) continue;
    final indent = line.length - line.trimLeft().length;
    switch (language) {
      case 'markdown':
        final m = _sectionRe.firstMatch(line);
        if (m != null) {
          out.add(OutlineEntry(
              name: m.group(2)!,
              kind: 'heading',
              line: i,
              indent: m.group(1)!.length - 1));
        }
        continue;
      case 'yaml' || 'toml':
        final sec = RegExp(r'^\[([^\]]+)\]').firstMatch(line.trim());
        if (sec != null) {
          out.add(OutlineEntry(
              name: sec.group(1)!, kind: 'section', line: i, indent: indent));
          continue;
        }
        final m = RegExp(r'^([A-Za-z_][\w.-]*):').firstMatch(line);
        if (m != null && !line.trimLeft().startsWith('#')) {
          out.add(OutlineEntry(
              name: m.group(1)!, kind: 'field', line: i, indent: indent));
        }
        continue;
      case 'json':
        final m = RegExp(r'^"([^"]+)"\s*:').firstMatch(line.trimLeft());
        if (m != null) {
          out.add(OutlineEntry(
              name: m.group(1)!, kind: 'field', line: i, indent: indent));
        }
        continue;
      case 'javascript' || 'typescript':
        var m = _jsClassRe.firstMatch(line);
        if (m != null) {
          out.add(OutlineEntry(
              name: m.group(1)!, kind: 'class', line: i, indent: indent));
          continue;
        }
        m = _jsFnRe.firstMatch(line) ?? _jsArrowRe.firstMatch(line);
        if (m != null) {
          out.add(OutlineEntry(
              name: m.group(1)!, kind: 'function', line: i, indent: indent));
        }
        continue;
      case 'python':
        var m = _pyClassRe.firstMatch(line);
        if (m != null) {
          out.add(OutlineEntry(
              name: m.group(1)!, kind: 'class', line: i, indent: indent));
          continue;
        }
        m = _pyDefRe.firstMatch(line);
        if (m != null) {
          out.add(OutlineEntry(
              name: m.group(1)!, kind: 'function', line: i, indent: indent));
        }
        continue;
      case 'rust':
        var m = _rustImplRe.firstMatch(line);
        if (m != null) {
          out.add(OutlineEntry(
              name: 'impl ${m.group(1)!.trim()}',
              kind: 'class',
              line: i,
              indent: indent));
          continue;
        }
        m = _rustFnRe.firstMatch(line);
        if (m != null) {
          out.add(OutlineEntry(
              name: m.group(1)!, kind: 'function', line: i, indent: indent));
        }
        continue;
      case 'go':
        final m = _goFnRe.firstMatch(line);
        if (m != null) {
          out.add(OutlineEntry(
              name: m.group(1)!, kind: 'function', line: i, indent: indent));
        }
        continue;
      case 'css' || 'scss' || 'less':
        final m = _cssRuleRe.firstMatch(line.trim());
        if (m != null) {
          out.add(OutlineEntry(
              name: m.group(1)!, kind: 'section', line: i, indent: indent));
        }
        continue;
      default:
        break;
    }
    if (_commentBannerRe.hasMatch(line)) {
      final m = _commentBannerRe.firstMatch(line)!;
      final title = (m.group(1) ?? m.group(2) ?? '').trim();
      if (title.isNotEmpty) {
        out.add(OutlineEntry(
            name: title, kind: 'section', line: i, indent: indent));
      }
      continue;
    }
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//') ||
        trimmed.startsWith('/*') ||
        trimmed.startsWith('*')) {
      continue;
    }
    var matched = false;
    for (final e in _declarationRes.entries) {
      final m = e.key.firstMatch(line);
      if (m != null) {
        out.add(OutlineEntry(
            name: m.group(1)!, kind: e.value, line: i, indent: indent));
        matched = true;
        break;
      }
    }
    if (matched) continue;
    final fm = _fnRe.firstMatch(line);
    if (fm != null && trimmed.contains('(') && !trimmed.startsWith('if')) {
      out.add(OutlineEntry(
          name: '${fm.group(1)}()', kind: 'function', line: i, indent: indent));
      continue;
    }
    if (indent > 0) {
      final fld = _fieldRe.firstMatch(line);
      if (fld != null &&
          !trimmed.contains('=>') &&
          !trimmed.startsWith('return') &&
          !trimmed.contains('(')) {
        out.add(OutlineEntry(
            name: fld.group(1)!, kind: 'field', line: i, indent: indent));
      }
    }
  }
  return out;
}

/// Nome do símbolo vigente na linha do caret (status bar / go to symbol).
String? symbolNameAt(List<OutlineEntry> outline, int caretLine) {
  String? best;
  var bestLine = -1;
  for (final e in outline) {
    if (e.line <= caretLine && e.line > bestLine) {
      bestLine = e.line;
      best = e.name;
    }
  }
  return best;
}

// ------------------------------------------------------------ bracket pairs

const Map<String, String> kBracketPairs = {
  '(': ')', '[': ']', '{': '}', '"': '"', "'": "'", '`': '`', '<': '>',
};

(String, String)? bracketPairFor(String ch) {
  final close = kBracketPairs[ch];
  return close == null ? null : (ch, close);
}

// ------------------------------------------------------------- word wrap

/// Linhas lógicas -> faixes de visual (soft wrap em colunas fixas). Usado
/// pela lista virtualizada (spec §LARGE FILES: lazy load por viewport).
List<(int, int)> wrappedRanges(List<String> lines, int columnWidth) {
  final ranges = <(int, int)>[];
  for (var i = 0; i < lines.length; i++) {
    final len = lines[i].length;
    final parts = len == 0 ? 1 : (len / columnWidth).ceil();
    for (var p = 0; p < parts; p++) {
      ranges.add((i, p));
    }
  }
  return ranges;
}

// -------------------------------------------------------------- snippets

class Snippet {
  const Snippet(this.prefix, this.body, this.langs, this.description);
  final String prefix;
  final List<String> body;
  final Set<String> langs;
  final String description;

  /// Substitui `${1:text}` → text; cursor vai ao primeiro grupo 1.
  static (String, int?) expand(List<String> bodyLines) {
    final sb = StringBuffer();
    int? cursorOffset;
    var offset = 0;
    for (final raw in bodyLines) {
      var l = raw;
      final m = RegExp(r'\$\{(\d+):([^}]*)\}').firstMatch(l);
      if (m != null) {
        final group = int.parse(m.group(1)!);
        l = l.replaceFirst(m.group(0)!, m.group(2)!);
        if (group == 1 && cursorOffset == null) {
          cursorOffset = offset + m.start;
        }
      }
      l = l.replaceAllMapped(RegExp(r'\$\{\d+\}'), (_) => '');
      sb.writeln(l);
      offset += l.length + 1;
    }
    return (sb.toString(), cursorOffset);
  }
}

const kSnippets = <Snippet>[
  Snippet('main', ['void main() {', '  \$0', '}'], {'dart'}, 'função main'),
  Snippet('test', ["test('\${1:name}', () async {", '  \$0', '});'],
      {'dart'}, 'bloco test()'),
  Snippet('widget', [
    'class \${1:MyWidget} extends StatelessWidget {',
    '  const \${1:MyWidget}({super.key});',
    '',
    '  @override',
    '  Widget build(BuildContext context) {',
    '    return \$0',
    '  }',
    '}',
  ], {'dart'}, 'StatelessWidget'),
  Snippet('stful', [
    'class \${1:MyScreen} extends ConsumerStatefulWidget {',
    '  const \${1:MyScreen}({super.key});',
    '',
    '  @override',
    '  ConsumerState<\${1:MyScreen}> createState() => _\${1:MyScreenState}();',
    '}',
    '',
    'class _\${1:MyScreenState} extends ConsumerState<\${1:MyScreen}> {',
    '  @override',
    '  Widget build(BuildContext context) {',
    '    return \$0',
    '  }',
    '}',
  ], {'dart'}, 'ConsumerStatefulWidget'),
  Snippet('prov', [
    'final \${1:thing}Provider = Provider<\${2:Object}>((ref) {',
    '  return \$0;',
    '});',
  ], {'dart'}, 'Riverpod Provider'),
  Snippet('notifier', [
    'class \${1:Thing}Notifier extends Notifier<\${2:State}> {',
    '  @override',
    '  \${2:State} build() => \$0;',
    '}',
  ], {'dart'}, 'Riverpod Notifier'),
  Snippet('for', [
    'for (var \${1:i} = 0; \${1:i} < \${2:n}; \${1:i}++) {',
    '  \$0',
    '}'
  ], {'dart', 'javascript', 'typescript', 'c', 'cpp', 'java', 'go'}, 'loop for'),
  Snippet('if', ['if (\${1:cond}) {', '  \$0', '}'],
      {'dart', 'javascript', 'typescript', 'c', 'cpp', 'java', 'go'}, 'if'),
  Snippet('try', ['try {', '  \$0', '} catch (e) {', '  rethrow;', '}'],
      {'dart', 'javascript', 'typescript'}, 'try/catch'),
  Snippet('log', ["print('\${1:msg}\$0');"], {'dart'}, 'print'),
  Snippet('console', ['console.log(\${1:value});'],
      {'javascript', 'typescript'}, 'console.log'),
  Snippet('fn', ['\${1:name}(\${2:args}) {', '  \$0', '}'], {'rust'}, 'fn'),
  Snippet('def', ['def \${1:name}(\${2:args}):', '    \$0'], {'python'}, 'def'),
  Snippet('html5', [
    '<!DOCTYPE html>',
    '<html lang="\${1:en}">',
    '<head>',
    '  <meta charset="utf-8">',
    '  <title>\${2:Title}</title>',
    '</head>',
    '<body>',
    '  \$0',
    '</body>',
    '</html>',
  ], {'html'}, 'boilerplate HTML5'),
];

List<Snippet> snippetsFor(String language) =>
    [for (final s in kSnippets) if (s.langs.contains(language)) s];

String snippetWordPrefix(String line, int column) {
  final upto = column <= line.length ? line.substring(0, column) : line;
  final m = RegExp(r'([A-Za-z0-9_-]+)$').firstMatch(upto);
  return m?.group(1) ?? '';
}

// ---------------------------------------------------------------- emmet

/// Emmet-like opcional: `div.card>ul>li*3` → HTML real. Suporta child `>`,
/// classes `.x`, id `#x`, repetição `*N`. Retorna null se inválido.
String? emmetExpand(String abbreviation) {
  final parts = abbreviation.split('>');
  if (parts.isEmpty || parts.length > 6) return null;

  String? render(String spec, {String inner = ''}) {
    var rep = 1;
    final star = RegExp(r'\*(\d+)$').firstMatch(spec);
    if (star != null) {
      rep = int.parse(star.group(1)!);
      spec = spec.substring(0, star.start);
    }
    final tm = RegExp(r'^([a-zA-Z][\w-]*)').firstMatch(spec);
    if (tm == null && !(spec.startsWith('.') || spec.startsWith('#'))) {
      return null;
    }
    final tag = tm?.group(1) ?? 'div';
    final rest = tm != null ? spec.substring(tm.group(1)!.length) : spec;
    final idm = RegExp(r'#([\w-]+)').firstMatch(rest);
    final classes = [
      for (final m in RegExp(r'\.([\w-]+)').allMatches(rest)) m.group(1)!,
    ];
    final attrs = StringBuffer();
    if (idm != null) attrs.write(' id="${idm.group(1)}"');
    if (classes.isNotEmpty) attrs.write(' class="${classes.join(' ')}"');
    final single = '<$tag${attrs.toString()}>$inner</$tag>';
    return List.generate(rep, (_) => single).join('\n');
  }

  String? acc;
  for (var i = parts.length - 1; i >= 0; i--) {
    final r = render(parts[i], inner: acc ?? '');
    if (r == null) return null;
    acc = r;
  }
  return acc;
}
