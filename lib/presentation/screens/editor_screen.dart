/// Editor real (spec §EDITOR) — multi-tab com preview/pinned, split H/V,
/// grupo por workspace, restore de sessão REAL, edição avançada, diff com
/// hunks, IA inline (ghost text + chat), virtualização por viewport,
/// diagnostics REAIS via `dart analyze` (nunca simulados).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/tool_executor.dart';
import '../../domain/tools/tool_contract.dart';
import '../../infrastructure/editor/editor_tools.dart' show resolveDart;
import '../state/app_state.dart';
import '../state/editor_state.dart';
import '../theme/vt_theme.dart';
import 'editor_ai.dart';
import 'editor_diff.dart';
import 'language_features.dart';

// ============================================================================
// Estado de UI do editor (por arquivo: bookmarks, local history, problemas)
// ============================================================================

class _Problem {
  const _Problem({
    required this.line,
    required this.column,
    required this.severity,
    required this.message,
  });
  final int line; // 1-based (wire dart analyze)
  final int column;
  final String severity; // error|warning|info
  final String message;
}

class _HistoryEntry {
  _HistoryEntry(this.at, this.text);
  final DateTime at;
  final String text;
}

class FileExtrasState {
  const FileExtrasState(
      {this.bookmarks = const {},
      this.history = const {},
      this.problems = const {},
      this.problemErrors = const {}});

  /// path -> linhas marcadas (0-based)
  final Map<String, Set<int>> bookmarks;

  /// path -> snapshots locais (timeline/local history, máx. 25)
  final Map<String, List<_HistoryEntry>> history;

  /// path -> diagnostics REAIS (dart analyze)
  final Map<String, List<_Problem>> problems;

  /// path -> último erro ao rodar analyze (honesto: missing_binary etc.)
  final Map<String, String> problemErrors;

  FileExtrasState copyWith({
    Map<String, Set<int>>? bookmarks,
    Map<String, List<_HistoryEntry>>? history,
    Map<String, List<_Problem>>? problems,
    Map<String, String>? problemErrors,
  }) =>
      FileExtrasState(
        bookmarks: bookmarks ?? this.bookmarks,
        history: history ?? this.history,
        problems: problems ?? this.problems,
        problemErrors: problemErrors ?? this.problemErrors,
      );
}

class FileExtrasNotifier extends Notifier<FileExtrasState> {
  static const maxHistory = 25;
  Timer? _snapshotTimer;

  @override
  FileExtrasState build() {
    ref.onDispose(() => _snapshotTimer?.cancel());
    return const FileExtrasState();
  }

  void toggleBookmark(String path, int line) {
    final set = {...state.bookmarks[path] ?? const <int>{}};
    if (!set.remove(line)) set.add(line);
    state = state.copyWith(bookmarks: {...state.bookmarks, path: set});
  }

  /// Snapshot periódico do buffer ativo (local history real, melhor esforço).
  void scheduleSnapshot(String path, String Function() readText) {
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer(const Duration(seconds: 30), () {
      final list = [...state.history[path] ?? const <_HistoryEntry>[]];
      if (list.isEmpty || list.last.text != readText()) {
        list.add(_HistoryEntry(DateTime.now(), readText()));
        while (list.length > maxHistory) {
          list.removeAt(0);
        }
        state = state.copyWith(history: {...state.history, path: list});
      }
    });
  }

  List<_HistoryEntry> historyOf(String path) =>
      state.history[path] ?? const [];

  void restoreHistory(String path, _HistoryEntry e) {
    final list = [...state.history[path] ?? const <_HistoryEntry>[]];
    list.add(_HistoryEntry(DateTime.now(), e.text));
    while (list.length > maxHistory) {
      list.removeAt(0);
    }
    state = state.copyWith(history: {...state.history, path: list});
  }

  void setProblems(String path, List<_Problem> items, {String? error}) {
    final errs = {...state.problemErrors};
    if (error == null) {
      errs.remove(path);
    } else {
      errs[path] = error;
    }
    state = state.copyWith(
        problems: {...state.problems, path: items}, problemErrors: errs);
  }
}

final fileExtrasProvider =
    NotifierProvider<FileExtrasNotifier, FileExtrasState>(
        FileExtrasNotifier.new);

/// Diagnostics REAIS: roda `editor.diagnostics` (dart analyze machine) pela
/// ToolExecutor — audit/trilha incluídos. Sem binário: guarda a falha tipada
/// para a UI exibir a instrução; NUNCA fabrica itens.
Future<void> runRealDiagnostics(
  WidgetRef ref,
  String path,
  FileExtrasNotifier extras,
) async {
  try {
    final app = ref.read(vtAppProvider);
    final executor = ToolExecutor(
      registry: app.registry,
      context: ToolContext(
        workspaceRoots: app.workspaceRoots,
        sandbox: app.sandbox,
        settings: app.settings,
      ),
      db: app.db,
      approvalGateway: app.chat.approvalGateway,
    );
    final outcome = await executor.run(
      callId: 'editor-${DateTime.now().microsecondsSinceEpoch}',
      toolId: 'editor.diagnostics',
      argsJson: jsonEncode({'path': path}),
    );
    if (outcome.kind == ToolCallOutcomeKind.succeeded) {
      final decoded =
          jsonDecode(outcome.resultText) as Map<String, Object?>;
      final items = [
        for (final raw in (decoded['items'] as List? ?? const []))
          _Problem(
            line: (raw['line'] as num).toInt(),
            column: (raw['column'] as num).toInt(),
            severity: raw['severity'] as String,
            message: raw['message'] as String,
          ),
      ];
      extras.setProblems(path, items);
    } else {
      extras.setProblems(path, const [],
          error: outcome.failure?.message ??
              'diagnóstico indisponível (${outcome.toolId})');
    }
  } catch (e) {
    extras.setProblems(path, const [], error: '$e');
  }
}

// ============================================================================
// Tela principal
// ============================================================================

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key});

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _editorFocus = FocusNode();

  GhostCompletionController? _ghost;
  InlineChatController? _inlineChat;

  bool _wordWrap = true;
  double _fontScale = 14.0;
  bool _outlineOpen = false;
  bool _treeOpen = true;
  bool _diffOpen = false;
  bool _aiPanelOpen = false;
  bool _ignoreWsInDiff = false;
  int _diffCaret = 0;
  final Set<int> _stagedHunks = {};
  InlineChatAction _chatAction = InlineChatAction.explain;
  bool _emmetEnabled = true;

  List<String> _bufferLines = const [''];
  int _caretLine = 0;
  int _caretCol = 0;

  /// Multi-cursor/coluna: seleções extras além da primária do TextField.
  final List<TextSelection> _extraCursors = [];

  /// Posições de navegação back/forward (path, line, col).
  final List<(String, int, int)> _navStack = [];
  int _navIndex = -1;
  bool _suppressNavPush = false;

  String? get _activePath => ref.read(editorProvider).activePath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initControllers());
  }

  void _initControllers() {
    final app = ref.read(vtAppProvider);
    _ghost = GhostCompletionController(
      providerFor: () {
        final model = ref.read(selectedModelProvider);
        if (model == null) return null;
        for (final p in app.chat.providers.all) {
          if (p.models.any((m) => m.id == model)) return p;
        }
        return null;
      },
      settings: app.settings,
      modelId: () => ref.read(selectedModelProvider) ?? '',
    );
    _inlineChat = InlineChatController(
      providerFor: () {
        final model = ref.read(selectedModelProvider);
        if (model == null) return null;
        for (final p in app.chat.providers.all) {
          if (p.models.any((m) => m.id == model)) return p;
        }
        return null;
      },
      modelId: () => ref.read(selectedModelProvider) ?? '',
      workspaceHint: () => _activePath ?? '(sem arquivo)',
    );
    _ghost?.addListener(_onGhostChanged);
    _inlineChat?.addListener(() {
      if (mounted) setState(() {});
    });
  }

  void _onGhostChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ghost?.dispose();
    _inlineChat?.dispose();
    _textController.dispose();
    _scrollController.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- sincronizar

  void _syncFromSession(EditorSession s) {
    final tab = s.activeTab;
    final preview = s.previewAt(s.activePath);
    final wantText = tab?.text ?? '';
    if (_textController.text != wantText &&
        (tab != null || preview != null)) {
      _textController.value = TextEditingValue(
        text: wantText,
        selection: tab == null
            ? const TextSelection.collapsed(offset: 0)
            : _selectionFromLineCol(wantText, tab.caretLine, tab.caretColumn),
      );
      _rebuildBuffer(wantText);
    }
  }

  TextSelection _selectionFromLineCol(String text, int line, int col) {
    final lines = text.split('\n');
    var offset = 0;
    for (var i = 0; i < line && i < lines.length; i++) {
      offset += lines[i].length + 1;
    }
    final c = offset + col.clamp(0, line < lines.length ? lines[line].length : 0);
    return TextSelection.collapsed(offset: c);
  }

  void _rebuildBuffer(String text) {
    _bufferLines = text.isEmpty ? const [''] : text.split('\n');
  }

  void _pushNav(String path, int line, int col) {
    if (_suppressNavPush) return;
    while (_navIndex < _navStack.length - 1) {
      _navStack.removeLast();
    }
    if (_navStack.isNotEmpty &&
        _navStack.last == (path, line, col)) {
      return;
    }
    _navStack.add((path, line, col));
    if (_navStack.length > 100) _navStack.removeAt(0);
    _navIndex = _navStack.length - 1;
  }

  void _goToLocation(String path, int line, int col) {
    _suppressNavPush = true;
    final notifier = ref.read(editorProvider.notifier);
    notifier.activate(path);
    final tab = ref.read(editorProvider).tabAt(path);
    if (tab != null) {
      tab.caretLine = line;
      tab.caretColumn = col;
      _applyCaret(line, col);
    } else {
      unawaited(notifier.openFile(path));
    }
    _suppressNavPush = false;
    setState(() {});
  }

  void _applyCaret(int line, int col) {
    final sel = _selectionFromLineCol(_textController.text, line, col);
    _textController.selection = sel;
    _caretLine = line;
    _caretCol = col;
    _scrollToLine(line);
  }

  void _scrollToLine(int line) {
    if (!_scrollController.hasClients) return;
    final vh = _scrollController.position.viewportDimension;
    final target = (line * _lineHeight).clamp(0.0,
        (_bufferLines.length * _lineHeight - vh / 2).clamp(0.0, double.infinity));
    _scrollController.animateTo(target.toDouble(),
        duration: const Duration(milliseconds: 90), curve: Curves.easeOut);
  }

  double get _lineHeight => (_fontScale + 8.0);

  void _back() {
    if (_navIndex <= 0) return;
    _navIndex--;
    final (p, l, c) = _navStack[_navIndex];
    _goToLocation(p, l, c);
  }

  void _forward() {
    if (_navIndex >= _navStack.length - 1) return;
    _navIndex++;
    final (p, l, c) = _navStack[_navIndex];
    _goToLocation(p, l, c);
  }

  // ----------------------------------------------------------------- edição

  void _onTextChanged(String text) {
    final path = _activePath;
    if (path == null) return;
    final session = ref.read(editorProvider);
    final tab = session.tabAt(path);
    if (tab == null) return;
    _rebuildBuffer(text);
    final caret = _textController.selection.base;
    _caretLine = text.substring(0, caret.clamp(0, text.length)).split('\n').length - 1;
    _caretCol = caret -
        (text.lastIndexOf('\n', caret == 0 ? 0 : caret - 1) + 1);
    ref.read(editorProvider.notifier).updateText(path, text);
    ref.read(fileExtrasProvider.notifier).scheduleSnapshot(path, () => text);
    _ghost?.schedule(
      prefix: text.substring(0, caret.clamp(0, text.length)),
      suffix: text.substring(caret.clamp(0, text.length)),
    );
  }

  /// Transformação genérica: aplica f sobre o texto atual como UMA edição
  /// (undo do TextField mantém um histórico profundo próprio).
  void _applyEdit(String Function(String text, TextSelection sel) f) {
    final before = _textController.value;
    final after = f(before.text, before.selection);
    if (after == before.text) return;
    final caret = before.selection.baseOffset.clamp(0, after.length);
    _textController.value = TextEditingValue(
      text: after,
      selection: TextSelection.collapsed(offset: caret),
    );
    _onTextChanged(after);
  }

  void _indent(bool outdent) {
    _applyEdit((text, sel) {
      final lines = text.split('\n');
      final start = _firstLine(lines, sel.start);
      final end = _lastLine(lines, sel.end, text);
      for (var i = start; i <= end && i < lines.length; i++) {
        if (outdent) {
          lines[i] = lines[i].replaceFirst(RegExp(r'^( {1,2}|\t)'), '');
        } else {
          lines[i] = '  ${lines[i]}';
        }
      }
      return lines.join('\n');
    });
  }

  int _firstLine(List<String> lines, int offset) {
    var acc = 0;
    for (var i = 0; i < lines.length; i++) {
      acc += lines[i].length + 1;
      if (offset < acc) return i;
    }
    return lines.length - 1;
  }

  int _lastLine(List<String> lines, int offset, String text) {
    var acc = 0;
    for (var i = 0; i < lines.length; i++) {
      acc += lines[i].length + 1;
      if (offset < acc) return i;
    }
    return lines.length - 1;
  }

  void _toggleComment() {
    _applyEdit((text, sel) {
      final lines = text.split('\n');
      final start = _firstLine(lines, sel.start);
      final end = _lastLine(lines, sel.end, text);
      final lang = languageForPath(_activePath ?? '');
      final single = switch (lang) {
        'python' || 'ruby' || 'shell' || 'yaml' || 'toml' => '# ',
        'sql' => '-- ',
        'html' || 'xml' => null,
        _ => '// ',
      };
      final allCommented = () {
        if (single == null) return false;
        for (var i = start; i <= end && i < lines.length; i++) {
          if (lines[i].trim().isEmpty) continue;
          if (!lines[i].trimLeft().startsWith(single.trimRight())) return false;
        }
        return true;
      }();
      for (var i = start; i <= end && i < lines.length; i++) {
        final l = lines[i];
        if (l.trim().isEmpty) continue;
        if (single == null) {
          // block comment simples por linha em html/xml
          if (allCommented) {
            lines[i] = l
                .replaceFirst('&lt;!--', '')
                .replaceFirst('--&gt;', '')
                .replaceFirst('<!--', '')
                .replaceFirst('-->', '');
          } else {
            final ind = l.length - l.trimLeft().length;
            lines[i] = '${l.substring(0, ind)}<!-- ${l.substring(ind)} -->';
          }
          continue;
        }
        final ind = l.length - l.trimLeft().length;
        if (allCommented) {
          final t = l.trimLeft();
          lines[i] = t.startsWith(single.trimRight())
              ? l.substring(0, ind) + t.substring(single.trimRight().length)
              : l;
        } else {
          lines[i] = l.substring(0, ind) + single + l.substring(ind);
        }
      }
      return lines.join('\n');
    });
  }

  void _moveLine(bool up) {
    _applyEdit((text, sel) {
      final lines = text.split('\n');
      final i = _firstLine(lines, sel.start);
      final j = up ? i - 1 : i + 1;
      if (j < 0 || j >= lines.length) return text;
      final tmp = lines[i];
      lines[i] = lines[j];
      lines[j] = tmp;
      return lines.join('\n');
    });
  }

  void _duplicateLine() {
    _applyEdit((text, sel) {
      final lines = text.split('\n');
      final i = _firstLine(lines, sel.start);
      lines.insert(i, lines[i]);
      return lines.join('\n');
    });
  }

  void _deleteLine() {
    _applyEdit((text, sel) {
      final lines = text.split('\n');
      final i = _firstLine(lines, sel.start);
      if (lines.length == 1) return '';
      lines.removeAt(i);
      return lines.join('\n');
    });
  }

  void _trimTrailing() {
    _applyEdit((text, _) => text
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'[ \t]+$'), ''))
        .join('\n'));
  }

  void _convertEol(String mode) {
    final path = _activePath;
    if (path == null) return;
    final tab = ref.read(editorProvider).tabAt(path);
    if (tab == null) return;
    setState(() => tab.eol = mode);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Ao salvar: EOL → $mode (buffer interno permanece LF).'),
        duration: const Duration(seconds: 2)));
  }

  void _addExtraCursor() {
    final sel = _textController.selection;
    setState(() {
      _extraCursors.add(sel);
      if (_extraCursors.length > 16) _extraCursors.removeAt(0);
    });
  }

  void _clearExtraCursors() => setState(_extraCursors.clear);

  /// Aplica a mesma transformação em todas as seleções (multi-cursor real
  /// limitado: substitui palavra sob cada cursor pela área de seleção primária).
  void _applyToAllCursors(String replacement) {
    for (final c in [..._extraCursors].reversed) {
      if (!c.isValid || c.isCollapsed) continue;
      final before = _textController.value;
      final text = before.text.replaceRange(c.start, c.end, replacement);
      _textController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: c.start + replacement.length));
      _onTextChanged(text);
    }
  }

  // ---------------------------------------------------------------- snippets

  void _insertSnippet(Snippet s) {
    final (body, cursorOffset) = Snippet.expand(s.body);
    final sel = _textController.selection;
    final before = _textController.value;
    // remove o prefixo digitado (ex.: "main") antes de inserir
    final lineStart = before.text.lastIndexOf('\n', sel.start == 0 ? 0 : sel.start - 1) + 1;
    final wordPrefix = snippetWordPrefix(before.text.substring(lineStart), sel.start - lineStart);
    final cutFrom = wordPrefix == s.prefix ? sel.start - wordPrefix.length : sel.start;
    final text = before.text.replaceRange(
        cutFrom.clamp(0, before.text.length), sel.end, body);
    final caret = cursorOffset == null
        ? cutFrom + body.length
        : cutFrom + cursorOffset;
    _textController.value = TextEditingValue(
        text: text, selection: TextSelection.collapsed(offset: caret));
    _onTextChanged(text);
  }

  void _tryEmmet() {
    if (!_emmetEnabled) return;
    final sel = _textController.selection;
    if (!sel.isCollapsed) return;
    final text = _textController.text;
    final lineStart = text.lastIndexOf('\n', sel.start == 0 ? 0 : sel.start - 1) + 1;
    final upto = text.substring(lineStart, sel.start);
    final m = RegExp(r'([.#]?[a-zA-Z][\w.#>]*\*?\d*)$').firstMatch(upto);
    if (m == null) return;
    final expanded = emmetExpand(m.group(1)!);
    if (expanded == null) return;
    final newText =
        text.replaceRange(lineStart + m.start, sel.start, expanded);
    _textController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: lineStart + m.start + expanded.length));
    _onTextChanged(newText);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Emmet: ${m.group(1)} → expandido'),
        duration: const Duration(milliseconds: 1200)));
  }

  // ------------------------------------------------------------------ ghost

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final logical = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final path = _activePath;
    final notifier = ref.read(editorProvider.notifier);

    // Aceitar/rejeitar ghost text (só quando há sugestão pendente).
    if (_ghost != null && _ghost!.state.hasSuggestions) {
      if (logical == LogicalKeyboardKey.tab) {
        final ins = _ghost!.accept();
        if (ins != null) {
          final sel = _textController.selection;
          final text = _textController.text
              .replaceRange(sel.start, sel.end, ins);
          _textController.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: sel.start + ins.length));
          _onTextChanged(text);
        }
        return KeyEventResult.handled;
      }
      if (logical == LogicalKeyboardKey.escape) {
        _ghost!.reject();
        return KeyEventResult.handled;
      }
      if (logical == LogicalKeyboardKey.arrowDown && alt) {
        _ghost!.cycle();
        return KeyEventResult.handled;
      }
    }

    if (ctrl && logical == LogicalKeyboardKey.keyS) {
      if (shift) {
        unawaited(notifier.saveAll());
      } else if (path != null) {
        unawaited(notifier.save(path));
      }
      return KeyEventResult.handled;
    }
    if (ctrl && logical == LogicalKeyboardKey.keyP) {
      _showGoToFile();
      return KeyEventResult.handled;
    }
    if (ctrl && logical == LogicalKeyboardKey.keyG) {
      if (shift) {
        _showGoToSymbol();
      } else {
        _showGoToLine();
      }
      return KeyEventResult.handled;
    }
    if (ctrl && alt && logical == LogicalKeyboardKey.keyRightBracket) {
      _splitNext(true);
      return KeyEventResult.handled;
    }
    if (ctrl && alt && logical == LogicalKeyboardKey.keyLeftBracket) {
      _splitNext(false);
      return KeyEventResult.handled;
    }
    if (alt && logical == LogicalKeyboardKey.arrowUp) {
      _moveLine(true);
      return KeyEventResult.handled;
    }
    if (alt && logical == LogicalKeyboardKey.arrowDown) {
      _moveLine(false);
      return KeyEventResult.handled;
    }
    if (shift && alt && logical == LogicalKeyboardKey.keyK) {
      _deleteLine();
      return KeyEventResult.handled;
    }
    if (shift && alt && logical == LogicalKeyboardKey.keyL) {
      _duplicateLine();
      return KeyEventResult.handled;
    }
    if (ctrl && logical == LogicalKeyboardKey.slash) {
      _toggleComment();
      return KeyEventResult.handled;
    }
    if (ctrl && shift && logical == LogicalKeyboardKey.keyL) {
      unawaited(_formatWithDart());
      return KeyEventResult.handled;
    }
    if (ctrl && logical == LogicalKeyboardKey.keyD && !shift) {
      _addExtraCursor();
      return KeyEventResult.handled;
    }
    if (ctrl && logical == LogicalKeyboardKey.keyM) {
      _clearExtraCursors();
      return KeyEventResult.handled;
    }
    if (ctrl && logical == LogicalKeyboardKey.keyF8) {
      _jumpProblem(forward: !shift);
      return KeyEventResult.handled;
    }
    if (alt && logical == LogicalKeyboardKey.arrowLeft) {
      _back();
      return KeyEventResult.handled;
    }
    if (alt && logical == LogicalKeyboardKey.arrowRight) {
      _forward();
      return KeyEventResult.handled;
    }
    if (ctrl && shift && logical == LogicalKeyboardKey.keyB) {
      if (path != null) {
        ref.read(fileExtrasProvider.notifier).toggleBookmark(path, _caretLine);
      }
      return KeyEventResult.handled;
    }
    if (logical == LogicalKeyboardKey.enter) {
      _tryEmmet();
    }
    return KeyEventResult.ignored;
  }

  void _splitNext(bool next) {
    final tabs = ref.read(editorProvider).groupTabs;
    if (tabs.length < 2) return;
    final idx = tabs.indexWhere((t) => t.path == _activePath);
    final target = next
        ? tabs[(idx + 1) % tabs.length]
        : tabs[(idx - 1 + tabs.length) % tabs.length];
    _goToLocation(target.path, 0, 0);
  }

  Future<void> _formatWithDart() async {
    final path = _activePath;
    if (path == null) return;
    final app = ref.read(vtAppProvider);
    final ctx = ToolContext(
      workspaceRoots: app.workspaceRoots,
      sandbox: app.sandbox,
      settings: app.settings,
    );
    final dart = await resolveDart(ctx);
    if (dart == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'dart não encontrado no PATH — instale o Dart SDK ou defina '
                'dart.binaryPath em Settings (formatação não simulada).')));
      }
      return;
    }
    final executor = ToolExecutor(
      registry: app.registry,
      context: ctx,
      db: app.db,
      approvalGateway: app.chat.approvalGateway,
    );
    final outcome = await executor.run(
      callId: 'fmt-${DateTime.now().microsecondsSinceEpoch}',
      toolId: 'editor.format',
      argsJson: jsonEncode({'path': path}),
    );
    if (outcome.kind == ToolCallOutcomeKind.succeeded && mounted) {
      _applyEdit((_, __) => outcome.resultText);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Formatado com dart format (edição undoável).'),
          duration: Duration(seconds: 2)));
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('dart format: ${outcome.failure?.message ?? 'falhou'}')));
    }
  }

  void _jumpProblem({required bool forward}) {
    final path = _activePath;
    if (path == null) return;
    final problems =
        ref.read(fileExtrasProvider).problems[path] ?? const [];
    if (problems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Sem diagnostics reais carregados — use ⟳ Analyze (dart analyze).'),
          duration: Duration(seconds: 2)));
      return;
    }
    final sorted = [...problems]..sort((a, b) => a.line.compareTo(b.line));
    var target = forward
        ? sorted.firstWhere((p) => p.line > _caretLine + 1,
            orElse: () => sorted.first)
        : sorted.reversed.firstWhere((p) => p.line < _caretLine + 1,
            orElse: () => sorted.last);
    _goToLocation(path, target.line - 1, target.column - 1);
  }

  // -------------------------------------------------------------- dialogs

  Future<void> _showGoToLine() async {
    final controller = TextEditingController(
        text: '${_caretLine + 1}:${_caretCol + 1}');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ir para linha:coluna'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
          decoration: const InputDecoration(hintText: 'ex.: 42:7'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        ],
      ),
    );
    if (result == null) return;
    final parts = result.split(':');
    final line = (int.tryParse(parts.first) ?? 1) - 1;
    final col = parts.length > 1 ? (int.tryParse(parts[1]) ?? 1) - 1 : 0;
    final path = _activePath;
    if (path != null) _goToLocation(path, line, col);
  }

  Future<void> _showGoToSymbol() async {
    final path = _activePath;
    if (path == null) return;
    final outline = outlineOf(ref.read(editorProvider).activeTab?.text ?? '',
        languageForPath(path));
    final selected = await showDialog<OutlineEntry>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Ir para símbolo (outline léxico — sem LSP ativo)'),
        children: [
          SizedBox(
            width: 420,
            height: 380,
            child: ListView(
              children: [
                for (final e in outline)
                  ListTile(
                    dense: true,
                    leading: Icon(_outlineIcon(e.kind), size: 15),
                    title: Text('${e.name}  ·  linha ${e.line + 1}'),
                    onTap: () => Navigator.pop(ctx, e),
                  ),
                if (outline.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Nenhuma declaração reconhecida neste arquivo.')),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected != null) _goToLocation(path, selected.line, 0);
  }

  Future<void> _showGoToFile() async {
    final ws = ref.read(focusedWorkspacePathProvider);
    if (ws == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nenhum workspace aberto (abra em Workspaces).')));
      return;
    }
    final controller = TextEditingController();
    var results = <String>[];
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) {
          void search(String q) {
            if (q.trim().isEmpty) {
              results = const [];
            } else {
              results = fuzzyFindFiles(ws, q, limit: 60);
            }
            setInner(() {});
          }

          return Dialog(
            child: SizedBox(
              width: 520,
              height: 420,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      onChanged: search,
                      onSubmitted: (v) {
                        if (results.isNotEmpty) Navigator.pop(ctx, results.first);
                      },
                      decoration: const InputDecoration(
                          hintText: 'Ir para arquivo… (fuzzy)'),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final r in results)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.description_outlined, size: 15),
                            title: Text(r, overflow: TextOverflow.ellipsis),
                            onTap: () => Navigator.pop(ctx, r),
                          ),
                        if (controller.text.trim().isNotEmpty &&
                            results.isEmpty)
                          const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('Nenhum match (busca lexical no workspace).')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (picked != null) {
      await ref.read(editorProvider.notifier).openFile(picked);
      _goToLocation(ref.read(editorProvider).activePath ?? picked, 0, 0);
    }
  }

  Future<void> _showHistory() async {
    final path = _activePath;
    if (path == null) return;
    final entries = ref.read(fileExtrasProvider).historyOf(path);
    final picked = await showDialog<_HistoryEntry>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Local history — ${path.split('/').last}'),
        children: [
          SizedBox(
            height: 360,
            width: 460,
            child: entries.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(
                        'Ainda sem snapshots (capturados a cada 30s de edição).'),
                  )
                : ListView(
                    children: [
                      for (var i = entries.length - 1; i >= 0; i--)
                        ListTile(
                          dense: true,
                          title: Text(
                              '${entries[i].at.toIso8601String().substring(0, 19)}  ·  '
                              '${entries[i].text.length} chars'),
                          onTap: () => Navigator.pop(ctx, entries[i]),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
    if (picked != null) {
      _applyEdit((_, __) => picked.text);
      ref.read(fileExtrasProvider.notifier).restoreHistory(path, picked);
    }
  }

  // ------------------------------------------------------------ file finder

  /// Busca fuzzy lexical REAL no workspace (Directory.list limitado).
  static List<String> fuzzyFindFiles(String root, String query,
      {int limit = 60}) {
    final q = query.toLowerCase();
    final out = <(int, String)>[];
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];
    final stack = <Directory>[dir];
    var scanned = 0;
    const skipDirs = {'.git', 'node_modules', '.dart_tool', 'build', 'target', '.idea'};
    while (stack.isNotEmpty && scanned < 20000) {
      final d = stack.removeLast();
      try {
        for (final e in d.listSync(followLinks: false)) {
          scanned++;
          if (scanned > 20000) break;
          if (e is Directory) {
            final name = e.uri.pathSegments.last.replaceAll('/', '');
            if (!skipDirs.contains(name)) stack.add(e);
            continue;
          }
          if (e is! File) continue;
          final rel = e.path.substring(root.length).replaceFirst(RegExp(r'^[/\\]'), '');
          final score = _fuzzyScore(rel.toLowerCase(), q);
          if (score > 0) out.add((score, e.path));
        }
      } on FileSystemException {
        continue;
      }
    }
    out.sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final (_, p) in out.take(limit)) p];
  }

  static int _fuzzyScore(String hay, String needle) {
    if (needle.isEmpty) return 0;
    if (hay.contains(needle)) return 1000 - hay.indexOf(needle);
    var hi = 0, score = 0, streak = 0;
    for (final ch in needle.split('')) {
      final idx = hay.indexOf(ch, hi);
      if (idx < 0) return 0;
      streak = idx == hi ? streak + 1 : 1;
      score += streak * 2;
      hi = idx + 1;
    }
    return score;
  }

  IconData _outlineIcon(String kind) => switch (kind) {
        'class' => Icons.category_outlined,
        'function' => Icons.functions,
        'field' => Icons.tag,
        'heading' => Icons.title,
        'section' => Icons.segment,
        _ => Icons.symbol_outlined,
      };

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(editorProvider);
    final extras = ref.watch(fileExtrasProvider);
    ref.listen<EditorSession>(editorProvider, (_, next) => _syncFromSession(next));
    _syncFromSession(session);

    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final tab = session.activeTab;
    final preview = session.previewAt(session.activePath);
    final error = session.errors[session.activePath];
    final groupTabs = session.groupTabs;

    return CallbackShortcut(
      onKeyPressed: (_) {},
      child: Focus(
        focusNode: _editorFocus,
        autofocus: false,
        onKeyEvent: _handleKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar(session, groupTabs),
            if (error != null)
              Material(
                color: vt.riskCritical.withOpacity(0.15),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, size: 15, color: vt.riskCritical),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(error.message,
                              style: theme.textTheme.bodySmall,
                              overflow: TextOverflow.ellipsis)),
                      IconButton(
                          iconSize: 15,
                          tooltip: 'Dispensar',
                          icon: const Icon(Icons.close),
                          onPressed: () =>
                              ref.read(editorProvider.notifier).clearError(error.message.hashCode.toString())),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Row(
                children: [
                  if (_treeOpen) _fileTree(session),
                  VerticalDivider(width: 1, color: theme.dividerColor),
                  Expanded(
                    child: Column(
                      children: [
                        _tabBar(session, groupTabs),
                        Expanded(
                          child: session.split == SplitMode.none || tab == null
                              ? _editorArea(session, tab, preview, extras)
                              : Flex(
                                  direction: session.split == SplitMode.horizontal
                                      ? Axis.horizontal
                                      : Axis.vertical,
                                  children: [
                                    Expanded(child: _editorArea(session, tab, preview, extras)),
                                    const Divider(thickness: 1),
                                    Expanded(
                                        child: _secondaryPane(session, groupTabs, extras)),
                                  ],
                                ),
                        ),
                        if (_diffOpen && tab != null) _diffPanel(tab),
                        if (_aiPanelOpen) _aiPanel(),
                      ],
                    ),
                  ),
                  if (_outlineOpen) _outlinePanel(tab, extras),
                ],
              ),
            ),
            _statusBar(theme, vt, session, tab, extras),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- toolbar

  Widget _toolbar(EditorSession session, List<EditorTab> groupTabs) {
    final theme = Theme.of(context);
    final hasTab = session.activeTab != null || session.activePath != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _toolBtn(Icons.folder_outlined, 'Árvore de arquivos', () => setState(() => _treeOpen = !_treeOpen)),
          _toolBtn(Icons.psychology_outlined, 'Outline', () => setState(() => _outlineOpen = !_outlineOpen)),
          const SizedBox(width: 6),
          _toolBtn(Icons.arrow_back, 'Voltar (Alt+←)', _back),
          _toolBtn(Icons.arrow_forward, 'Avançar (Alt+→)', _forward),
          const SizedBox(width: 6),
          _toolBtn(Icons.looks_one_outlined, 'Ir para linha (Ctrl+G)', _showGoToLine),
          _toolBtn(Icons.symbol_outlined, 'Ir para símbolo (Ctrl+Shift+G)', _showGoToSymbol),
          _toolBtn(Icons.search_outlined, 'Ir para arquivo (Ctrl+P)', _showGoToFile),
          _toolBtn(Icons.history, 'Local history', _showHistory),
          _toolBtn(Icons.bookmark_border, 'Bookmark (Ctrl+Shift+B)', () {
            final p = _activePath;
            if (p != null) {
              ref.read(fileExtrasProvider.notifier).toggleBookmark(p, _caretLine);
            }
          }),
          _toolBtn(Icons.bug_report_outlined, 'Próximo problema (Ctrl+F8)', () => _jumpProblem(forward: true)),
          _toolBtn(Icons.bug_check_outlined, 'Problema anterior (Ctrl+Shift+F8)', () => _jumpProblem(forward: false)),
          const SizedBox(width: 6),
          _toolBtn(Icons.compare_arrows, 'Diff buffer × disco', () => setState(() => _diffOpen = !_diffOpen)),
          _toolBtn(Icons.smart_toy_outlined, 'IA inline', () => setState(() => _aiPanelOpen = !_aiPanelOpen)),
          _toolBtn(Icons.checklist_rounded, 'Analyze (dart analyze)', () {
            final p = _activePath;
            if (p != null) {
              runRealDiagnostics(ref, p, ref.read(fileExtrasProvider.notifier));
            }
          }),
          const SizedBox(width: 6),
          _toolBtn(Icons.view_column_outlined, 'Split horizontal',
              () => ref.read(editorProvider.notifier).setSplit(
                  session.split == SplitMode.horizontal ? SplitMode.none : SplitMode.horizontal)),
          _toolBtn(Icons.view_agenda_outlined, 'Split vertical',
              () => ref.read(editorProvider.notifier).setSplit(
                  session.split == SplitMode.vertical ? SplitMode.none : SplitMode.vertical)),
          const SizedBox(width: 6),
          _toolBtn(Icons.wrap_text, 'Word wrap', () => setState(() => _wordWrap = !_wordWrap)),
          _toolBtn(Icons.text_increase, 'Zoom +', () => setState(() => _fontScale = (_fontScale + 1).clamp(10, 28))),
          _toolBtn(Icons.text_decrease, 'Zoom −', () => setState(() => _fontScale = (_fontScale - 1).clamp(10, 28))),
          _toolBtn(Icons.cleaning_services_outlined, 'Trim trailing whitespace', _trimTrailing),
          PopupMenuButton<String>(
            tooltip: 'EOL / Encoding',
            icon: const Icon(Icons.subtitles_outlined, size: 18),
            onSelected: (v) {
              if (v.startsWith('eol:')) {
                _convertEol(v.substring(4));
              } else if (v.startsWith('enc:')) {
                final p = _activePath;
                final t = ref.read(editorProvider).tabAt(p);
                if (t != null) setState(() => t.encoding = v.substring(4));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'eol:lf', child: Text('EOL: LF (\\n)')),
              PopupMenuItem(value: 'eol:crlf', child: Text('EOL: CRLF (\\r\\n)')),
              PopupMenuItem(value: 'eol:auto', child: Text('EOL: auto (detectado)')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'enc:utf-8', child: Text('Encoding: UTF-8 (na reabertura)')),
              PopupMenuItem(value: 'enc:utf16le', child: Text('Encoding: UTF-16LE')),
              PopupMenuItem(value: 'enc:latin1', child: Text('Encoding: Latin-1')),
            ],
          ),
          if (hasTab) ...[
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: () {
                final p = _activePath;
                if (p != null) {
                  unawaited(ref.read(editorProvider.notifier).save(p));
                }
              },
              icon: const Icon(Icons.save, size: 16),
              label: const Text('Salvar'),
            ),
            TextButton.icon(
              onPressed: () =>
                  unawaited(ref.read(editorProvider.notifier).saveAll()),
              icon: const Icon(Icons.save_all, size: 16),
              label: const Text('Salvar tudo'),
            ),
          ],
          const Spacer(),
          if (session.groupPath != null)
            Chip(
              avatar: const Icon(Icons.folder, size: 14),
              label: Text(session.groupPath!.split('/').last,
                  style: const TextStyle(fontSize: 11)),
              deleteIcon: const Icon(Icons.close, size: 14),
              onDeleted: () =>
                  ref.read(editorProvider.notifier).setGroup(null),
            ),
        ],
      ),
    );
  }

  Widget _toolBtn(IconData icon, String tooltip, VoidCallback onTap) =>
      IconButton(icon: Icon(icon, size: 17), tooltip: tooltip, onPressed: onTap);

  // ---------------------------------------------------------------- tab bar

  Widget _tabBar(EditorSession session, List<EditorTab> groupTabs) {
    final theme = Theme.of(context);
    const maxVisible = 8;
    final visible = groupTabs.length <= maxVisible
        ? groupTabs
        : groupTabs.sublist(0, maxVisible);
    final overflow = groupTabs.length - visible.length;
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final t in visible)
                  _tabChip(t, active: t.path == session.activePath,
                      dirtyCount: groupTabs.where((x) => x.isDirty).length),
                if (overflow > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: PopupMenuButton<String>(
                      tooltip: '+$overflow tabs paginadas',
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        alignment: Alignment.center,
                        child: Text('+ $overflow',
                            style: theme.textTheme.labelMedium),
                      ),
                      itemBuilder: (_) => [
                        for (final t in groupTabs.sublist(maxVisible))
                          PopupMenuItem(
                            value: t.path,
                            child: Row(
                              children: [
                                if (t.isDirty)
                                  Container(
                                      width: 7,
                                      height: 7,
                                      margin: const EdgeInsets.only(right: 6),
                                      decoration: const BoxDecoration(
                                          color: Colors.orange,
                                          shape: BoxShape.circle)),
                                Expanded(
                                    child: Text(t.name,
                                        overflow: TextOverflow.ellipsis)),
                              ],
                            ),
                          ),
                      ],
                      onSelected: (v) =>
                          ref.read(editorProvider.notifier).activate(v),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
              icon: const Icon(Icons.add, size: 16),
              tooltip: 'Nova aba (arquivo existente ou novo)',
              onPressed: _newFile),
        ],
      ),
    );
  }

  Widget _tabChip(EditorTab t, {required bool active, required int dirtyCount}) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    return GestureDetector(
      onDoubleTap: () => ref.read(editorProvider.notifier).togglePin(t.path),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        decoration: BoxDecoration(
          color: active ? vt.panel : Colors.transparent,
          border: Border(
            top: BorderSide(color: active ? vt.accent : Colors.transparent, width: 2),
            right: BorderSide(color: theme.dividerColor, width: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 8),
            if (t.pinned)
              Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.push_pin, size: 12, color: theme.hintColor)),
            Flexible(
              child: Text(
                t.preview ? '${t.name} (preview)' : t.name,
                style: theme.textTheme.labelMedium?.copyWith(
                    fontStyle: t.preview ? FontStyle.italic : null,
                    fontWeight: active ? FontWeight.w600 : null),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            if (t.isDirty)
              Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                      color: Colors.orangeAccent, shape: BoxShape.circle)),
            InkWell(
              onTap: () {
                if (t.isDirty) {
                  _confirmCloseDirty(t);
                } else {
                  ref.read(editorProvider.notifier).closeTab(t.path);
                }
              },
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCloseDirty(EditorTab t) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Fechar "${t.name}" com alterações?'),
        content: const Text('O buffer tem mudanças ainda não salvas em disco.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          OutlinedButton(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              child: const Text('Descartar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Salvar e fechar')),
        ],
      ),
    );
    if (choice == null) return;
    final notifier = ref.read(editorProvider.notifier);
    if (choice == 'save') {
      final ok = await notifier.save(t.path);
      if (!ok) return;
    }
    notifier.closeTab(t.path);
  }

  Future<void> _newFile() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Novo arquivo (no workspace)'),
        content: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(ctx, v),
            decoration: const InputDecoration(hintText: 'ex.: lib/foo.dart')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final ws = ref.read(focusedWorkspacePathProvider);
    if (ws == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Abra um workspace primeiro (Workspaces → adicionar).')));
      return;
    }
    final full = '$ws/${name.trim()}';
    try {
      final f = File(full);
      await f.parent.create(recursive: true);
      if (!await f.exists()) await f.writeAsString('');
    } on FileSystemException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Falha criando "$full": ${e.message}')));
      }
      return;
    }
    await ref.read(editorProvider.notifier).openFile(full, forcePin: true);
  }

  // -------------------------------------------------------------- file tree

  Widget _fileTree(EditorSession session) {
    final theme = Theme.of(context);
    final ws = ref.watch(focusedWorkspacePathProvider);
    return SizedBox(
      width: 230,
      child: ColoredBox(
        color: theme.colorScheme.surfaceContainerLow,
        child: ws == null
            ? const Center(
                child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Sem workspace.\nAbra em Workspaces.',
                        textAlign: TextAlign.center)))
            : _TreeList(root: ws),
      ),
    );
  }

  Widget _secondaryPane(EditorSession session, List<EditorTab> groupTabs,
      FileExtrasState extras) {
    final others = groupTabs.where((t) => t.path != session.activePath).toList();
    if (others.isEmpty) {
      return const Center(child: Text('Segunda pane: abra outra aba (Ctrl+Alt+←/→ troca).'));
    }
    final second = others.first;
    return _editorArea(session, second, null, extras, secondary: true);
  }

  // ------------------------------------------------------------ editor area

  Widget _editorArea(EditorSession session, EditorTab? tab,
      EditorPreview? preview, FileExtrasState extras,
      {bool secondary = false}) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);

    if (preview != null) {
      return _previewView(preview, theme, vt);
    }
    if (tab == null) {
      return Center(
          child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_note, size: 42, color: theme.hintColor),
          const SizedBox(height: 8),
          Text('Nenhum arquivo aberto.\nUse a árvore à esquerda ou Ctrl+P.',
              textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
        ],
      ));
    }

    final lang = languageForPath(tab.path);
    final problems = extras.problems[tab.path] ?? const [];
    final bookmarks = extras.bookmarks[tab.path] ?? const <int>{};
    final isBigWarning = tab.text.length > kEditSizeWarning;

    // Virtualização por viewport: constrói apenas as linhas visíveis ± overscan.
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: Container(
        color: vt.codeBackground,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isBigWarning && !secondary)
              Material(
                color: vt.riskMedium.withOpacity(0.15),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Text(
                      '⚠ Arquivo grande (> ${kEditSizeWarning ~/ 1024} KiB): edição possível, mas acima de '
                      '${kEditSizeHardLimit ~/ (1024 * 1024)} MiB vira somente-leitura.',
                      style: theme.textTheme.bodySmall),
                ),
              ),
            if (tab.text.length > 2 * 1024 * 1024)
              Expanded(
                child: _virtualReadOnly(tab, lang, theme, vt),
              )
            else
              Expanded(
                child: ListenableBuilder(
                  listenable: _ghost!,
                  builder: (context, _) => Stack(
                    children: [
                      _codeField(tab, lang, problems, bookmarks, theme, vt),
                      Positioned(
                        left: 58,
                        bottom: 6,
                        child: _ghostBadge(),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _codeField(EditorTab tab, String lang, List<_Problem> problems,
      Set<int> bookmarks, ThemeData theme, VtColors vt) {
    final gutterWidth = 52.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Gutter com números + marcadores reais (problemas/bookmarks).
        SizedBox(
          width: gutterWidth,
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _textController,
            builder: (context, value, _) {
              final lines = value.text.split('\n');
              final first = _scrollController.hasClients
                  ? (_scrollController.offset / _lineHeight).floor()
                  : 0;
              final visibleCount =
                  ((MediaQuery.sizeOf(context).height / _lineHeight) + 6)
                      .ceil();
              final from = (first - 2).clamp(0, lines.length);
              final to = (first + visibleCount).clamp(0, lines.length);
              return ListView.builder(
                controller: _mirrorScroll(from, to, lines.length),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: to - from,
                itemBuilder: (context, i) {
                  final ln = from + i;
                  final hasProblem = problems.any((p) => p.line - 1 == ln);
                  final bookmarked = bookmarks.contains(ln);
                  return Container(
                    height: _lineHeight,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 6),
                    color: ln == _caretLine ? vt.accent.withOpacity(0.08) : null,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (bookmarked)
                          Icon(Icons.bookmark, size: 10, color: vt.accent),
                        if (hasProblem)
                          Icon(Icons.circle,
                              size: 8,
                              color: problems
                                          .firstWhere((p) => p.line - 1 == ln)
                                          .severity ==
                                      'error'
                                  ? vt.riskCritical
                                  : vt.riskMedium),
                        Text('${ln + 1}',
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: (_fontScale - 2).clamp(9, 14),
                                color: theme.hintColor)),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, cons) {
            return TextField(
              controller: _textController,
              focusNode: _editorFocus,
              maxLines: null,
              minLines: 1,
              expands: true,
              keyboardType: TextInputType.none,
              scrollController: _scrollController,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: _fontScale,
                  height: (_lineHeight / _fontScale)),
              decoration: const InputDecoration(
                  isDense: true, border: InputBorder.none,
                  contentPadding: EdgeInsets.fromLTRB(8, 6, 8, 40)),
              onChanged: _onTextChanged,
              onTap: () => _updateCaretFromController(),
              onTapOutside: (_) => _updateCaretFromController(),
              readOnly: false,
            );
          }),
        ),
      ],
    );
  }

  ScrollController _mirrorScroll(int from, int to, int total) =>
      _scrollController;

  void _updateCaretFromController() {
    final sel = _textController.selection;
    if (!sel.isValid) return;
    final text = _textController.text;
    final offset = sel.baseOffset.clamp(0, text.length);
    final line = text.substring(0, offset).split('\n').length - 1;
    final col = offset - (text.lastIndexOf('\n', offset == 0 ? 0 : offset - 1) + 1);
    if (line != _caretLine || col != _caretCol) {
      final path = _activePath;
      if (path != null) {
        _pushNav(path, line, col);
        final tab = ref.read(editorProvider).tabAt(path);
        if (tab != null) {
          ref.read(editorProvider.notifier).updateCaret(path, line, col,
              _scrollController.hasClients ? _scrollController.offset : 0);
        }
      }
      setState(() {
        _caretLine = line;
        _caretCol = col;
      });
    }
  }

  Widget _ghostBadge() {
    final g = _ghost?.state ?? const GhostState();
    if (g.busy) {
      return const Padding(
          padding: EdgeInsets.all(6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 6),
            Text('IA…', style: TextStyle(fontSize: 11)),
          ]));
    }
    if (g.error != null) {
      return Padding(
          padding: const EdgeInsets.all(6),
          child: Text('IA inline: ${g.error}',
              style: TextStyle(
                  fontSize: 11, color: VtTheme.of(context).riskMedium)));
    }
    if (g.current == null) return const SizedBox.shrink();
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(4),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(g.current!.split('\n').first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).hintColor)),
            Text(
                '${g.source ?? ''} · Tab aceita · Esc rejeita · Alt+↓ alterna '
                '(${g.index + 1}/${g.suggestions.length})',
                style: TextStyle(
                    fontSize: 10, color: Theme.of(context).hintColor)),
          ],
        ),
      ),
    );
  }

  /// Acima de ~2 MiB no buffer: view somente-leitura virtualizada por
  /// viewport (lazy load real das linhas), nunca TextField completo.
  Widget _virtualReadOnly(
      EditorTab tab, String lang, ThemeData theme, VtColors vt) {
    final lines = _bufferLines;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _textController,
      builder: (context, _, __) => ListView.builder(
        controller: _scrollController,
        itemCount: lines.length,
        cacheExtent: _lineHeight * 40,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              SizedBox(
                  width: 44,
                  child: Text('${i + 1}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 11, color: theme.hintColor))),
              const SizedBox(width: 8),
              Expanded(
                child: Text(lines[i],
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: (_fontScale - 1).clamp(9, 24),
                        color: theme.textTheme.bodySmall?.color)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _previewView(EditorPreview p, ThemeData theme, VtColors vt) {
    final ext = p.path.toLowerCase().split('.').last;
    final isImage = const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico'}
        .contains(ext);
    return Container(
      color: vt.codeBackground,
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                p.isBinary
                    ? 'Arquivo binário — preview HEX (read-only). ${p.byteLength} bytes'
                        '${p.truncated ? ' · dump truncado' : ''}'
                    : 'Arquivo grande/binário — read-only. ${p.byteLength} bytes',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 10),
            if (isImage)
              FutureBuilder<Uint8List>(
                future: File(p.path).readAsBytes(),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Text('Falha lendo imagem: ${snap.error}',
                        style: TextStyle(color: vt.riskCritical));
                  }
                  if (!snap.hasData) {
                    return const SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator());
                  }
                  return Image.memory(
                    snap.data!,
                    fit: BoxFit.contain,
                    errorBuilder: (context, e, st) => Text(
                        'Decoder de imagem falhou ($e) — exibindo hex abaixo.',
                        style: theme.textTheme.bodySmall),
                  );
                },
              ),
            const SizedBox(height: 10),
            SelectableText(
              p.hexDump.isEmpty ? '(sem dump disponível)' : p.hexDump,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ outline panel

  Widget _outlinePanel(EditorTab? tab, FileExtrasState extras) {
    final theme = Theme.of(context);
    final outline = tab == null
        ? const <OutlineEntry>[]
        : outlineOf(tab.text, languageForPath(tab.path));
    final problems = tab == null ? const <_Problem>[] : (extras.problems[tab.path] ?? const []);
    final errInfo = tab == null ? null : extras.problemErrors[tab.path];
    return SizedBox(
      width: 250,
      child: ColoredBox(
        color: theme.colorScheme.surfaceContainerLow,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 4),
              child: Row(
                children: [
                  Text('Outline', style: theme.textTheme.labelLarge),
                  const Spacer(),
                  IconButton(
                      icon: const Icon(Icons.close, size: 15),
                      onPressed: () => setState(() => _outlineOpen = false)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  if (errInfo != null)
                    Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text('Diagnósticos: $errInfo',
                            style: TextStyle(
                                fontSize: 11,
                                color: VtTheme.of(context).riskMedium))),
                  if (problems.isNotEmpty) ...[
                    Padding(
                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                        child: Text('Problemas (dart analyze)',
                            style: theme.textTheme.labelSmall)),
                    for (final p in problems.take(60))
                      ListTile(
                        dense: true,
                        leading: Icon(
                            p.severity == 'error'
                                ? Icons.error_outline
                                : p.severity == 'warning'
                                    ? Icons.warning_amber
                                    : Icons.info_outline,
                            size: 14,
                            color: p.severity == 'error'
                                ? VtTheme.of(context).riskCritical
                                : VtTheme.of(context).riskMedium),
                        title: Text('${p.line}:${p.column} ${p.message}',
                            maxLines: 2,
                            style: const TextStyle(fontSize: 11)),
                        onTap: () =>
                            _goToLocation(tab.path, p.line - 1, p.column - 1),
                      ),
                    const Divider(),
                  ],
                  Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                      child: Text('Símbolos (léxico — sem LSP)',
                          style: theme.textTheme.labelSmall)),
                  for (final e in outline)
                    InkWell(
                      onTap: () => _goToLocation(tab?.path ?? '', e.line, 0),
                      child: Padding(
                        padding: EdgeInsets.only(left: 8.0 + e.indent, right: 8),
                        child: Row(
                          children: [
                            Icon(_outlineIcon(e.kind),
                                size: 13, color: theme.hintColor),
                            const SizedBox(width: 6),
                            Expanded(
                                child: Text(e.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12))),
                          ],
                        ),
                      ),
                    ),
                  if (outline.isEmpty && tab != null)
                    const Padding(
                        padding: EdgeInsets.all(10),
                        child: Text('Nenhuma declaração reconhecida.',
                            style: TextStyle(fontSize: 11))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- diff panel

  Widget _diffPanel(EditorTab tab) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final result = diffLines(tab.originalText, tab.text,
        ignoreWhitespace: _ignoreWsInDiff);
    final changed = result.changedHunks;
    return Container(
      height: 260,
      decoration:
          BoxDecoration(border: Border(top: BorderSide(color: theme.dividerColor))),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              children: [
                Text(
                    'Diff buffer×disco: +${result.additions} −${result.deletions} · ${changed.length} hunks',
                    style: theme.textTheme.labelMedium),
                const SizedBox(width: 8),
                Checkbox(
                    visualDensity: VisualDensity.compact,
                    value: _ignoreWsInDiff,
                    onChanged: (v) => setState(() => _ignoreWsInDiff = v ?? false)),
                const Text('ignorar whitespace', style: TextStyle(fontSize: 11)),
                const Spacer(),
                IconButton(
                    icon: const Icon(Icons.navigate_before, size: 16),
                    tooltip: 'Hunk anterior',
                    onPressed: () {
                      if (changed.isEmpty) return;
                      setState(() => _diffCaret = (_diffCaret - 1) % changed.length);
                    }),
                IconButton(
                    icon: const Icon(Icons.navigate_next, size: 16),
                    tooltip: 'Próximo hunk',
                    onPressed: () {
                      if (changed.isEmpty) return;
                      setState(() => _diffCaret = (_diffCaret + 1) % changed.length);
                    }),
                TextButton(
                    onPressed: () {
                      final reverted = revertHunk(
                          tab.originalText, tab.text, _diffCaret,
                          ignoreWhitespace: _ignoreWsInDiff);
                      _applyEdit((_, __) => reverted);
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Hunk revertido no buffer.'),
                          duration: Duration(seconds: 2)));
                    },
                    child: const Text('Revert hunk')),
                TextButton(
                    onPressed: () {
                      setState(() => _stagedHunks.add(_diffCaret));
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(
                              'Hunk ${_diffCaret + 1} marcado (use "Aplicar staged" para compor).'),
                          duration: const Duration(seconds: 2)));
                    },
                    child: const Text('Stage hunk')),
                TextButton(
                    onPressed: () {
                      final applied = applySelectedHunks(
                          tab.originalText, tab.text, _stagedHunks,
                          ignoreWhitespace: _ignoreWsInDiff);
                      _applyEdit((_, __) => applied);
                      setState(_stagedHunks.clear);
                    },
                    child: const Text('Aplicar staged')),
                IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _diffOpen = false)),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: result.lines.length,
              itemBuilder: (context, i) {
                final l = result.lines[i];
                final color = switch (l.op) {
                  DiffOp.insert => vt.diffAddition.withOpacity(0.25),
                  DiffOp.delete => vt.diffDeletion.withOpacity(0.25),
                  DiffOp.equal => null,
                };
                // word-diff nos inserts pareados com deletes vizinhos
                List<(String, bool)>? words;
                if (l.op == DiffOp.insert && i > 0 && result.lines[i - 1].op == DiffOp.delete) {
                  words = wordDiff(result.lines[i - 1].text, l.text);
                }
                return Container(
                  color: color,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                          width: 46,
                          child: Text(l.oldLine?.toString() ?? '',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  fontSize: 10, color: theme.hintColor))),
                      SizedBox(
                          width: 46,
                          child: Text(l.newLine?.toString() ?? '',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  fontSize: 10, color: theme.hintColor))),
                      SizedBox(
                          width: 14,
                          child: Text(
                              l.op == DiffOp.insert
                                  ? '+'
                                  : l.op == DiffOp.delete
                                      ? '-'
                                      : ' ',
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 12))),
                      Expanded(
                        child: words == null
                            ? SelectableText(l.text,
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 12))
                            : SelectableText.rich(TextSpan(
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 12),
                                children: [
                                  for (final (w, hot) in words)
                                    TextSpan(
                                        text: w,
                                        style: hot
                                            ? TextStyle(
                                                background:
                                                    vt.diffAddition.withOpacity(0.5))
                                            : null),
                                ],
                              ))),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- ai panel

  Widget _aiPanel() {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final chat = _inlineChat!;
    final state = chat.state;
    final code = InlineChatController.extractCodeBlock(state.response);
    return Container(
      height: 220,
      decoration:
          BoxDecoration(border: Border(top: BorderSide(color: theme.dividerColor))),
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: ListView(
              children: [
                for (final a in InlineChatAction.values)
                  RadioMenuButton<InlineChatAction>(
                    value: a,
                    groupValue: _chatAction,
                    onChanged: (v) => setState(() => _chatAction = v!),
                    child: Text(a.label, style: const TextStyle(fontSize: 12)),
                  ),
                const SizedBox(height: 6),
                FilledButton(
                    onPressed: () {
                      final sel = _textController.selection;
                      final text = _textController.text;
                      final selection = sel.isValid && !sel.isCollapsed
                          ? text.substring(sel.start, sel.end)
                          : '';
                      chat.run(_chatAction, selection,
                          wholeFileContext: text);
                    },
                    child: const Text('Rodar na seleção')),
                const SizedBox(height: 6),
                if (state.running)
                  OutlinedButton(
                      onPressed: chat.stop, child: const Text('Parar')),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isDense: true,
                    value: ref.read(selectedModelProvider),
                    hint: const Text('modelo…', style: TextStyle(fontSize: 11)),
                    items: [
                      for (final p in ref.read(vtAppProvider).chat.providers.all)
                        for (final m in p.models)
                          DropdownMenuItem(
                              value: m.id,
                              child: Text('${m.displayName}',
                                  style: const TextStyle(fontSize: 11))),
                    ],
                    onChanged: (v) =>
                        ref.read(selectedModelProvider.notifier).state = v,
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(),
          Expanded(
            child: state.error != null
                ? SelectableText('Erro: ${state.error}',
                    style: TextStyle(color: vt.riskCritical))
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (state.source != null)
                          Text('fonte: ${state.source}',
                              style: theme.textTheme.labelSmall),
                        SelectableText(
                          state.response.isEmpty
                              ? 'Selecione código → escolha uma ação → Rodar. '
                                  'Resposta real do provider (sem simulação).'
                              : state.response,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
          ),
          if (code != null && !state.running)
            SizedBox(
              width: 110,
              child: Column(
                children: [
                  const SizedBox(height: 20),
                  FilledButton.tonal(
                      onPressed: () {
                        final sel = _textController.selection;
                        final text = _textController.text;
                        final newT = text.replaceRange(
                            sel.isValid ? sel.start : text.length,
                            sel.isValid ? sel.end : text.length,
                            code);
                        _textController.value = TextEditingValue(
                            text: newT,
                            selection: TextSelection.collapsed(
                                offset: (sel.isValid ? sel.start : text.length) + code.length));
                        _onTextChanged(newT);
                        chat.reset();
                      },
                      child: const Text('Aplicar código',
                          style: TextStyle(fontSize: 11))),
                  const SizedBox(height: 6),
                  TextButton(
                      onPressed: chat.reset, child: const Text('Fechar')),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- status bar

  Widget _statusBar(ThemeData theme, VtColors vt, EditorSession session,
      EditorTab? tab, FileExtrasState extras) {
    final lang = tab == null ? '—' : languageForPath(tab.path);
    final sym = tab == null
        ? null
        : symbolNameAt(outlineOf(tab.text, lang), _caretLine);
    final problems = tab == null
        ? const <_Problem>[]
        : (extras.problems[tab.path] ?? const <_Problem>[]);
    final errCount = problems.where((p) => p.severity == 'error').length;
    final warnCount = problems.where((p) => p.severity == 'warning').length;
    final dirty = session.hasDirty;
    final model = ref.watch(selectedModelProvider);
    return Container(
      height: 24,
      color: vt.panel,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: DefaultTextStyle(
        style: theme.textTheme.labelSmall ?? const TextStyle(fontSize: 11),
        child: Row(
          children: [
            Text(tab == null ? 'sem arquivo' : tab.name),
            const SizedBox(width: 10),
            Text('$lang (sintaxe lexical${sym != null ? ' · $sym' : ''})'),
            const SizedBox(width: 10),
            Text('Ln ${_caretLine + 1}, Col ${_caretCol + 1}'),
            const SizedBox(width: 10),
            Text('Linhas ${_bufferLines.length}'),
            const SizedBox(width: 10),
            if (tab != null) Text('EOL ${tab.eol.toUpperCase()} · ${tab.encoding}'),
            const SizedBox(width: 10),
            if (_extraCursors.isNotEmpty)
              Text('cursors: ${_extraCursors.length + 1}'),
            const Spacer(),
            if (problems.isNotEmpty ||
                (tab != null && extras.problemErrors[tab.path] != null))
              Row(children: [
                Icon(Icons.error_outline, size: 12, color: vt.riskCritical),
                const SizedBox(width: 2),
                Text('$errCount'),
                const SizedBox(width: 8),
                Icon(Icons.warning_amber, size: 12, color: vt.riskMedium),
                const SizedBox(width: 2),
                Text('$warnCount'),
                const SizedBox(width: 10),
              ])
            else if (tab != null)
              const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text('sem analyze rodado')),
            if (model != null) Text(model),
            const SizedBox(width: 10),
            Icon(dirty ? Icons.circle : Icons.check_circle,
                size: 11, color: dirty ? Colors.orangeAccent : vt.riskLow),
            const SizedBox(width: 4),
            Text(dirty ? 'não salvo' : 'salvo'),
          ],
        ),
      ),
    );
  }
}

/// Wrapper mínimo para atalhos globais da tela (mantém API estável caso o
/// projeto adicione keybindings centralizados depois).
class CallbackShortcut extends StatelessWidget {
  const CallbackShortcut({super.key, required this.onKeyPressed, required this.child});
  final VoidCallback onKeyPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

// ============================================================================
// Árvore de arquivos (lazy, dentro do sandbox)
// ============================================================================

class _TreeList extends ConsumerStatefulWidget {
  const _TreeList({required this.root});
  final String root;

  @override
  ConsumerState<_TreeList> createState() => _TreeListState();
}

class _TreeListState extends ConsumerState<_TreeList> {
  late Future<List<_TreeEntry>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _load(widget.root);
  }

  Future<List<_TreeEntry>> _load(String dir) async {
    final app = ref.read(vtAppProvider);
    final ctx = ToolContext(
        workspaceRoots: app.workspaceRoots,
        sandbox: app.sandbox,
        settings: app.settings);
    try {
      final resolved = await app.sandbox.resolveReadable(dir, ctx);
      final d = Directory(resolved);
      if (!d.existsSync()) return const [];
      final entities = d
          .listSync(followLinks: false)
          .whereType<FileSystemEntity>()
          .toList()
        ..sort((a, b) {
          final ad = a is Directory ? 0 : 1;
          final bd = b is Directory ? 0 : 1;
          if (ad != bd) return ad.compareTo(bd);
          return basenameOf(a.path).compareTo(basenameOf(b.path));
        });
      return [
        for (final e in entities.take(400))
          _TreeEntry(
            path: e.path,
            name: basenameOf(e.path),
            isDir: e is Directory,
          ),
      ];
    } on Object {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder(
      future: _entries,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(
              child: SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator()));
        }
        final items = snap.data!;
        if (items.isEmpty) {
          return Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Diretório vazio ou fora do sandbox.',
                  style: theme.textTheme.bodySmall));
        }
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            for (final e in items)
              _TreeNode(
                entry: e,
                depth: 0,
                onLoadChildren: _load,
                onOpenFile: (p) =>
                    ref.read(editorProvider.notifier).openFile(p),
                onPinFile: (p) =>
                    ref.read(editorProvider.notifier).openFile(p, forcePin: true),
              ),
          ],
        );
      },
    );
  }
}

class _TreeEntry {
  const _TreeEntry({required this.path, required this.name, required this.isDir});
  final String path;
  final String name;
  final bool isDir;
}

class _TreeNode extends StatefulWidget {
  const _TreeNode(
      {required this.entry,
      required this.depth,
      required this.onLoadChildren,
      required this.onOpenFile,
      required this.onPinFile});

  final _TreeEntry entry;
  final int depth;
  final Future<List<_TreeEntry>> Function(String dir) onLoadChildren;
  final void Function(String path) onOpenFile;
  final void Function(String path) onPinFile;

  @override
  State<_TreeNode> createState() => _TreeNodeState();
}

class _TreeNodeState extends State<_TreeNode> {
  bool _expanded = false;
  List<_TreeEntry>? _children;
  bool _loading = false;

  Future<void> _toggle() async {
    if (!widget.entry.isDir) return;
    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    if (_children == null) {
      setState(() => _loading = true);
      _children = await widget.onLoadChildren(widget.entry.path);
      if (!mounted) return;
      setState(() => _loading = false);
    }
    setState(() => _expanded = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hidden = widget.entry.name.startsWith('.') ||
        widget.entry.name == 'node_modules' ||
        widget.entry.name == 'build' ||
        widget.entry.name == '.dart_tool';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: widget.entry.isDir
              ? _toggle
              : () => widget.onOpenFile(widget.entry.path),
          onDoubleTap:
              widget.entry.isDir ? null : () => widget.onPinFile(widget.entry.path),
          child: Padding(
            padding: EdgeInsets.only(
                left: 6.0 + widget.depth * 12.0, top: 2, bottom: 2, right: 6),
            child: Row(
              children: [
                Icon(
                    widget.entry.isDir
                        ? (_expanded
                            ? Icons.expand_more
                            : Icons.chevron_right)
                        : Icons.description_outlined,
                    size: 14,
                    color: theme.hintColor),
                const SizedBox(width: 4),
                Expanded(
                    child: Text(
                  widget.entry.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: hidden ? theme.disabledColor : null,
                      fontWeight:
                          widget.entry.isDir ? FontWeight.w600 : null),
                )),
              ],
            ),
          ),
        ),
        if (_expanded)
          if (_loading)
            const Padding(
                padding: EdgeInsets.only(left: 28),
                child: SizedBox(
                    width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)))
          else
            for (final c in _children ?? const <_TreeEntry>[])
              _TreeNode(
                entry: c,
                depth: widget.depth + 1,
                onLoadChildren: widget.onLoadChildren,
                onOpenFile: widget.onOpenFile,
                onPinFile: widget.onPinFile,
              ),
      ],
    );
  }
}
