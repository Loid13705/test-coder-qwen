/// Estado do Editor real (spec §EDITOR): sessão multi-tab com restore REAL.
///
/// Persistência em `<dataDir>/editor/session.json` — tabs, split, grupo por
/// workspace e última posição de cursor sobrevivem a restart. Nada aqui é
/// decorativo: [EditorTab.isDirty] vem de comparação com o disco; salvar passa
/// pelo sandbox (resolveWritable) e grava de verdade.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import 'app_state.dart';

enum SplitMode { none, horizontal, vertical }

class EditorTab {
  EditorTab({
    required this.path,
    required this.workspaceRoot,
    required this.originalText,
    required this.text,
    this.pinned = false,
    this.preview = false,
    this.caretLine = 0,
    this.caretColumn = 0,
    this.scrollOffset = 0,
    this.encoding = 'utf-8',
    this.eol = 'auto',
  });

  /// Caminho absoluto já resolvido pelo sandbox.
  final String path;

  /// Grupo de tabs: raiz do workspace ao qual esta tab pertence.
  final String workspaceRoot;

  /// Conteúdo do disco na última leitura/salvação — base do dirty e do diff.
  String originalText;

  /// Conteúdo corrente no buffer (canonical LF).
  String text;

  bool pinned;

  /// Preview tab (clique único no arquivo): reutilizada até ser fixada.
  bool preview;

  int caretLine;
  int caretColumn;
  double scrollOffset;

  /// Codificação declarada para REABRIR o arquivo (leitura real detecta BOM
  /// UTF-16; senão UTF-8 com fallback latin-1).
  String encoding;

  /// 'auto' mantém o EOL detectado do disco; lf/crlf convertem ao salvar.
  String eol;

  bool get isDirty => text != originalText;

  String get name => path.replaceAll('\\', '/').split('/').last;
}

/// Arquivo binário/demasiado grande: abre como preview (hex), NUNCA editável
/// — read-only forçado pela spec de large files.
class EditorPreview {
  const EditorPreview({
    required this.path,
    required this.byteLength,
    required this.hexDump,
    required this.isBinary,
    required this.truncated,
  });

  final String path;
  final int byteLength;
  final String hexDump;
  final bool isBinary;

  /// Conteúdo exibido foi cortado no limite configurado.
  final bool truncated;
}

class EditorError {
  const EditorError(this.message);
  final String message;
}

class EditorSession {
  const EditorSession({
    this.tabs = const [],
    this.activePath,
    this.split = SplitMode.none,
    this.groupPath,
    this.previews = const {},
    this.errors = const {},
    this.restored = false,
  });

  final List<EditorTab> tabs;
  final String? activePath;
  final SplitMode split;

  /// Grupo de tabs atualmente visível (workspace focado).
  final String? groupPath;

  /// path -> preview read-only (binários / arquivos gigantes).
  final Map<String, EditorPreview> previews;

  /// path -> último erro de I/O (abertura/salvação reais, não simulados).
  final Map<String, EditorError> errors;

  final bool restored;

  EditorTab? get activeTab => tabAt(activePath);

  EditorTab? tabAt(String? p) {
    if (p == null) return null;
    for (final t in tabs) {
      if (t.path == p) return t;
    }
    return null;
  }

  EditorPreview? previewAt(String? p) => p == null ? null : previews[p];

  List<EditorTab> get groupTabs => groupPath == null
      ? tabs
      : [for (final t in tabs) if (t.workspaceRoot == groupPath) t];

  bool get hasDirty => tabs.any((t) => t.isDirty);

  EditorSession copyWith({
    List<EditorTab>? tabs,
    String? activePath,
    SplitMode? split,
    String? groupPath,
    Map<String, EditorPreview>? previews,
    Map<String, EditorError>? errors,
    bool? restored,
  }) =>
      EditorSession(
        tabs: tabs ?? this.tabs,
        activePath: activePath ?? this.activePath,
        split: split ?? this.split,
        groupPath: groupPath ?? this.groupPath,
        previews: previews ?? this.previews,
        errors: errors ?? this.errors,
        restored: restored ?? this.restored,
      );
}

/// Limites de large files (bytes). Defaults seguros: preview hex até 2 MiB,
/// warning acima de 1 MiB, read-only obrigatório acima de 5 MiB.
const int kHexPreviewLimit = 2 * 1024 * 1024;
const int kEditSizeWarning = 1024 * 1024;
const int kEditSizeHardLimit = 5 * 1024 * 1024;

bool looksBinary(List<int> bytes) {
  final n = bytes.length < 8000 ? bytes.length : 8000;
  for (var i = 0; i < n; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

String hexDumpOf(List<int> bytes, {int maxLines = 64}) {
  final capped =
      bytes.length > maxLines * 16 ? bytes.sublist(0, maxLines * 16) : bytes;
  final sb = StringBuffer();
  for (var off = 0; off < capped.length; off += 16) {
    final chunk = capped.skip(off).take(16).toList();
    sb.write('${off.toRadixString(16).padLeft(8, '0')}  ');
    for (var i = 0; i < 16; i++) {
      sb.write(i < chunk.length
          ? '${chunk[i].toRadixString(16).padLeft(2, '0')} '
          : '   ');
    }
    sb.write(' |');
    for (final c in chunk) {
      sb.write(c >= 32 && c < 127 ? String.fromCharCode(c) : '.');
    }
    sb.writeln('|');
  }
  return sb.toString();
}

void _atomicWriteString(String path, String content) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  final tmp = File('$path.tmp');
  tmp.writeAsStringSync(content, flush: true);
  tmp.renameSync(path);
}

T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final i in items) {
    if (test(i)) return i;
  }
  return null;
}

class EditorNotifier extends Notifier<EditorSession> {
  static const _sessionVersion = 1;

  late final File _sessionFile;
  Timer? _saveDebounce;
  Timer? _touchDebounce;

  @override
  EditorSession build() {
    final dataDir = ref.watch(vtAppProvider).dataDir;
    _sessionFile = File('$dataDir/editor/session.json');
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreOnce());
    ref.onDispose(() {
      _saveDebounce?.cancel();
      _touchDebounce?.cancel();
      _persistNow();
    });
    return const EditorSession();
  }

  ToolContext _ctx() {
    final app = ref.read(vtAppProvider);
    return ToolContext(
      workspaceRoots: app.workspaceRoots,
      sandbox: app.sandbox,
      settings: app.settings,
    );
  }

  // ---------------------------------------------------------------- restore

  void _restoreOnce() {
    if (state.restored) return;
    state = state.copyWith(restored: true);
    try {
      if (!_sessionFile.existsSync()) return;
      final raw = jsonDecode(_sessionFile.readAsStringSync());
      if (raw is! Map || raw['version'] != _sessionVersion) return;
      final group = raw['group'];
      final split = raw['split'];
      final tabsRaw = raw['tabs'];
      if (tabsRaw is! List) return;
      final restoredTabs = <EditorTab>[];
      for (final e in tabsRaw) {
        if (e is! Map) continue;
        final path = e['path'];
        final root = e['workspaceRoot'];
        if (path is! String || root is! String) continue;
        // Restore REAL: relê o conteúdo do disco (não persistimos texto —
        // evita divergir do arquivo e vazar segredos no session.json).
        try {
          final file = File(path);
          if (!file.existsSync()) continue;
          final bytes = file.readAsBytesSync();
          if (looksBinary(bytes)) continue;
          var text = _decode(bytes);
          final eol = e['eol'];
          if (eol == 'crlf') {
            text = text.replaceAll('\n', '\r\n');
          } else if (eol == 'lf') {
            text = text.replaceAll('\r\n', '\n');
          }
          restoredTabs.add(EditorTab(
            path: path,
            workspaceRoot: root,
            originalText: text,
            text: text,
            pinned: e['pinned'] == true,
            preview: e['preview'] == true,
            caretLine: (e['line'] as num?)?.toInt() ?? 0,
            caretColumn: (e['column'] as num?)?.toInt() ?? 0,
            scrollOffset: (e['scroll'] as num?)?.toDouble() ?? 0,
            encoding:
                e['encoding'] is String ? e['encoding'] as String : 'utf-8',
            eol: eol is String ? eol : 'auto',
          ));
        } catch (_) {
          continue; // arquivo sumiu/permissão: skip silencioso na restauração
        }
      }
      var next = state;
      if (group is String) next = next.copyWith(groupPath: group);
      if (split == 'horizontal' || split == 'vertical') {
        next = next.copyWith(split: SplitMode.values.byName(split));
      }
      if (restoredTabs.isEmpty) {
        state = next.copyWith(restored: true);
        return;
      }
      final active = restoredTabs.any((t) => t.path == raw['active'])
          ? raw['active'] as String
          : restoredTabs.first.path;
      state =
          next.copyWith(tabs: restoredTabs, activePath: active, restored: true);
    } catch (_) {
      // session.json corrompido: começa limpo, nunca crasha o editor.
    }
  }

  void _schedulePersist() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), _persistNow);
  }

  void _persistNow() {
    try {
      final payload = {
        'version': _sessionVersion,
        'group': state.groupPath,
        'split': state.split.name,
        'active': state.activePath,
        'tabs': [
          for (final t in state.tabs)
            {
              'path': t.path,
              'workspaceRoot': t.workspaceRoot,
              'pinned': t.pinned,
              'preview': t.preview,
              'line': t.caretLine,
              'column': t.caretColumn,
              'scroll': t.scrollOffset,
              'encoding': t.encoding,
              'eol': t.eol,
            },
        ],
      };
      _atomicWriteString(_sessionFile.path, jsonEncode(payload));
    } catch (_) {
      // Persistência de sessão é melhor esforço; falha não pode quebrar editar.
    }
  }

  // ------------------------------------------------------------- abrir/editar

  static String _decode(List<int> bytes) {
    // BOM UTF-16LE/BE detectado de verdade; senão UTF-8 com fallback latin-1.
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return utf16.decode(bytes.sublist(2));
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final units = bytes.sublist(2);
      final swapped = Uint8List(units.length);
      for (var i = 0; i + 1 < units.length; i += 2) {
        swapped[i] = units[i + 1];
        swapped[i + 1] = units[i];
      }
      return utf16.decode(swapped);
    }
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.runes.contains(0xFFFD)) {
      text = latin1.decode(bytes, allowInvalid: true);
    }
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return text;
  }

  Future<void> openFile(String rawPath, {bool forcePin = false}) async {
    final app = ref.read(vtAppProvider);
    final ctx = _ctx();
    String resolved;
    try {
      resolved = await app.sandbox.resolveReadable(rawPath, ctx);
    } on VtFailure catch (f) {
      state = state.copyWith(
          errors: {...state.errors, rawPath: EditorError(f.message)});
      return;
    }
    final existing = _firstWhereOrNull(state.tabs, (t) => t.path == resolved);
    if (existing != null) {
      state = state.copyWith(activePath: resolved);
      if (forcePin && (existing.preview || !existing.pinned)) {
        existing.preview = false;
        existing.pinned = true;
        state = state.copyWith(tabs: [...state.tabs]);
      }
      _schedulePersist();
      return;
    }
    try {
      final file = File(resolved);
      final stat = file.statSync();
      final head = await _readHead(resolved, kHexPreviewLimit);
      final bin = looksBinary(head);
      if (stat.size > kEditSizeHardLimit || bin || _extIsImage(resolved)) {
        // Read-only obrigatório para binários/arquivos gigantes (§LARGE FILES).
        state = state.copyWith(
          previews: {
            ...state.previews,
            resolved: EditorPreview(
              path: resolved,
              byteLength: stat.size,
              hexDump: bin || _extIsImage(resolved) ? hexDumpOf(head) : '',
              isBinary: bin,
              truncated: stat.size > kHexPreviewLimit,
            ),
          },
          activePath: resolved,
        );
        _schedulePersist();
        return;
      }
      final bytes =
          stat.size <= head.length ? head : await file.readAsBytes();
      var text = _decode(bytes);
      final detectedEol = text.contains('\r\n') ? 'crlf' : 'lf';
      text = text.replaceAll('\r\n', '\n'); // buffer canônico LF
      final tab = EditorTab(
        path: resolved,
        workspaceRoot: state.groupPath ??
            (app.workspaceRoots.isEmpty ? '' : app.workspaceRoots.first),
        originalText: text,
        text: text,
        pinned: forcePin,
        preview: !forcePin,
        eol: detectedEol,
      );
      var tabs = [...state.tabs];
      // Preview slot: uma única preview tab ativa — clique em outro arquivo
      // substitui apenas previews LIMPAS (suja permanece até pin/save/close).
      if (!forcePin) {
        tabs.removeWhere(
            (t) => t.preview && !t.isDirty && t.path != resolved);
      }
      tabs.add(tab);
      state = state.copyWith(
          tabs: tabs,
          activePath: resolved,
          previews: {...state.previews}..remove(resolved));
      _schedulePersist();
    } on VtFailure catch (f) {
      state = state.copyWith(
          errors: {...state.errors, resolved: EditorError(f.message)});
    } catch (e) {
      state = state.copyWith(
          errors: {...state.errors, resolved: EditorError('$e')});
    }
  }

  static Future<List<int>> _readHead(String path, int limit) async {
    final raf = await File(path).open();
    try {
      final n = await raf.length();
      final size = n < limit ? n : limit;
      final buf = Uint8List(size);
      await raf.readInto(buf, 0, size);
      return buf;
    } finally {
      await raf.close();
    }
  }

  static bool _extIsImage(String p) {
    final lower = p.toLowerCase();
    for (final ext in const [
      '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico', '.ttf',
      '.otf', '.woff', '.woff2', '.zip', '.gz', '.tar', '.pdf', '.exe',
      '.dll', '.so', '.dylib', '.db', '.sqlite', '.a', '.o', '.class',
      '.jar', '.war', '.mp3', '.mp4', '.mov', '.avi', '.wav', '.flac',
    ]) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  void activate(String path) {
    state = state.copyWith(activePath: path);
    _schedulePersist();
  }

  void closeTab(String path) {
    final tabs = state.tabs.where((t) => t.path != path).toList();
    final previews = {...state.previews}..remove(path);
    var active = state.activePath;
    if (active == path) {
      active = tabs.isEmpty ? null : tabs.last.path;
    }
    state = state.copyWith(tabs: tabs, activePath: active, previews: previews);
    _schedulePersist();
  }

  void closeAllInGroup(String root) {
    final tabs = state.tabs.where((t) => t.workspaceRoot != root).toList();
    state = state.copyWith(
        tabs: tabs, activePath: tabs.isEmpty ? null : tabs.last.path);
    _schedulePersist();
  }

  void togglePin(String path) {
    for (final t in state.tabs) {
      if (t.path == path) {
        t.pinned = !t.pinned;
        if (t.pinned) t.preview = false;
      }
    }
    state = state.copyWith(tabs: [...state.tabs]);
    _schedulePersist();
  }

  /// Chamado a cada edição — muta o buffer sem reconstruir o estado (senão o
  /// campo de texto perderia o foco a cada tecla); notify via touch agendado.
  void updateText(String path, String text) {
    final tab = _firstWhereOrNull(state.tabs, (t) => t.path == path);
    if (tab == null) return;
    tab.text = text;
    _touchDebounce?.cancel();
    _touchDebounce = Timer(const Duration(milliseconds: 250), () {
      state = state.copyWith(tabs: [...state.tabs]);
    });
  }

  void updateCaret(String path, int line, int column, double scroll) {
    final tab = _firstWhereOrNull(state.tabs, (t) => t.path == path);
    if (tab == null) return;
    tab.caretLine = line;
    tab.caretColumn = column;
    tab.scrollOffset = scroll;
    _schedulePersist();
  }

  /// Salva de verdade: sandbox resolve writable, aplica EOL/trim, grava.
  Future<bool> save(String path, {bool trimTrailing = false}) async {
    final tab = _firstWhereOrNull(state.tabs, (t) => t.path == path);
    if (tab == null) return false;
    final app = ref.read(vtAppProvider);
    try {
      final writable = await app.sandbox.resolveWritable(path, _ctx());
      var out = tab.text;
      if (trimTrailing) {
        out = out
            .split('\n')
            .map((l) => l.replaceFirst(RegExp(r'[ \t]+$'), ''))
            .join('\n');
      }
      if (tab.eol == 'crlf') out = out.replaceAll('\n', '\r\n');
      final file = File(writable);
      await file.parent.create(recursive: true);
      await file.writeAsString(out, flush: true);
      tab.originalText = tab.text;
      state = state.copyWith(tabs: [...state.tabs]);
      _schedulePersist();
      return true;
    } on VtFailure catch (f) {
      state = state.copyWith(
          errors: {...state.errors, path: EditorError(f.message)});
      return false;
    } catch (e) {
      state = state.copyWith(
          errors: {...state.errors, path: EditorError('$e')});
      return false;
    }
  }

  Future<bool> saveAll() async {
    var ok = true;
    for (final t in [...state.tabs]) {
      if (t.isDirty) ok = await save(t.path) && ok;
    }
    return ok;
  }

  void setSplit(SplitMode mode) {
    state = state.copyWith(split: mode);
    _schedulePersist();
  }

  void setGroup(String? root) {
    state = state.copyWith(groupPath: root);
    _schedulePersist();
  }

  void clearError(String path) {
    final errors = Map.of(state.errors)..remove(path);
    state = state.copyWith(errors: errors);
  }
}

final editorProvider =
    NotifierProvider<EditorNotifier, EditorSession>(EditorNotifier.new);
