import 'package:techvt/domain/errors/redaction.dart';

void main() {
  const r = SecretRedactor();
  final cases = <String, String>{
    'api_key = "sk-abcdefghijklmnopqrstuvwx"': 'openai',
    "password: 'hunter2'": 'kv',
    'Authorization: Bearer abc123.def-456': 'bearer',
    'https://user:pass@example.com/x': 'urlauth',
    'AKIAABCDEFGHIJKLMNOP': 'aws',
    'ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx': 'github',
    '-----BEGIN RSA PRIVATE KEY-----\nAAA\n-----END RSA PRIVATE KEY-----':
        'privkey',
  };
  cases.forEach((input, label) {
    final red = r.redact(input);
    final det = r.detect(input);
    print('$label -> redacted="$red" detected=$det');
  });
}
