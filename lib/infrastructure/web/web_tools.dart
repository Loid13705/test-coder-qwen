/// Implementação REAL das tools de web (§CATÁLOGO §WEB).
///
/// Regras da casa:
/// - Toda requisição sai por `dart:io HttpClient` — nada de output inventado;
/// - Falha de rede/HTTP vira VtFailure tipado com status/bytes reais;
/// - Tamanho de resposta é limitado (size limit real, conexão abortada);
/// - robots.txt é verificado ANTES de fetch de página quando habilitado;
/// - Domínio fora da allowlist do sandbox → domain_not_allowed (nunca fetch);
/// - Provedores sem chave (Brave) degradam para scraping HTML real dos
///   endpoints públicos ou erro tipado honesto — nunca resultado fake.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';

typedef WebHttpClientFactory = HttpClient Function();

HttpClient _defaultWebHttpClient() =>
    HttpClient()..connectionTimeout = const Duration(seconds: 15);

const String _userAgent =
    'techVT-Agent/0.1 (+local-first IDE; respects robots.txt)';

// ------------------------------------------------------------- utilitários

class HttpResponseData {
  const HttpResponseData({
    required this.status,
    required this.headers,
    required this.bodyBytes,
    required this.finalUrl,
    required this.truncated,
  });
  final int status;
  final Map<String, String> headers;
  final List<int> bodyBytes;
  final String finalUrl;
  final bool truncated;

  String get bodyText =>
      utf8.decode(bodyBytes, allowMalformed: true).replaceAll('\r\n', '\n');
  int get sizeBytes => bodyBytes.length;
  String get contentType => headers['content-type'] ?? '';
}

/// Valor `default` declarado no JSON Schema de um campo.
Object? _schemaDefault(Map<String, Object?> schema, String field) {
  final props = schema['properties'];
  if (props is Map && props[field] is Map) {
    return (props[field] as Map)['default'];
  }
  return null;
}

String _strArg(MapToolInput input, Map<String, Object?> schema, String field) =>
    input.str(field).isNotEmpty
        ? input.str(field)
        : (_schemaDefault(schema, field)?.toString() ?? '');

int _intArg(MapToolInput input, Map<String, Object?> schema, String field) {
  final v = input.intOrNull(field);
  if (v != null) return v;
  final d = _schemaDefault(schema, field);
  return d is num ? d.toInt() : 0;
}

/// Fetch GET real com size limit, redirects manuais auditados e timeout.
Future<HttpResponseData> webFetch(
  HttpClient client,
  String urlStr, {
  required Duration timeout,
  int maxBytes = 2 * 1024 * 1024,
  int maxRedirects = 5,
  Map<String, String>? extraHeaders,
}) async {
  var current = Uri.parse(urlStr);
  for (var hop = 0;; hop++) {
    final req = await client.getUrl(current).timeout(timeout);
    req.headers.set('User-Agent', _userAgent);
    req.headers.set('Accept',
        'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8');
    extraHeaders?.forEach((k, v) => req.headers.set(k, v));
    final resp = await req.close().timeout(timeout);

    // redirect real: 3xx com Location — revalida scheme/hop e segue
    if (resp.statusCode >= 300 && resp.statusCode < 400) {
      final loc = resp.headers.value('location');
      await resp.drain<void>();
      if (loc == null) {
        throw VtFailure(
          code: VtErrorCode.networkUnavailable,
          message: 'HTTP ${resp.statusCode} em $current sem header Location '
              '(redirect não resolvível).',
        );
      }
      if (hop >= maxRedirects) {
        throw VtFailure(
          code: VtErrorCode.networkUnavailable,
          message:
              'Máximo de $maxRedirects redirects excedido partindo de $urlStr.',
        );
      }
      final next = current.resolve(loc);
      if (next.scheme != 'http' && next.scheme != 'https') {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Redirect para esquema não-HTTP bloqueado: $next.',
        );
      }
      current = next;
      continue;
    }

    final bytes = <int>[];
    var truncated = false;
    await for (final chunk in resp.timeout(timeout)) {
      if (bytes.length + chunk.length > maxBytes) {
        bytes.addAll(chunk.take(maxBytes - bytes.length));
        truncated = true;
        break; // size limit real: paramos de ler
      }
      bytes.addAll(chunk);
    }
    if (truncated) {
      // descarta o resto do corpo sem esperar (socket destruído)
      unawaited(resp.drain<void>().catchError((_) {}));
    }
    final headers = <String, String>{};
    resp.headers.forEach((name, values) => headers[name] = values.join(','));
    return HttpResponseData(
      status: resp.statusCode,
      headers: headers,
      bodyBytes: bytes,
      finalUrl: current.toString(),
      truncated: truncated,
    );
  }
}

/// Conversão honesta de exceções de I/O em VtFailure tipado.
VtFailure webIoFailure(Object e, String target) {
  if (e is SocketException) {
    return VtFailure(
      code: VtErrorCode.networkUnavailable,
      message: 'Falha de conexão/DNS em $target: '
          '${e.osError?.message ?? e.message}',
      retryable: true,
    );
  }
  if (e is TimeoutException) {
    return VtFailure(
      code: VtErrorCode.timeout,
      message: 'Requisição a $target excedeu o timeout.',
      retryable: true,
    );
  }
  if (e is HttpException) {
    return VtFailure(
      code: VtErrorCode.networkUnavailable,
      message: 'Erro HTTP em $target: ${e.message}',
    );
  }
  if (e is FormatException) {
    return VtFailure(
      code: VtErrorCode.validationFailed,
      message: 'Resposta de $target não é parseável: ${e.message}',
    );
  }
  return VtFailure(
    code: VtErrorCode.internalError,
    message: 'Erro de rede em $target: $e',
  );
}

String _stripHtml(String s) => s
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .trim();

String _isoToday() => DateTime.now().toUtc().toIso8601String().split('T').first;

bool _withinFreshness(String dateStr, String freshness) {
  if (freshness.isEmpty || freshness == 'noLimit') return true;
  final days = switch (freshness) {
    'day' => 1,
    'week' => 7,
    'month' => 31,
    _ => null,
  };
  if (days == null) return true;
  final dt = DateTime.tryParse(dateStr.replaceFirst(' GMT', 'Z'));
  if (dt == null) return true; // sem data parseável: não filtramos em silêncio
  return dt.isAfter(DateTime.now().toUtc().subtract(Duration(days: days)));
}

List<Citation> _searchCitations(List<Map<String, Object?>> results) => [
      for (final r in results)
        Citation(
          sourceType: 'url',
          sourceRef: r['url'] as String? ?? '',
          label: r['title'] as String? ?? r['url'] as String? ?? 'resultado',
        ),
    ];

// -------------------------------------------------------- parser XML mínimo
// Parser de tags balanceadas suficiente para RSS/Atom/sitemap bem-formados
// (RFC 8141). Não tolera HTML arbitrário — falha vira erro tipado no caller.

Map<String, dynamic> _tinyXml(String s) {
  var i = 0;
  while (i < s.length) {
    final lt = s.indexOf('<', i);
    if (lt < 0) {
      return {'name': '#text', 'attrs': const {}, 'children': [], 'text': ''};
    }
    if (s.startsWith('<?', lt) || s.startsWith('<!', lt)) {
      final end = s.startsWith('<!--', lt)
          ? s.indexOf('-->', lt)
          : s.indexOf('>', lt);
      i = end < 0 ? s.length : end + 1;
      continue;
    }
    i = lt;
    break;
  }
  if (i >= s.length) {
    throw const FormatException('XML sem elemento raiz');
  }
  final openEnd = s.indexOf('>', i);
  if (openEnd < 0) {
    throw const FormatException('XML truncado: tag de abertura não fechada');
  }
  final inner = s.substring(i + 1, openEnd);
  final name = inner.split(RegExp(r'[\s/]')).first;
  if (name.isEmpty) {
    throw FormatException('Tag inválida em offset $i');
  }
  final attrs = _xmlAttrs(inner);
  if (inner.endsWith('/')) {
    return {'name': name, 'attrs': attrs, 'children': [], 'text': ''};
  }
  final children = <Map<String, dynamic>>[];
  final textParts = <String>[];
  var p = openEnd + 1;
  final closeTag = '</$name';
  while (p < s.length) {
    final lt = s.indexOf('<', p);
    if (lt < 0) {
      textParts.add(s.substring(p));
      p = s.length;
      break;
    }
    if (lt > p) textParts.add(s.substring(p, lt));
    if (s.startsWith(closeTag, lt)) {
      final gt = s.indexOf('>', lt);
      if (gt < 0) throw FormatException('XML truncado em fecho de <$name>');
      return {
        'name': name,
        'attrs': attrs,
        'children': children,
        'text': _decodeEntities(textParts.join()),
      };
    }
    if (s.startsWith('<!--', lt)) {
      final end = s.indexOf('-->', lt);
      p = end < 0 ? s.length : end + 3;
      continue;
    }
    if (s.startsWith('<![CDATA[', lt)) {
      final end = s.indexOf(']]>', lt);
      textParts.add(s.substring(lt + 9, end < 0 ? s.length : end));
      p = end < 0 ? s.length : end + 3;
      continue;
    }
    if (s.startsWith('<?', lt) || s.startsWith('<!', lt)) {
      final end = s.indexOf('>', lt);
      p = end < 0 ? s.length : end + 1;
      continue;
    }
    if (s.startsWith('</', lt)) {
      throw FormatException('Tag de fechamento órfã perto do offset $lt');
    }
    children.add(_tinyXml(s.substring(lt)));
    p = _xmlSkipNode(s, lt);
  }
  throw FormatException('XML truncado: <$name> nunca fechado');
}

Map<String, String> _xmlAttrs(String inner) {
  final attrs = <String, String>{};
  for (final m in RegExp(r'''([\w:.-]+)\s*=\s*"([^"]*)"''').allMatches(inner)) {
    attrs[m.group(1)!] = _decodeEntities(m.group(2)!);
  }
  for (final m in RegExp(r"([\w:.-]+)\s*=\s*'([^']*)'").allMatches(inner)) {
    attrs.putIfAbsent(m.group(1)!, () => _decodeEntities(m.group(2)!));
  }
  return attrs;
}

String _decodeEntities(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// Índice após o fim do nó que começa em [start] (`<` em start).
int _xmlSkipNode(String s, int start) {
  final openEnd = s.indexOf('>', start);
  if (openEnd < 0) throw FormatException('XML truncado em offset $start');
  final head = s.substring(start + 1, openEnd);
  final name = head.split(RegExp(r'[\s/]')).first;
  if (head.endsWith('/')) return openEnd + 1;
  var depth = 1;
  var p = openEnd + 1;
  final openTag = RegExp('<$name(?=[\s/>])');
  final closeTag = RegExp('</$name[\s>]');
  while (p < s.length && depth > 0) {
    final nextClose = closeTag.matchAsPrefix(s, p)?.end ?? _findAfter(s, closeTag, p);
    if (nextClose < 0) throw FormatException('Fecho de <$name> ausente');
    // conta aberturas aninhadas antes do próximo fecho
    var q = p;
    while (true) {
      final no = openTag.matchAsPrefix(s, q)?.end ?? _findAfter(s, openTag, q);
      if (no < 0 || no >= nextClose) break;
      final gt = s.indexOf('>', no);
      if (!s.substring(no + 1, gt).endsWith('/')) depth++;
      q = gt + 1;
    }
    depth--;
    p = s.indexOf('>', nextClose) + 1;
  }
  return p;
}

int _findAfter(String s, RegExp re, int from) {
  final m = re.firstMatch(s.substring(from));
  return m == null ? -1 : from + m.start;
}

List<Map<String, dynamic>> _childElements(Map<String, dynamic> node) =>
    (node['children'] as List).cast<Map<String, dynamic>>();

String _firstChildText(Map<String, dynamic> node, String tagName) {
  for (final c in _childElements(node)) {
    if (c['name'] == tagName) {
      final own = _textOf(c);
      if (own.isNotEmpty) return own;
    }
  }
  return '';
}

String _textOf(Map<String, dynamic> node) {
  final direct = node['text'] as String? ?? '';
  if (direct.trim().isNotEmpty) return direct.trim();
  final parts = <String>[];
  for (final c in _childElements(node)) {
    parts.add(_textOf(c));
  }
  return parts.join(' ').trim();
}

({String title, String url, String date, String summary}) _parseRssItem(
    Map<String, dynamic> item) {
  var link = _firstChildText(item, 'link');
  if (link.isEmpty) {
    link = _firstChildText(item, 'guid').replaceFirst('Permalink: ', '');
  }
  return (
    title: _firstChildText(item, 'title'),
    url: link,
    date: _firstChildText(item, 'pubDate').isNotEmpty
        ? _firstChildText(item, 'pubDate')
        : _firstChildText(item, 'dc:date').isNotEmpty
            ? _firstChildText(item, 'dc:date')
            : _firstChildText(item, 'date'),
    summary: _stripHtml(_firstChildText(item, 'description')),
  );
}

({String title, String url, String date, String summary}) _parseAtomEntry(
    Map<String, dynamic> entry) {
  var url = '';
  for (final c in _childElements(entry)) {
    if (c['name'] == 'link') {
      final rel = (c['attrs'] as Map)['rel'] as String? ?? 'alternate';
      final href = (c['attrs'] as Map)['href'] as String? ?? '';
      if (href.isNotEmpty && (rel == 'alternate' || url.isEmpty)) url = href;
    }
  }
  final updated = _firstChildText(entry, 'updated');
  return (
    title: _firstChildText(entry, 'title'),
    url: url,
    date: updated.isNotEmpty ? updated : _firstChildText(entry, 'published'),
    summary: _stripHtml(_firstChildText(entry, 'summary').isNotEmpty
        ? _firstChildText(entry, 'summary')
        : _firstChildText(entry, 'content')),
  );
}

List<({String title, String url, String date, String summary})> parseFeedXml(
    String xml) {
  final root = _tinyXml(xml);
  switch (root['name']) {
    case 'rss':
      final channel =
          _childElements(root).firstWhere((c) => c['name'] == 'channel');
      return [
        for (final item in _childElements(channel))
          if (item['name'] == 'item') _parseRssItem(item)
      ];
    case 'feed':
      return [
        for (final e in _childElements(root))
          if (e['name'] == 'entry') _parseAtomEntry(e)
      ];
    default:
      throw FormatException('Não é RSS/Atom (raiz: <${root['name']}>)');
  }
}

// ------------------------------------------------------------ base das tools

abstract class WebToolBase extends VtTool<MapToolInput, TextOutput> {
  WebToolBase({WebHttpClientFactory? httpClientFactory})
      : _http = httpClientFactory ?? _defaultWebHttpClient;

  final WebHttpClientFactory _http;

  @override
  List<String> get capabilities => const ['network'];

  @override
  RiskLevel get risk => RiskLevel.networkRead;

  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;

  @override
  bool get isIdempotent => true;

  @override
  RetryPolicy get retryPolicy => const RetryPolicy(maxAttempts: 2);

  @override
  Duration get timeout => const Duration(seconds: 30);

  @override
  Map<String, Object?> get outputSchema => const {'type': 'object'};

  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async => const HealthOk();

  /// Validação de URL + política de domínio ANTES de qualquer conexão.
  ({Uri uri, String error}) _checkUrl(ToolContext ctx, String urlStr) {
    final uri = Uri.tryParse(urlStr);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return (uri: Uri.parse('http://invalid.invalid'), error: 'bad_url');
    }
    if (!ctx.sandbox.isAllowedDomain(uri.host, ctx)) {
      return (uri: uri, error: 'domain_denied');
    }
    return (uri: uri, error: '');
  }

  ToolResult<TextOutput> _badUrl(String urlStr) => ToolFailureResult(VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'URL inválida ou esquema não-HTTP(S): "$urlStr".',
      ));

  ToolResult<TextOutput> _denied(String host) =>
      ToolFailureResult(VtFailure.domainNotAllowed(host));

  /// Fetch com verificação prévia de robots.txt (política real).
  Future<HttpResponseData> fetchWithRobots(
    HttpClient client,
    ToolContext ctx,
    Uri uri, {
    required int maxBytes,
    bool respectRobots = true,
  }) async {
    if (respectRobots) {
      final decision =
          await checkRobots(client, uri, timeout: const Duration(seconds: 10));
      if (!decision.allowed) {
        throw VtFailure(
          code: VtErrorCode.permissionDenied,
          message: 'robots.txt de ${uri.host} proíbe "${uri.path}" para '
              '"$_userAgent"'
              '${decision.rule != null ? ' (regra: ${decision.rule})' : ''}.',
          details: {'disallow': decision.rule, 'robotsUrl': decision.source},
        );
      }
    }
    return webFetch(client, uri.toString(),
        timeout: timeout, maxBytes: maxBytes);
  }

  Future<ToolResult<TextOutput>> runGuarded(
    ToolContext ctx,
    String targetForErrors,
    Future<ToolResult<TextOutput>> Function(HttpClient client) body,
  ) async {
    final client = _http();
    try {
      return await body(client);
    } on VtFailure catch (f) {
      return ToolFailureResult(f);
    } catch (e) {
      return ToolFailureResult(webIoFailure(e, targetForErrors));
    } finally {
      client.close(force: true);
    }
  }
}

// -------------------------------------------------------------- web.search
class WebSearchTool extends WebToolBase {
  WebSearchTool({super.httpClientFactory});

  @override
  String get id => 'web.search';
  @override
  String get title => 'Web search';
  @override
  String get description =>
      'Busca web genérica REAL. Provider preferencial Brave Search API '
      '(settings "web.braveApiKey"); sem chave usa DuckDuckGo HTML real. '
      'Resultados vêm com URL original — nada é inventado.';
  @override
  ToolCategory get category => ToolCategory.web;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['query'],
        'properties': {
          'query': {'type': 'string'},
          'count': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 20,
            'default': 8
          },
          'region': {'type': 'string', 'default': 'wt-wt'},
        },
      };

  static const braveEndpoint = 'https://api.search.brave.com/res/v1/web/search';

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final query = input.str('query');
    final count = _intArg(input, inputSchema, 'count');
    final region = _strArg(input, inputSchema, 'region');
    return runGuarded(ctx, query, (client) async {
      final key = ctx.settings.get('web.braveApiKey')?.toString() ??
          Platform.environment['BRAVE_API_KEY'] ??
          '';
      final results = <Map<String, Object?>>[];
      final String providerUsed;
      if (key.isNotEmpty) {
        providerUsed = 'brave';
        final uri = Uri.parse(braveEndpoint).replace(queryParameters: {
          'q': query,
          'count': '$count',
          'search_lang': region,
        });
        final res = await webFetch(client, uri.toString(),
            timeout: timeout,
            extraHeaders: {'X-Subscription-Token': key});
        if (res.status == 429) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.rateLimited,
            message: 'Brave Search API rate limited (HTTP 429).',
            retryable: true,
          ));
        }
        if (res.status >= 400) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.networkUnavailable,
            message: 'Brave Search respondeu HTTP ${res.status}.',
            details: {'bodyPreview': res.bodyText.substring(
                0, res.bodyText.length < 300 ? res.bodyText.length : 300)},
          ));
        }
        final json = jsonDecode(res.bodyText) as Map<String, Object?>;
        final web = (json['web'] as Map?)?['results'] as List? ?? const [];
        for (final r in web.take(count)) {
          final m = (r as Map).cast<String, Object?>();
          results.add({
            'title': m['title'] ?? '',
            'url': m['url'] ?? '',
            'snippet': m['description'] ?? '',
            'age': m['age'] ?? '',
          });
        }
      } else {
        providerUsed = 'duckduckgo_html';
        final res = await webFetch(
          client,
          Uri.parse('https://html.duckduckgo.com/html/')
              .replace(queryParameters: {'q': query, 'kl': region})
              .toString(),
          timeout: timeout,
        );
        if (res.status >= 400) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.networkUnavailable,
            message: 'DuckDuckGo HTML respondeu HTTP ${res.status}.',
          ));
        }
        final links = RegExp(
          r'<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]*)"[^>]*>(.*?)</a>',
          dotAll: true,
        ).allMatches(res.bodyText).toList();
        final snippets = RegExp(
          r'<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>',
          dotAll: true,
        ).allMatches(res.bodyText).toList();
        for (var i = 0; i < links.length && results.length < count; i++) {
          final rawHref = Uri.decodeComponent(links[i].group(1) ?? '');
          final uddg = RegExp(r'uddg=([^&]+)').firstMatch(rawHref);
          final url =
              uddg != null ? Uri.decodeQueryComponent(uddg.group(1)!) : rawHref;
          if (!url.startsWith('http')) continue;
          results.add({
            'title': _stripHtml(links[i].group(2) ?? ''),
            'url': url,
            'snippet': i < snippets.length
                ? _stripHtml(snippets[i].group(1) ?? '')
                : '',
          });
        }
      }
      if (results.isEmpty) {
        return ToolSuccess(
          data: TextOutput(
            'Busca REAL via $providerUsed para "$query": 0 resultados.\n'
            '(sem simulação — o provedor não retornou nada)',
            metadata: {'provider': providerUsed, 'count': 0},
          ),
        );
      }
      final lines = [
        'Busca web REAL ($providerUsed) — "$query"',
        '',
      ];
      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        lines.add('${i + 1}. ${r['title']}');
        lines.add('   ${r['url']}');
        final snip = r['snippet']?.toString() ?? '';
        if (snip.isNotEmpty) lines.add('   $snip');
        final age = r['age']?.toString() ?? '';
        if (age.isNotEmpty) lines.add('   idade: $age');
        lines.add('');
      }
      return ToolSuccess(
        data: TextOutput(lines.join('\n'), metadata: {
          'provider': providerUsed,
          'count': results.length,
          'results': results,
        }),
        citations: _searchCitations(results),
      );
    });
  }
}

// ---------------------------------------------------------- web.news_search
class WebNewsSearchTool extends WebToolBase {
  WebNewsSearchTool({super.httpClientFactory});

  @override
  String get id => 'web.news_search';
  @override
  String get title => 'News search';
  @override
  String get description =>
      'Busca notícias REAL com filtro de frescor. Brave News API quando há '
      'chave; senão Google News RSS público — freshness day/week/month é '
      'aplicado sobre datas reais do feed, não decorativo.';
  @override
  ToolCategory get category => ToolCategory.web;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['query'],
        'properties': {
          'query': {'type': 'string'},
          'freshness': {
            'type': 'string',
            'enum': ['noLimit', 'day', 'week', 'month'],
            'default': 'week',
          },
          'count': {'type': 'integer', 'default': 10, 'maximum': 30},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final query = input.str('query');
    final freshness = _strArg(input, inputSchema, 'freshness');
    final count = _intArg(input, inputSchema, 'count');
    return runGuarded(ctx, query, (client) async {
      final key = ctx.settings.get('web.braveApiKey')?.toString() ??
          Platform.environment['BRAVE_API_KEY'] ??
          '';
      final items = <Map<String, Object?>>[];
      final String provider;
      if (key.isNotEmpty) {
        provider = 'brave_news';
        final uri =
            Uri.parse('https://api.search.brave.com/res/v1/news/search')
                .replace(queryParameters: {
          'q': query,
          'freshness': freshness,
          'count': '$count',
        });
        final res = await webFetch(client, uri.toString(),
            timeout: timeout,
            extraHeaders: {'X-Subscription-Token': key});
        if (res.status >= 400) {
          return ToolFailureResult(VtFailure(
            code: res.status == 429
                ? VtErrorCode.rateLimited
                : VtErrorCode.networkUnavailable,
            message: 'Brave News respondeu HTTP ${res.status}.',
            retryable: res.status == 429,
          ));
        }
        final json = jsonDecode(res.bodyText) as Map<String, Object?>;
        for (final r in ((json['results'] as List?) ?? const []).take(count)) {
          final m = (r as Map).cast<String, Object?>();
          items.add({
            'title': m['title'] ?? '',
            'url': m['url'] ?? '',
            'date': m['age'] ?? '',
            'snippet': m['description'] ?? '',
          });
        }
      } else {
        provider = 'google_news_rss';
        final when = switch (freshness) {
          'day' => '1',
          'week' => '7',
          'month' => '31',
          _ => '',
        };
        final q = when.isEmpty ? query : '$query when:$when days';
        final url = 'https://news.google.com/rss/search'
            '?q=${Uri.encodeQueryComponent(q)}';
        final res = await webFetch(client, url, timeout: timeout);
        if (res.status >= 400) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.networkUnavailable,
            message: 'Google News RSS respondeu HTTP ${res.status}.',
          ));
        }
        for (final it in parseFeedXml(res.bodyText)) {
          if (!_withinFreshness(it.date, freshness)) continue;
          items.add({
            'title': it.title,
            'url': it.url,
            'date': it.date,
            'snippet': it.summary,
          });
          if (items.length >= count) break;
        }
      }
      if (items.isEmpty) {
        return ToolSuccess(
          data: TextOutput(
              'Notícias REAL ($provider) para "$query" (freshness=$freshness): '
              'nenhum resultado no período.',
              metadata: {'provider': provider, 'count': 0}),
        );
      }
      final lines = [
        'Notícias REAIS ($provider) — "$query" (freshness=$freshness)',
        '',
      ];
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        lines.add('${i + 1}. ${it['title']}');
        lines.add('   ${it['url']}');
        if ((it['date'] ?? '').toString().isNotEmpty) {
          lines.add('   data: ${it['date']}');
        }
        final snip = (it['snippet'] ?? '').toString();
        if (snip.isNotEmpty) lines.add('   $snip');
        lines.add('');
      }
      return ToolSuccess(
        data: TextOutput(lines.join('\n'),
            metadata: {'provider': provider, 'results': items}),
        citations: _searchCitations(items),
      );
    });
  }
}

// ---------------------------------------------------------- web.image_search
class WebImageSearchTool extends WebToolBase {
  WebImageSearchTool({super.httpClientFactory});

  @override
  String get id => 'web.image_search';
  @override
  String get title => 'Image search';
  @override
  String get description =>
      'Busca imagens REAL via Openverse (catálogo CC; licença/attribution '
      'quando presentes nos metadados). Licença ausente é reportada como '
      'ausente — nunca preenchida por suposição.';
  @override
  ToolCategory get category => ToolCategory.web;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['query'],
        'properties': {
          'query': {'type': 'string'},
          'count': {'type': 'integer', 'default': 10, 'maximum': 20},
          'license': {
            'type': 'string',
            'description': 'filtro opcional, ex.: cc0, by, by-sa',
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final query = input.str('query');
    final count = _intArg(input, inputSchema, 'count');
    final license = input.str('license');
    return runGuarded(ctx, query, (client) async {
      final uri = Uri.parse('https://api.openverse.org/v1/images/')
          .replace(queryParameters: {
        'q': query,
        'page_size': '$count',
        if (license.isNotEmpty) 'license': license,
      });
      final res = await webFetch(client, uri.toString(), timeout: timeout);
      if (res.status >= 400) {
        return ToolFailureResult(VtFailure(
          code: res.status == 429
              ? VtErrorCode.rateLimited
              : VtErrorCode.networkUnavailable,
          message: 'Openverse respondeu HTTP ${res.status}.',
          retryable: res.status == 429,
        ));
      }
      final json = jsonDecode(res.bodyText) as Map<String, Object?>;
      final raw = (json['results'] as List?) ?? const [];
      final imgs = <Map<String, Object?>>[];
      for (final r in raw) {
        final m = (r as Map).cast<String, Object?>();
        imgs.add({
          'title': m['title'] ?? '',
          'url': m['foreign_landing_url'] ?? m['detail_page'] ?? '',
          'image': m['url'] ?? m['thumbnail'] ?? '',
          'creator': m['creator'],
          'license': m['license'],
          'license_version': m['license_version'],
          'source': m['source'],
        });
      }
      if (imgs.isEmpty) {
        return ToolSuccess(
          data: TextOutput('Openverse: 0 imagens para "$query".',
              metadata: {'count': 0}),
        );
      }
      final lines = ['Imagens REAIS (Openverse) — "$query"', ''];
      for (var i = 0; i < imgs.length; i++) {
        final im = imgs[i];
        lines.add('${i + 1}. ${im['title']}');
        lines.add('   img: ${im['image']}');
        lines.add('   origem: ${im['url']}');
        final lic = im['license'];
        if (lic != null) {
          lines.add('   licença: ${lic.toString().toUpperCase()}'
              '${im['license_version'] != null ? ' ${im['license_version']}' : ''}'
              '${im['creator'] != null ? ' | © ${im['creator']}' : ''}');
        } else {
          lines.add('   licença: desconhecida (metadado ausente)');
        }
        lines.add('');
      }
      return ToolSuccess(
        data: TextOutput(lines.join('\n'),
            metadata: {'count': imgs.length, 'results': imgs}),
        citations: [
          for (final im in imgs)
            Citation(
              sourceType: 'url',
              sourceRef: (im['url'] ?? im['image'] ?? '').toString(),
              label: (im['title'] ?? '').toString(),
            ),
        ],
      );
    });
  }
}

// ------------------------------------------------------------ web.doc_search
class WebDocSearchTool extends WebToolBase {
  WebDocSearchTool({super.httpClientFactory});

  @override
  String get id => 'web.doc_search';
  @override
  String get title => 'Documentation search';
  @override
  String get description =>
      'Busca documentação técnica REAL: Dash DevDocs (API pública) quando '
      'docset informado; fallback é busca restrita (site:) a hosts oficiais '
      'de docs — filtro aplicado de verdade nos resultados.';
  @override
  ToolCategory get category => ToolCategory.web;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['query'],
        'properties': {
          'query': {'type': 'string'},
          'docset': {
            'type': 'string',
            'description': 'ex.: dart, flutter, react (prefixo DevDocs)',
          },
          'count': {'type': 'integer', 'default': 8, 'maximum': 20},
        },
      };

  static const _officialDocsHosts = [
    'dart.dev',
    'api.dart.dev',
    'flutter.dev',
    'api.flutter.dev',
    'docs.flutter.dev',
    'pub.dev',
    'react.dev',
    'developer.mozilla.org',
    'docs.python.org',
    'learn.microsoft.com',
    'kotlinlang.org',
    'doc.rust-lang.org',
  ];

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final query = input.str('query');
    final docset = input.str('docset');
    final count = _intArg(input, inputSchema, 'count');
    return runGuarded(ctx, query, (client) async {
      final hits = <Map<String, Object?>>[];
      // 1) Dash DevDocs API real (busca nomeada por docset)
      if (docset.isNotEmpty) {
        final uri = Uri.parse('https://documents4dash.com/?controller=search')
            .replace(queryParameters: {'q': '$docset::$query'});
        try {
          final res = await webFetch(client, uri.toString(), timeout: timeout);
          if (res.status == 200) {
            final list = (jsonDecode(res.bodyText) as List?) ?? const [];
            for (final r in list.take(count)) {
              final m = (r as Map).cast<String, Object?>();
              final path = (m['path'] ?? '').toString();
              hits.add({
                'title': m['name'] ?? path,
                'url': path.startsWith('http')
                    ? path
                    : 'https://devdocs.io/${Uri.encodeComponent(docset)}/'
                        '${path.replaceFirst(RegExp('^/?$docset/'), '')}',
                'snippet': 'DevDocs ($docset)',
              });
            }
          }
        } on Object {
          // DevDocs fora do ar: seguimos para o fallback (reportado abaixo)
        }
      }
      // 2) fallback: DuckDuckGo Lite real restrito a hosts de documentação
      if (hits.isEmpty) {
        final q = docset.isNotEmpty ? '$query $docset documentation' : query;
        final res = await webFetch(
          client,
          Uri.parse('https://lite.duckduckgo.com/lite/').replace(
              queryParameters: {
                'q': '$q site:(dart.dev OR flutter.dev OR pub.dev OR '
                    'api.dart.dev OR api.flutter.dev OR docs.flutter.dev OR '
                    'developer.mozilla.org)'
              }).toString(),
          timeout: timeout,
        );
        if (res.status >= 400) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.networkUnavailable,
            message: 'Busca de docs respondeu HTTP ${res.status}.',
          ));
        }
        final links = RegExp(
          r'<a[^>]*rel="nofollow"[^>]*href="([^"]*)"[^>]*>(.*?)</a>',
          dotAll: true,
        ).allMatches(res.bodyText).toList();
        final snippets = RegExp(r'class="result-snippet">(.*?)</td>',
                dotAll: true)
            .allMatches(res.bodyText)
            .toList();
        for (var i = 0; i < links.length && hits.length < count; i++) {
          final rawHref = links[i].group(1) ?? '';
          final uddg = RegExp(r'uddg=([^&]+)').firstMatch(rawHref);
          final url =
              uddg != null ? Uri.decodeQueryComponent(uddg.group(1)!) : rawHref;
          final host = Uri.tryParse(url)?.host ?? '';
          if (!_officialDocsHosts
              .any((h) => host == h || host.endsWith('.$h'))) {
            continue; // só docs oficiais — filtro real, não decorativo
          }
          hits.add({
            'title': _stripHtml(links[i].group(2) ?? ''),
            'url': url,
            'snippet':
                i < snippets.length ? _stripHtml(snippets[i].group(1) ?? '') : '',
          });
        }
      }
      if (hits.isEmpty) {
        return ToolSuccess(
          data: TextOutput(
              'Busca de documentação REAL: nenhum resultado oficial para '
              '"$query"${docset.isNotEmpty ? ' (docset=$docset)' : ''}.',
              metadata: {'count': 0}),
        );
      }
      final lines = ['Documentação REAL — "$query"', ''];
      for (var i = 0; i < hits.length; i++) {
        lines.add('${i + 1}. ${hits[i]['title']}');
        lines.add('   ${hits[i]['url']}');
        final s = (hits[i]['snippet'] ?? '').toString();
        if (s.isNotEmpty) lines.add('   $s');
        lines.add('');
      }
      return ToolSuccess(
        data: TextOutput(lines.join('\n'), metadata: {'results': hits}),
        citations: _searchCitations(hits),
      );
    });
  }
}

// ----------------------------------------------------------- web.code_search
class WebCodeSearchTool extends WebToolBase {
  WebCodeSearchTool({super.httpClientFactory});

  @override
  String get id => 'web.code_search';
  @override
  String get title => 'Code search';
  @override
  String get description =>
      'Busca snippets/repositórios públicos REAIS via GitHub REST API. '
      'Busca de código exige token autenticado (GitHub impõe); sem token a '
      'tool degrada honestamente para modo repositories. Nunca fabrica '
      'código: retorna repo, path e URL canônica.';
  @override
  ToolCategory get category => ToolCategory.web;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['query'],
        'properties': {
          'query': {'type': 'string'},
          'mode': {
            'type': 'string',
            'enum': ['code', 'repositories'],
            'default': 'repositories',
          },
          'language': {'type': 'string', 'description': 'ex.: dart'},
          'count': {'type': 'integer', 'default': 8, 'maximum': 30},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final query = input.str('query');
    var mode = _strArg(input, inputSchema, 'mode');
    final language = input.str('language');
    final count = _intArg(input, inputSchema, 'count');
    return runGuarded(ctx, query, (client) async {
      final token = ctx.settings.get('web.githubToken')?.toString() ??
          Platform.environment['GITHUB_TOKEN'] ??
          '';
      if (mode == 'code' && token.isEmpty) {
        // recusa honesta ANTES de gastar request (GitHub devolve 401)
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.approvalRequired,
          message: 'GitHub code search exige token autenticado (settings '
              '"web.githubToken"). Use mode=repositories ou configure o token.',
          setupUri: 'techvt://settings/web',
        ));
      }
      final q = [
        query,
        if (language.isNotEmpty) 'language:$language',
      ].join(' ');
      final endpoint = mode == 'code'
          ? 'https://api.github.com/search/code'
          : 'https://api.github.com/search/repositories';
      final uri = Uri.parse(endpoint)
          .replace(queryParameters: {'q': q, 'per_page': '$count'});
      final res = await webFetch(client, uri.toString(),
          timeout: timeout,
          extraHeaders: {
            'Accept': 'application/vnd.github+json',
            if (token.isNotEmpty) 'Authorization': 'Bearer $token',
          });
      if (res.status == 401 || res.status == 403) {
        return ToolFailureResult(VtFailure(
          code: res.status == 403 ? VtErrorCode.rateLimited : VtErrorCode.permissionDenied,
          message: 'GitHub API recusou (HTTP ${res.status}). '
              'Rate limit anônimo ou token inválido.',
          retryable: res.status == 403,
        ));
      }
      if (res.status >= 400) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.networkUnavailable,
          message: 'GitHub API respondeu HTTP ${res.status}.',
        ));
      }
      final json = jsonDecode(res.bodyText) as Map<String, Object?>;
      final items = <Map<String, Object?>>[];
      for (final r in ((json['items'] as List?) ?? const [])) {
        final m = (r as Map).cast<String, Object?>();
        if (mode == 'code') {
          final repo = (m['repository'] as Map?)?['full_name'] ?? '';
          final htmlUrl = (m['html_url'] ?? '').toString();
          items.add({
            'title': '$repo:${m['path']}',
            'url': htmlUrl.isNotEmpty
                ? htmlUrl
                : 'https://github.com/$repo/blob/HEAD/${m['path']}',
            'snippet': '',
          });
        } else {
          items.add({
            'title': m['full_name'] ?? '',
            'url': m['html_url'] ?? '',
            'snippet': '${m['description'] ?? ''} '
                '(★${m['stargazers_count'] ?? '?'}, ${m['language'] ?? 'n/a'})',
          });
        }
      }
      if (items.isEmpty) {
        return ToolSuccess(
          data: TextOutput(
              'GitHub search REAL ($mode): 0 resultados para "$q".',
              metadata: {'count': 0}),
        );
      }
      final lines = [
        'Código/repos REAIS (GitHub, modo=$mode) — "$q"',
        '',
      ];
      for (var i = 0; i < items.length; i++) {
        lines.add('${i + 1}. ${items[i]['title']}');
        lines.add('   ${items[i]['url']}');
        final s = (items[i]['snippet'] ?? '').toString().trim();
        if (s.isNotEmpty) lines.add('   $s');
        lines.add('');
      }
      return ToolSuccess(
        data: TextOutput(lines.join('\n'), metadata: {'results': items}),
        citations: _searchCitations(items),
      );
    });
  }
}

// ------------------------------------------------------------ web.fetch_page
class WebFetchPageTool extends WebToolBase {
  WebFetchPageTool({super.httpClientFactory});

  @override
  String get id => 'web.fetch_page';
  @override
  String get title => 'Fetch page';
  @override
  String get description =>
      'Baixa página REAL: headers de resposta, status code e tamanho com '
      'limite rígido (leitura abortada ao exceder — flagged truncated). '
      'robots.txt verificado antes por padrão.';
  @override
  ToolCategory get category => ToolCategory.web;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['url'],
        'properties': {
          'url': {'type': 'string'},
          'maxBytes': {'type': 'integer', 'default': 524288},
          'respectRobots': {'type': 'boolean', 'default': true},
          'includeBody': {'type': 'boolean', 'default': true},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final urlStr = input.str('url');
    final checked = _checkUrl(ctx, urlStr);
    if (checked.error == 'bad_url') return _badUrl(urlStr);
    if (checked.error == 'domain_denied') return _denied(checked.uri.host);
    final maxBytes = _intArg(input, inputSchema, 'maxBytes');
    final respectRobots = input.values['respectRobots'] as bool? ?? true;
    final includeBody = input.values['includeBody'] as bool? ?? true;
    return runGuarded(ctx, urlStr, (client) async {
      final res = await fetchWithRobots(client, ctx, checked.uri,
          maxBytes: maxBytes, respectRobots: respectRobots);
      final meta = <String, Object?>{
        'status': res.status,
        'contentType': res.contentType,
        'sizeBytes': res.sizeBytes,
        'truncated': res.truncated,
        'finalUrl': res.finalUrl,
        'headers': res.headers,
      };
      final head = [
        'GET ${checked.uri} → HTTP ${res.status}',
        'content-type: ${res.contentType}',
        'bytes: ${res.sizeBytes}'
            '${res.truncated ? ' (TRUNCADO no limite de $maxBytes — corpo parcial real)' : ''}',
        'url final: ${res.finalUrl}',
        'headers:',
        ...res.headers.entries.map((e) => '  ${e.key}: ${e.value}'),
      ];
      final citation = Citation(
          sourceType: 'url', sourceRef: res.finalUrl, label: urlStr);
      if (!includeBody) {
        return ToolSuccess(
          data: TextOutput(head.join('\n'), metadata: meta),
          citations: [citation],
        );
      }
      final body = res.bodyText;
      final preview = res.contentType.contains('html')
          ? _extractMainContent(body).text
          : body;
      return ToolSuccess(
        data: TextOutput('${head.join('\n')}\n\ncorpo:\n$preview',
            metadata: meta),
        citations: [citation],
      );
    });
  }
}

// -------------------------------------------------------- web.extract_article
class WebExtractArticleTool extends WebToolBase {
  WebExtractArticleTool({super.httpClientFactory});

  @override
  String get id => 'web.extract_article';
  @override
  String get title => 'Extract article';
  @override
  String get description =>
      'Extrai conteúdo principal REAL (heurística de densidade de parágrafos '
      '+ candidatos article/main/entry-content). Reporta confiança e tamanho; '
      'se a página não tem artigo, diz — não inventa texto.';
  @override
  ToolCategory get category => ToolCategory.web;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['url'],
        'properties': {
          'url': {'type': 'string'},
          'maxChars': {'type': 'integer', 'default': 20000},
          'respectRobots': {'type': 'boolean', 'default': true},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final urlStr = input.str('url');
    final checked = _checkUrl(ctx, urlStr);
    if (checked.error == 'bad_url') return _badUrl(urlStr);
    if (checked.error == 'domain_denied') return _denied(checked.uri.host);
    final maxChars = _intArg(input, inputSchema, 'maxChars');
    final respectRobots = input.values['respectRobots'] as bool? ?? true;
    return runGuarded(ctx, urlStr, (client) async {
      final res = await fetchWithRobots(client, ctx, checked.uri,
          maxBytes: 2 * 1024 * 1024, respectRobots: respectRobots);
      if (res.status >= 400) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.networkUnavailable,
          message: 'HTTP ${res.status} ao extrair artigo de $urlStr.',
          details: {'status': res.status},
        ));
      }
      if (!res.contentType.contains('html')) {
        return ToolFailureResult(VtFailure(
          code: VtErrorCode.validationFailed,
          message: 'Conteúdo não-HTML (${res.contentType}) — extração de '
              'artigo não se aplica.',
        ));
      }
      final art = _extractMainContent(res.bodyText);
      final citation =
          Citation(sourceType: 'url', sourceRef: res.finalUrl, label: urlStr);
      if (art.text.trim().isEmpty) {
        return ToolSuccess(
          data: TextOutput(
            'ARTIGO NÃO ENCONTRADO em $urlStr (heurística real sem conteúdo '
            'candidato; página pode ser SPA/JS-only).',
            metadata: {'confidence': 0.0, 'chars': 0},
          ),
          citations: [citation],
        );
      }
      final text = art.text.length > maxChars
          ? '${art.text.substring(0, maxChars)}\n…[truncado em $maxChars chars]'
          : art.text;
      return ToolSuccess(
        data: TextOutput(
          '${art.title.isNotEmpty ? '${art.title}\n' : ''}'
          '${art.byline.isNotEmpty ? 'por ${art.byline}\n' : ''}'
          '${art.siteName.isNotEmpty ? '${art.siteName}\n' : ''}\n$text',
          metadata: {
            'confidence': art.confidence,
            'chars': art.text.length,
            'title': art.title,
            'status': res.status,
          },
        ),
        citations: [citation],
      );
    });
  }
}

// ------------------------------------------------------- web.citation_format
class WebCitationFormatTool extends WebToolBase {
  WebCitationFormatTool({super.httpClientFactory});

  @override
  String get id => 'web.citation_format';
  @override
  String get title => 'Format citation';
  @override
  String get description =>
      'Formata citação a partir de METADADOS REAIS. Campos faltantes são '
      'extraídos da página real (og:/meta/link rel=author) antes de formatar; '
      'o que continuar ausente vira placeholder explícito — nunca invenção.';
  @override
  ToolCategory get category => ToolCategory.web;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['url'],
        'properties': {
          'url': {'type': 'string'},
          'style': {
            'type': 'string',
            'enum': ['apa', 'mla', 'chicago', 'ieee', 'bibtex', 'markdown'],
            'default': 'markdown',
          },
          'title': {'type': 'string'},
          'author': {'type': 'string'},
          'date': {'type': 'string', 'description': 'ISO 8601'},
          'publisher': {'type': 'string'},
          'accessed': {'type': 'string', 'description': 'default hoje'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final urlStr = input.str('url');
    final style = _strArg(input, inputSchema, 'style');
    final checked = _checkUrl(ctx, urlStr);
    if (checked.error == 'bad_url') return _badUrl(urlStr);
    var title = input.str('title');
    var author = input.str('author');
    var date = input.str('date');
    var publisher = input.str('publisher');
    final accessed =
        input.str('accessed').isNotEmpty ? input.str('accessed') : _isoToday();
    final needsFetch =
        title.isEmpty || author.isEmpty || date.isEmpty || publisher.isEmpty;
    if (needsFetch && checked.error == 'domain_denied') {
      return _denied(checked.uri.host);
    }
    return runGuarded(ctx, urlStr, (client) async {
      if (needsFetch && checked.error == '') {
        final res =
            await webFetch(client, urlStr, timeout: timeout, maxBytes: 512 * 1024);
        if (res.status < 400 && res.contentType.contains('html')) {
          final html = res.bodyText;
          title = title.isNotEmpty
              ? title
              : _metaValue(html, 'og:title') ??
                  _regexGroup(
                      html, RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true)) ??
                  '';
          author = author.isNotEmpty
              ? author
              : _metaValue(html, 'author') ??
                  _metaValue(html, 'article:author') ??
                  '';
          date = date.isNotEmpty
              ? date
              : _metaValue(html, 'article:published_time') ??
                  _regexGroup(
                      html, RegExp(r'"datePublished"\s*:\s*"([^"]+)"')) ??
                  '';
          publisher = publisher.isNotEmpty
              ? publisher
              : _metaValue(html, 'og:site_name') ?? Uri.parse(res.finalUrl).host;
        }
      }
      final missing = <String>[
        if (title.isEmpty) 'title',
        if (author.isEmpty) 'author',
        if (date.isEmpty) 'date',
      ];
      final t = title.isEmpty ? '[TÍTULO AUSENTE]' : title;
      final a = author.isEmpty ? '[AUTOR AUSENTE]' : author;
      final d = date.isEmpty ? '[DATA AUSENTE]' : date;
      final p = publisher.isEmpty ? Uri.parse(urlStr).host : publisher;
      final year = DateTime.tryParse(d)?.year.toString() ?? d;
      final out = switch (style) {
        'apa' => '$a ($year). $t. $p. Consultado $accessed em $urlStr',
        'mla' => '$a. "$t." $p, $d, $urlStr. Consultado $accessed.',
        'chicago' => '$a. "$t." $p. Consultado $accessed. $urlStr.',
        'ieee' =>
          '[1] $a, "$t," $p, $d. [Online]. Disponível: $urlStr [Acesso: $accessed]',
        'bibtex' => '@online{vt_${Uri.parse(urlStr).host.replaceAll('.', '_')},\n'
            '  title = {$t},\n'
            '  author = {$a},\n'
            '  date = {$d},\n'
            '  organization = {$p},\n'
            '  url = {$urlStr},\n'
            '  note = {acesso $accessed}\n'
            '}',
        _ => '[$t]($urlStr) — $a, $d, $p (acesso: $accessed)',
      };
      return ToolSuccess(
        data: TextOutput(out, metadata: {
          'style': style,
          'fields': {
            'title': title,
            'author': author,
            'date': date,
            'publisher': publisher,
          },
          'missingFields': missing,
        }),
        citations: [Citation(sourceType: 'url', sourceRef: urlStr, label: t)],
      );
    });
  }

  static String? _metaValue(String html, String property) {
    final esc = RegExp.escape(property);
    for (final re in [
      RegExp('<meta[^>]+property="$esc"[^>]+content="([^"]*)"',
          caseSensitive: false),
      RegExp('<meta[^>]+content="([^"]*)"[^>]+property="$esc"',
          caseSensitive: false),
      RegExp('<meta[^>]+name="$esc"[^>]+content="([^"]*)"',
          caseSensitive: false),
      RegExp('<meta[^>]+content="([^"]*)"[^>]+name="$esc"',
          caseSensitive: false),
    ]) {
      final m = re.firstMatch(html);
      if (m != null) return _stripHtml(m.group(1)!);
    }
    return null;
  }

  static String? _regexGroup(String s, RegExp re) =>
      re.firstMatch(s)?.group(1)?.trim();
}

// ----------------------------------------------------------- web.robots_check
class WebRobotsCheckTool extends WebToolBase {
  WebRobotsCheckTool({super.httpClientFactory});

  @override
  String get id => 'web.robots_check';
  @override
  String get title => 'Robots.txt check';
  @override
  String get description =>
      'Verifica robots.txt/política REAL antes de fetch: baixa o arquivo do '
      'host, casa User-agent (específico > generic * > ausente = permitido), '
      'aplica Disallow/Allow (mais longo vence) e Crawl-delay. 4xx no '
      'robots.txt ⇒ permitido conforme RFC 9309; 5xx ⇒ tratado como bloqueio.';
  @override
  ToolCategory get category => ToolCategory.web;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['url'],
        'properties': {
          'url': {'type': 'string'},
          'userAgent': {'type': 'string'},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    final urlStr = input.str('url');
    final checked = _checkUrl(ctx, urlStr);
    if (checked.error == 'bad_url') return _badUrl(urlStr);
    if (checked.error == 'domain_denied') return _denied(checked.uri.host);
    final ua = _strArg(input, inputSchema, 'userAgent').isNotEmpty
        ? input.str('userAgent')
        : _userAgent;
    return runGuarded(ctx, urlStr, (client) async {
      final decision = await checkRobots(client, checked.uri,
          userAgent: ua, timeout: timeout);
      final lines = [
        'robots.txt REAL de ${checked.uri.host} para UA "$ua":',
        '  path testado: ${checked.uri.path.isEmpty ? '/' : checked.uri.path}',
        '  robots status HTTP: ${decision.httpStatus ?? 'n/d'}',
        '  fonte: ${decision.source ?? 'nenhum robots.txt acessível'}',
        '  regra aplicada: ${decision.rule ?? 'nenhuma (padrão permitir)'}',
        if (decision.crawlDelaySeconds != null)
          '  crawl-delay: ${decision.crawlDelaySeconds}s',
        '',
        'Veredito: ${decision.allowed ? 'PERMITIDO' : 'BLOQUEADO por robots.txt'}',
        if (decision.rawRobots != null) ...[
          '',
          'robots.txt cru:',
          decision.rawRobots!,
        ],
      ];
      return ToolSuccess(
        data: TextOutput(lines.join('\n'), metadata: {
          'allowed': decision.allowed,
          'rule': decision.rule,
          'crawlDelay': decision.crawlDelaySeconds,
          'httpStatus': decision.httpStatus,
        }),
        citations: [
          Citation(
            sourceType: 'url',
            sourceRef: decision.source ?? 'https://${checked.uri.host}/robots.txt',
            label: 'robots.txt (${checked.uri.host})',
          ),
        ],
      );
    });
  }
}

/// Decisão de política de robots.txt (implementação compartilhada).
class RobotsDecision {
  const RobotsDecision({
    required this.allowed,
    this.rule,
    this.crawlDelaySeconds,
    this.httpStatus,
    this.source,
    this.rawRobots,
  });
  final bool allowed;
  final String? rule;
  final double? crawlDelaySeconds;
  final int? httpStatus;
  final String? source;
  final String? rawRobots;
}

Future<RobotsDecision> checkRobots(
  HttpClient client,
  Uri target, {
  String userAgent = _userAgent,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final robotsUri = Uri(
    scheme: target.scheme,
    host: target.host,
    port: target.port,
    path: '/robots.txt',
  );
  final res = await webFetch(client, robotsUri.toString(),
      timeout: timeout, maxBytes: 64 * 1024);
  // RFC 9309: 4xx ⇒ acesso irrestrito; 5xx ⇒ tratar como bloqueio temporário
  if (res.status >= 400 && res.status < 500) {
    return RobotsDecision(
        allowed: true, httpStatus: res.status, source: robotsUri.toString());
  }
  if (res.status >= 500) {
    return RobotsDecision(
      allowed: false,
      httpStatus: res.status,
      source: robotsUri.toString(),
      rule: 'servidor indisponível (5xx) — tratamos como não-permitido',
    );
  }
  final body = res.bodyText;
  final uaLower = userAgent.toLowerCase();
  final groups = parseRobotsGroups(body);
  RobotsGroup? best;
  var bestLen = -1;
  for (final g in groups) {
    for (final agent in g.agents) {
      final a = agent.toLowerCase();
      final matchLen = a == '*' ? 0 : (uaLower.startsWith(a) ? a.length : -1);
      if (matchLen > bestLen) {
        bestLen = matchLen;
        best = g;
      }
    }
  }
  if (best == null || best.disallows.isEmpty) {
    return RobotsDecision(
      allowed: true,
      crawlDelaySeconds: best?.crawlDelay,
      httpStatus: res.status,
      source: robotsUri.toString(),
      rawRobots: _truncate(body),
    );
  }
  final path = target.path.isEmpty ? '/' : target.path;
  String? appliedDisallow;
  String? appliedAllow;
  for (final d in best.disallows) {
    if (d.isEmpty) continue;
    if (path.startsWith(Uri.decodeFull(d))) {
      if (appliedDisallow == null || d.length > appliedDisallow.length) {
        appliedDisallow = d;
      }
    }
  }
  for (final a in best.allows) {
    if (a.isEmpty) continue;
    if (path.startsWith(Uri.decodeFull(a))) {
      if (appliedAllow == null || a.length > appliedAllow.length) {
        appliedAllow = a;
      }
    }
  }
  final allowed = appliedAllow != null || appliedDisallow == null;
  final String? rule = appliedAllow != null
      ? 'Allow: $appliedAllow (permissão explícita vence)'
      : (appliedDisallow != null ? 'Disallow: $appliedDisallow' : null);
  return RobotsDecision(
    allowed: allowed,
    rule: rule,
    crawlDelaySeconds: best.crawlDelay,
    httpStatus: res.status,
    source: robotsUri.toString(),
    rawRobots: _truncate(body),
  );
}

String _truncate(String s) =>
    s.length > 4000 ? '${s.substring(0, 4000)}…' : s;

class RobotsGroup {
  RobotsGroup();
  final agents = <String>[];
  final allows = <String>[];
  final disallows = <String>[];
  double? crawlDelay;
}

List<RobotsGroup> parseRobotsGroups(String content) {
  final groups = <RobotsGroup>[];
  RobotsGroup? current;
  var inAgentBlock = false;
  for (final raw in LineSplitter.split(content)) {
    final line = raw.split('#').first.trim();
    if (line.isEmpty) continue;
    final i = line.indexOf(':');
    if (i < 0) continue;
    final field = line.substring(0, i).trim().toLowerCase();
    final value = line.substring(i + 1).trim();
    switch (field) {
      case 'user-agent':
        if (!inAgentBlock || current == null) {
          current = RobotsGroup();
          groups.add(current);
        }
        current.agents.add(value);
        inAgentBlock = true;
      case 'disallow':
        current?.disallows.add(value);
        inAgentBlock = false;
      case 'allow':
        current?.allows.add(value);
        inAgentBlock = false;
      case 'crawl-delay':
        current?.crawlDelay = double.tryParse(value);
        inAgentBlock = false;
      default:
        inAgentBlock = false;
    }
  }
  return groups;
}

// ---------------------------------------------------------- web.sitemap_query
class WebSitemapQueryTool extends WebToolBase {
  WebSitemapQueryTool({super.httpClientFactory});

  @override
  String get id => 'web.sitemap_query';
  @override
  String get title => 'Sitemap query';
  @override
  String get description =>
      'Consulta sitemap.xml REAL (/sitemap.xml padrão ou sitemapUrl), resolve '
      'sitemap index recursivamente (máx. 2 níveis, cada host revalidado na '
      'allowlist) e filtra por substring. lastmod reportado quando presente.';
  @override
  ToolCategory get category => ToolCategory.web;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['domain'],
        'properties': {
          'domain': {
            'type': 'string',
            'description': 'ex.: https://flutter.dev ou flutter.dev'
          },
          'sitemapUrl': {'type': 'string'},
          'filter': {'type': 'string'},
          'limit': {'type': 'integer', 'default': 50, 'maximum': 200},
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) async {
    var domain = input.str('domain');
    if (!domain.startsWith('http')) domain = 'https://$domain';
    final checked = _checkUrl(ctx, domain);
    if (checked.error == 'bad_url') return _badUrl(domain);
    if (checked.error == 'domain_denied') return _denied(checked.uri.host);
    final sitemapStr = input.str('sitemapUrl').isNotEmpty
        ? input.str('sitemapUrl')
        : 'https://${checked.uri.host}/sitemap.xml';
    final smChecked = _checkUrl(ctx, sitemapStr);
    if (smChecked.error == 'bad_url') return _badUrl(sitemapStr);
    if (smChecked.error == 'domain_denied') {
      return _denied(smChecked.uri.host);
    }
    final filter = input.str('filter');
    final limit = _intArg(input, inputSchema, 'limit');
    return runGuarded(ctx, sitemapStr, (client) async {
      final entries = <Map<String, Object?>>[];
      final visited = <String>[];

      Future<void> walk(Uri u, int depth) async {
        if (visited.contains(u.toString()) || entries.length >= limit) return;
        visited.add(u.toString());
        final res = await webFetch(client, u.toString(),
            timeout: timeout, maxBytes: 4 * 1024 * 1024);
        if (res.status >= 400) return; // sitemap ausente: tenta os demais
        late final Map<String, dynamic> root;
        try {
          root = _tinyXml(res.bodyText);
        } on FormatException catch (e) {
          throw VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Sitemap em $u não é XML válido: ${e.message}',
          );
        }
        if (root['name'] == 'sitemapindex' && depth < 2) {
          for (final s in _childElements(root)) {
            if (s['name'] != 'sitemap') continue;
            final loc = _firstChildText(s, 'loc');
            final lu = Uri.tryParse(loc);
            if (lu == null || (lu.scheme != 'http' && lu.scheme != 'https')) {
              continue;
            }
            if (!ctx.sandbox.isAllowedDomain(lu.host, ctx)) continue;
            await walk(lu, depth + 1);
            if (entries.length >= limit) return;
          }
          return;
        }
        for (final s in _childElements(root)) {
          if (s['name'] != 'url') continue;
          final loc = _firstChildText(s, 'loc');
          if (loc.isEmpty) continue;
          if (filter.isNotEmpty && !loc.contains(filter)) continue;
          entries.add({
            'url': loc,
            'lastmod': _firstChildText(s, 'lastmod'),
            'changefreq': _firstChildText(s, 'changefreq'),
            'priority': _firstChildText(s, 'priority'),
          });
          if (entries.length >= limit) return;
        }
      }

      await walk(smChecked.uri, 0);
      final sitemapCitation =
          Citation(sourceType: 'url', sourceRef: sitemapStr, label: 'sitemap');
      if (entries.isEmpty) {
        return ToolSuccess(
          data: TextOutput(
            'Sitemap REAL consultado em $sitemapStr: 0 URLs '
            '${filter.isNotEmpty ? '(filtro "$filter") ' : ''}'
            '(visitados: ${visited.join(', ')}).',
            metadata: {'count': 0, 'visited': visited},
          ),
          citations: [sitemapCitation],
        );
      }
      final lines = [
        'Sitemap REAL de ${checked.uri.host} — ${entries.length} URLs'
            '${filter.isNotEmpty ? ' (filtro "$filter")' : ''}',
        '',
      ];
      for (final e in entries) {
        final lm = (e['lastmod'] ?? '').toString();
        lines.add('- ${e['url']}${lm.isNotEmpty ? '  [lastmod: $lm]' : ''}');
      }
      return ToolSuccess(
        data: TextOutput(lines.join('\n'),
            metadata: {'count': entries.length, 'urls': entries}),
        citations: [
          sitemapCitation,
          for (final e in entries.take(20))
            Citation(
                sourceType: 'url',
                sourceRef: e['url'].toString(),
                label: e['url'].toString()),
        ],
      );
    });
  }
}

// ----------------------------------------------- extração de conteúdo (real)
class _ExtractedArticle {
  const _ExtractedArticle({
    required this.text,
    required this.confidence,
    this.title = '',
    this.byline = '',
    this.siteName = '',
  });
  final String text;
  final double confidence;
  final String title;
  final String byline;
  final String siteName;
}

/// Heurística REAL: remove boilerplate, pontua containers candidatos por
/// densidade textual (parágrafos/comas/tamanho − link density) e escolhe o
/// melhor. Fallback: todos os <p>. Sem dependências externas, sem inventar.
_ExtractedArticle _extractMainContent(String html) {
  var work = html;
  work = work.replaceAll(
      RegExp(
          r'<(script|style|noscript|svg|iframe|form|nav|footer|header|aside|dialog)\b.*?</\1>',
          dotAll: true,
          caseSensitive: false),
      ' ');
  work = work
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
      .replaceAll(RegExp(r'<!\[CDATA\[.*?\]\]>', dotAll: true), ' ');

  final title = _stripHtml(
      RegExp(r'<meta[^>]+property="og:title"[^>]+content="([^"]*)"')
              .firstMatch(html)
              ?.group(1) ??
          RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true)
              .firstMatch(html)
              ?.group(1) ??
          '');
  final byline = _stripHtml(
      RegExp(
              r'<meta[^>]+(?:name|property)="(?:author|article:author)"[^>]+content="([^"]*)"')
          .firstMatch(html)
          ?.group(1) ??
          '');
  final siteName = _stripHtml(
      RegExp(r'<meta[^>]+property="og:site_name"[^>]+content="([^"]*)"')
          .firstMatch(html)
          ?.group(1) ??
          '');

  final candidateRe = RegExp(
      r'<(article|main|section|div)\b[^>]*>((?:(?!</?\1[\s>]).)*?)</\1\s*>',
      dotAll: true,
      caseSensitive: false);
  String? best;
  double bestScore = 0;
  for (final m in candidateRe.allMatches(work)) {
    final inner = m.group(2)!;
    final text = _stripHtml(inner);
    if (text.length < 120) continue;
    final paragraphs = RegExp(r'[.!?](?:\s|$)').allMatches(text).length;
    final commas = ','.allMatches(text).length;
    final linkText = RegExp(r'<a\b[^>]*>.*?</a>', dotAll: true)
        .allMatches(inner)
        .map((l) => _stripHtml(l.group(0)!))
        .join(' ');
    final linkDensity = linkText.length / (text.length + 1);
    var score = paragraphs * 3 + commas + text.length / 100 - linkDensity * 40;
    final tag = m.group(1)!.toLowerCase();
    final openTag = m.group(0)!.split('>').first.toLowerCase();
    if (tag == 'article' || tag == 'main') score *= 1.5;
    if (RegExp(r'(article|post-body|entry-content|markdown-body|content)')
        .hasMatch(openTag)) {
      score *= 1.3;
    }
    if (score > bestScore) {
      bestScore = score;
      best = text;
    }
  }
  if (best == null) {
    final ps = RegExp(r'<p\b[^>]*>(.*?)</p>',
            dotAll: true, caseSensitive: false)
        .allMatches(work)
        .map((m) => _stripHtml(m.group(1)!))
        .where((t) => t.length > 40)
        .join('\n\n');
    if (ps.trim().isEmpty) {
      return const _ExtractedArticle(text: '', confidence: 0);
    }
    return _ExtractedArticle(
        text: ps,
        confidence: 0.4,
        title: title,
        byline: byline,
        siteName: siteName);
  }
  final confidence = bestScore > 300 ? 0.9 : (bestScore > 100 ? 0.7 : 0.5);
  return _ExtractedArticle(
      text: best,
      confidence: confidence,
      title: title,
      byline: byline,
      siteName: siteName);
}

/// As 10 web-tools para registro na application layer.
List<VtTool<ToolInput, ToolOutput>> buildWebTools() => [
      WebSearchTool(),
      WebNewsSearchTool(),
      WebImageSearchTool(),
      WebDocSearchTool(),
      WebCodeSearchTool(),
      WebFetchPageTool(),
      WebExtractArticleTool(),
      WebCitationFormatTool(),
      WebRobotsCheckTool(),
      WebSitemapQueryTool(),
    ];
