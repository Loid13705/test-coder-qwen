/// Utilitários de paginação global (spec §PAGINAÇÃO GLOBAL).
///
/// Page<T> é o modelo único para toda superfície paginada: cursor-based para
/// chat/logs/git, offset para tabelas administrativas.
library;

import 'dart:convert';

class Page<T> {
  const Page({
    required this.items,
    this.nextCursor,
    this.prevCursor,
    this.hasMore = false,
    required this.pageSize,
    this.totalEstimate,
    this.offsetMode,
  });

  final List<T> items;
  final String? nextCursor;
  final String? prevCursor;
  final bool hasMore;
  final int pageSize;

  /// Total real quando a fonte consegue computá-lo; null quando desconhecido
  /// (a UI mostra "showing X of Y" apenas com total real).
  final int? totalEstimate;

  /// Página inicial quando em modo offset (tabelas administrativas).
  final int? offsetMode;

  bool get isEmpty => items.isEmpty;

  Page<R> map<R>(R Function(T) f) => Page(
        items: [for (final i in items) f(i)],
        nextCursor: nextCursor,
        prevCursor: prevCursor,
        hasMore: hasMore,
        pageSize: pageSize,
        totalEstimate: totalEstimate,
        offsetMode: offsetMode,
      );
}

/// Page sizes configuráveis da spec.
const kVtPageSizes = [20, 50, 100, 200];

/// Defaults por superfície (spec): chat 50 mensagens, search 50 resultados,
/// logs 100 linhas/chunks, tool catalog 30 tools, git log 50 commits.
const kDefaultPageSizeChat = 50;
const kDefaultPageSizeSearch = 50;
const kDefaultPageSizeLogs = 100;
const kDefaultPageSizeToolCatalog = 30;
const kDefaultPageSizeGitLog = 50;

/// Codificação de cursor opaco (base64 do payload interno) — evita que a UI
/// dependa do formato; cada repositório define seu payload real (id/timestamp).
String encodeCursor(Map<String, Object?> payload) {
  return base64Url.encode(utf8.encode(_jsonEncode(payload)));
}

Map<String, Object?> decodeCursor(String cursor) {
  final raw = utf8.decode(base64Url.decode(base64Url.normalize(cursor)));
  return _jsonDecode(raw);
}

const _codec = JsonCodec();

String _jsonEncode(Object? v) => _codec.encode(v);

Map<String, Object?> _jsonDecode(String s) =>
    (_codec.decode(s) as Map).cast<String, Object?>();
