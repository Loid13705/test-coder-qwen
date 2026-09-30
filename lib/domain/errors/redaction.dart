/// Redação de secrets em logs, chat e audit (spec §SEGURANÇA: nunca logar raw).
library;

/// Substitui padrões conhecidos de tokens/chaves/senhas por `[REDACTED:*]`.
class SecretRedactor {
  const SecretRedactor();

  static final _privateKey = RegExp(
      '(?i)-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY -----'
      '[\\s\\S]*?-----END (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY -----');

  static final _bearer = RegExp(
      '(?i)(authorization\\s*[:=]\\s*)bearer\\s+[a-z0-9._\\-]+');

  // key = "value" | key = 'value' | key = bareword
  static final _kv = RegExp(
      '(?i)'
      '\\b(password|passwd|secret|api[_-]?key|access[_-]?token|client[_-]?secret)\\b'
      '\\s*[:=]\\s*'
      '(' + '"' + '[^"' + '"]*"|\'[^\']*\'|\\S+)');

  static final _urlAuth = RegExp('(?i)(https?://)[^\\s/:@]+:[^\\s@]+@');

  static const _singleTokenPatterns = <String, Pattern>{
    'aws_key': r'\bAKIA[0-9A-Z]{16}\b',
    'openai_key': r'\bsk-[A-Za-z0-9_\-]{16,}\b',
    'github_token': r'\bgh[pousr]_[A-Za-z0-9]{20,}\b',
    'slack_token': r'\bxox[baprs]-[A-Za-z0-9\-]{10,}\b',
    'google_key': r'\bAIza[0-9A-Za-z_\-]{30,}\b',
    'jwt': r'\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}\b',
  };

  static final _compiledTokens = _singleTokenPatterns.map(
      (name, pattern) => MapEntry(name, RegExp(pattern as String)));

  /// Retorna o texto com segredos redigidos.
  String redact(String input) {
    var out =
        input.replaceAllMapped(_privateKey, (m) => '[REDACTED:private_key]');
    out = out.replaceAllMapped(
        _bearer, (m) => '${m.group(1)}Bearer [REDACTED:token]');
    for (final entry in _compiledTokens.entries) {
      out = out.replaceAllMapped(
          entry.value, (m) => '[REDACTED:${entry.key}]');
    }
    out = out.replaceAllMapped(
        _kv, (m) => '${m.group(1)}=[REDACTED:${m.group(1)}]');
    out = out.replaceAllMapped(
        _urlAuth, (m) => '${m.group(1)}[REDACTED:user:pass]@');
    return out;
  }

  /// Detecta presença de padrões de secret (usado por secret.scan e pré-commit).
  List<String> detect(String input) {
    final found = <String>[];
    if (_privateKey.hasMatch(input)) found.add('private_key');
    if (_bearer.hasMatch(input)) found.add('bearer');
    if (_kv.hasMatch(input)) found.add('kv_secret');
    if (_urlAuth.hasMatch(input)) found.add('url_basic_auth');
    for (final entry in _compiledTokens.entries) {
      if (entry.value.hasMatch(input)) found.add(entry.key);
    }
    return found;
  }
}
