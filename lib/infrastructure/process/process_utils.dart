/// Utilitários reais de processo/arquivo compartilhados pela infra.
library;

import 'dart:io';

/// Procura um binário no PATH real do sistema (com extensões do Windows).
Future<String?> findBinaryInPath(String name) async {
  final paths =
      (Platform.environment['PATH'] ?? '').split(Platform.pathSeparator);
  final exts = Platform.isWindows ? ['.exe', '.cmd', '.bat', ''] : [''];
  for (final dir in paths) {
    if (dir.isEmpty) continue;
    for (final ext in exts) {
      final cand = joinPath(dir, '$name$ext');
      try {
        if (await File(cand).exists()) return cand;
      } on FileSystemException {
        continue;
      }
    }
  }
  return null;
}

final _sep = Platform.isWindows ? r'\' : '/';

String get platformSeparator => _sep;

String joinPath(String a, String b) {
  if (a.isEmpty) return b;
  final needsSep = !a.endsWith('/') && !a.endsWith(r'\');
  return needsSep ? '$a$_sep$b' : '$a$b';
}

String relativePath(String full, String root) {
  final f = normalizeSlashes(full);
  final r = normalizeSlashes(root);
  if (f.startsWith('$r/')) return f.substring(r.length + 1);
  return f;
}

String basenameOf(String p) {
  final s = normalizeSlashes(p);
  final i = s.lastIndexOf('/');
  return i < 0 ? s : s.substring(i + 1);
}

String dirname(String p) {
  final s = normalizeSlashes(p);
  final i = s.lastIndexOf('/');
  if (i < 0) return '.';
  return i == 0 ? '/' : s.substring(0, i);
}

String normalizeSlashes(String p) => p.replaceAll(r'\', '/');

/// Caminho absoluto em qualquer plataforma (posix `/...` ou windows `C:\` / `\\UNC`).
bool isAbsolute(String p) =>
    p.startsWith('/') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) ||
    p.startsWith(r'\\');

/// Normaliza `..`/`.` em caminhos sem tocar no disco (proteção path traversal).
String lexicalNormalize(String p) {
  final parts = normalizeSlashes(p).split('/');
  final out = <String>[];
  final absolute = parts.isNotEmpty && parts.first.isEmpty;
  for (final seg in parts) {
    if (seg == '.' || seg.isEmpty) continue;
    if (seg == '..') {
      if (out.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else if (!absolute) {
        out.add('..');
      }
      continue;
    }
    out.add(seg);
  }
  return (absolute ? '/' : '') + out.join('/');
}
