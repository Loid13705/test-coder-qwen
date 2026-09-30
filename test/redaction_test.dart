import 'package:techvt/domain/errors/redaction.dart';

void main() {
  const r = SecretRedactor();
  assert(r.detect('api_key = "sk-abcdefghijklmnopqrstuvwx"').isNotEmpty);
  assert(r.redact('password: hunter2').contains('[REDACTED'));
  print('redaction smoke test OK');
}
