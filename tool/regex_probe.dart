void main() {
  void probe(String name, RegExp Function() f) {
    try {
      f();
      print('$name: OK');
    } catch (e) {
      print('$name: FAIL -> $e');
    }
  }

  probe('inline (?i)', () => RegExp(r'(?i)abc'));
  probe('caseSensitive:false', () => RegExp('abc', caseSensitive: false));
  probe('\\s', () => RegExp(r'a\sb'));
  probe('[a-z._\\-]', () => RegExp(r'[a-z._\-]+'));
  probe('non-capturing (?:)', () => RegExp(r'(?:abc)'));
  probe('aws \\b..\\b', () => RegExp(r'\bAKIA[0-9A-Z]{16}\b'));
  probe('[\\s\\S]*?', () => RegExp(r'[\s\S]*?'));
}
