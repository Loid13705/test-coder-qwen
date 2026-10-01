/// Diff real do Editor (spec §EDITOR/DIFF): LCS por linhas com Myers-style
/// backtracking, hunk navigation, stage/revert por hunk, ignore-whitespace e
/// word-diff. Sem dependências externas — algoritmo próprio sobre o texto.
library;

import 'dart:convert';

enum DiffOp { equal, insert, delete }

class DiffLine {
  const DiffLine(this.op, this.text, {this.oldLine, this.newLine});
  final DiffOp op;
  final String text;
  /// Número da linha no lado original (null para inserts), 1-based.
  final int? oldLine;
  /// Número da linha no lado novo (null para deletes), 1-based.
  final int? newLine;
}

class DiffHunk {
  DiffHunk({
    required this.start,
    required this.end,
    required this.hasInsert,
    required this.hasDelete,
  });

  /// Índice [start,end) na lista de linhas do diff (excluindo contexto).
  final int start;
  final int end;
  final bool hasInsert;
  final bool hasDelete;

  bool get changed => hasInsert || hasDelete;
}

class DiffResult {
  DiffResult(this.lines, this.hunks);

  final List<DiffLine> lines;
  final List<DiffHunk> hunks;

  int get additions =>
      lines.where((l) => l.op == DiffOp.insert).length;
  int get deletions => lines.where((l) => l.op == DiffOp.delete).length;

  List<DiffHunk> get changedHunks => hunks.where((h) => h.changed).toList();

  /// Unified diff textual (para exibição/exportação real).
  String toUnified({int context = 3}) {
    final sb = StringBuffer();
    for (final h in hunks) {
      var lo = h.start - context;
      if (lo < 0) lo = 0;
      var hi = h.end + context;
      if (hi > lines.length) hi = lines.length;
      final oldStart = lines.sublist(lo, hi).firstWhere(
          (l) => l.oldLine != null, orElse: () => lines[lo]).oldLine ??
          0;
      final newStart = lines.sublist(lo, hi).firstWhere(
          (l) => l.newLine != null, orElse: () => lines[lo]).newLine ??
          0;
      sb.writeln('@@ -$oldStart +$newStart @@');
      for (var i = lo; i < hi; i++) {
        final l = lines[i];
        sb.write(switch (l.op) {
          DiffOp.insert => '+',
          DiffOp.delete => '-',
          DiffOp.equal => ' ',
        });
        sb.writeln(l.text);
      }
    }
    return sb.toString();
  }
}

String _norm(String s, {bool ignoreWs = false}) =>
    ignoreWs ? s.replaceAll(RegExp(r'\s+'), ' ').trim() : s;

/// Diff de linhas entre [a] (original) e [b] (novo). DP LCS — adequado aos
/// tamanhos de buffer editável; arquivos gigantes viram read-only antes.
DiffResult diffLines(String a, String b, {bool ignoreWhitespace = false}) {
  final la = const LineSplitter().convert(a);
  final lb = const LineSplitter().convert(b);
  final n = la.length, m = lb.length;
  // Guarda tabela DP apenas quando o produto é razoável; senão heurística.
  if (n * m > 4000000) {
    return _diffFallback(la, lb, ignoreWhitespace);
  }
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = _norm(la[i], ignoreWs: ignoreWhitespace) ==
              _norm(lb[j], ignoreWs: ignoreWhitespace)
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  final out = <DiffLine>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (_norm(la[i], ignoreWs: ignoreWhitespace) ==
        _norm(lb[j], ignoreWs: ignoreWhitespace)) {
      out.add(DiffLine(DiffOp.equal, la[i], oldLine: i + 1, newLine: j + 1));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.add(DiffLine(DiffOp.delete, la[i], oldLine: i + 1));
      i++;
    } else {
      out.add(DiffLine(DiffOp.insert, lb[j], newLine: j + 1));
      j++;
    }
  }
  while (i < n) {
    out.add(DiffLine(DiffOp.delete, la[i], oldLine: i + 1));
    i++;
  }
  while (j < m) {
    out.add(DiffLine(DiffOp.insert, lb[j], newLine: j + 1));
    j++;
  }
  return DiffResult(out, _hunksOf(out));
}

DiffResult _diffFallback(List<String> la, List<String> lb, bool ignoreWs) {
  // buffers enormes: trata como um único hunk substituído (nunca inventa
  // similaridade que não calculou).
  final out = <DiffLine>[
    for (var i = 0; i < la.length; i++)
      DiffLine(DiffOp.delete, la[i], oldLine: i + 1),
    for (var j = 0; j < lb.length; j++)
      DiffLine(DiffOp.insert, lb[j], newLine: j + 1),
  ];
  return DiffResult(out,
      out.isEmpty ? [] : [DiffHunk(start: 0, end: out.length, hasInsert: lb.isNotEmpty, hasDelete: la.isNotEmpty)]);
}

List<DiffHunk> _hunksOf(List<DiffLine> lines) {
  final hunks = <DiffHunk>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].op == DiffOp.equal) {
      i++;
      continue;
    }
    final start = i;
    var hasIns = false, hasDel = false;
    while (i < lines.length && lines[i].op != DiffOp.equal) {
      if (lines[i].op == DiffOp.insert) hasIns = true;
      if (lines[i].op == DiffOp.delete) hasDel = true;
      i++;
    }
    hunks.add(DiffHunk(
        start: start, end: i, hasInsert: hasIns, hasDelete: hasDel));
  }
  return hunks;
}

/// Próxima/previa mudança (jump to next/prev problem aplica mesma ideia aos
/// diagnostics). Retorna índice da linha do diff ou null.
int? nextChange(List<DiffLine> lines, int fromIndex, {bool forward = true}) {
  if (forward) {
    for (var i = fromIndex + 1; i < lines.length; i++) {
      if (lines[i].op != DiffOp.equal) return i;
    }
  } else {
    for (var i = fromIndex - 1; i >= 0; i--) {
      if (lines[i].op != DiffOp.equal) return i;
    }
  }
  return null;
}

/// Aplica ao ORIGINAL apenas os hunks marcados como "stage" (stage hunk real:
/// resultado é o arquivo com aquelas mudanças aceitas; o resto volta ao disco).
String applySelectedHunks(
    String original, String modified, Set<int> acceptedHunkIndexes,
    {bool ignoreWhitespace = false}) {
  final d = diffLines(original, modified,
      ignoreWhitespace: ignoreWhitespace);
  final changed = d.changedHunks;
  final keep = <int>{};
  for (final idx in acceptedHunkIndexes) {
    if (idx >= 0 && idx < changed.length) keep.add(changed[idx].start);
  }
  final sb = StringBuffer();
  var lastOld = 0; // linhas do original já emitidas
  for (final h in changed) {
    if (!keep.contains(h.start)) continue;
    // contexto original até o hunk
    final firstOld =
        d.lines.sublist(h.start, h.end).firstWhere((l) => l.oldLine != null,
                orElse: () => d.lines[h.start])
            .oldLine;
    final cutTo = firstOld != null ? firstOld - 1 : lastOld;
    if (cutTo > lastOld) {
      final ctx = const LineSplitter().convert(original)
          .sublist(lastOld, cutTo < original.split('\n').length ? cutTo : lastOld);
      for (final l in ctx) {
        sb.writeln(l);
      }
      lastOld = cutTo;
    }
    for (var i = h.start; i < h.end; i++) {
      if (d.lines[i].op == DiffOp.insert) sb.writeln(d.lines[i].text);
    }
    // pula as linhas deletadas do original
    var maxOld = lastOld;
    for (var i = h.start; i < h.end; i++) {
      final ol = d.lines[i].oldLine;
      if (ol != null && ol > maxOld) maxOld = ol;
    }
    lastOld = maxOld;
  }
  // restante do original após o último hunk aceito
  final origLines = const LineSplitter().convert(original);
  for (var k = lastOld; k < origLines.length; k++) {
    sb.writeln(origLines[k]);
  }
  final res = sb.toString();
  return res.endsWith('\n') ? res.substring(0, res.length - 1) : res;
}

/// Reverte um hunk específico no buffer modificado (volta aquela região ao
/// conteúdo original) — revert hunk real.
String revertHunk(String original, String modified, int changedHunkIndex,
    {bool ignoreWhitespace = false}) {
  final d = diffLines(original, modified, ignoreWhitespace: ignoreWhitespace);
  final changed = d.changedHunks;
  if (changedHunkIndex < 0 || changedHunkIndex >= changed.length) {
    return modified;
  }
  final h = changed[changedHunkIndex];
  final modLines = const LineSplitter().convert(modified);
  final result = <String>[];
  // mapeamento: linhas new do hunk -> substituir pelas old do hunk
  final newIdxs = <int>[];
  final oldTexts = <String>[];
  for (var i = h.start; i < h.end; i++) {
    final l = d.lines[i];
    if (l.op == DiffOp.insert && l.newLine != null) newIdxs.add(l.newLine - 1);
    if (l.op == DiffOp.delete) oldTexts.add(l.text);
  }
  final replaceAt = newIdxs.isEmpty
      ? (d.lines[h.start].newLine != null ? d.lines[h.start].newLine! - 1 : null)
      : newIdxs.first;
  var inserted = false;
  for (var i = 0; i < modLines.length; i++) {
    if (newIdxs.contains(i)) continue; // drop linhas inseridas pelo hunk
    if (!inserted && replaceAt != null && i >= replaceAt) {
      result.addAll(oldTexts); // restaura linhas originais removidas
      inserted = true;
    }
    result.add(modLines[i]);
  }
  if (!inserted && oldTexts.isNotEmpty) result.addAll(oldTexts);
  return result.join('\n');
}

/// Word diff dentro de um par (delete, insert) — destaca tokens alterados.
List<(String, bool)> wordDiff(String oldLine, String newLine) {
  final ow = oldLine.split(RegExp(r'(\s+)'));
  final nw = newLine.split(RegExp(r'(\s+)'));
  final common = <String>{...ow}.intersection({...nw});
  final marks = <(String, bool)>[]
      ;
  for (final w in nw) {
    marks.add((w, !common.contains(w) && w.trim().isNotEmpty));
  }
  return marks;
}
