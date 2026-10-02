import 'dart:async';
import 'dart:convert';

import '../../domain/errors/vt_failure.dart';

/// Reassembles DAP `Content-Length` frames from arbitrary stdout chunks.
class DapFramer extends StreamTransformerBase<List<int>, Map<String, Object?>> {
  static const _headerDelimiter = [13, 10, 13, 10];
  static const _maxHeaderBytes = 16 * 1024;
  static const _maxPayloadBytes = 16 * 1024 * 1024;

  @override
  Stream<Map<String, Object?>> bind(Stream<List<int>> stream) {
    late StreamSubscription<List<int>> subscription;
    return Stream<Map<String, Object?>>.multi((output) {
      final buffered = <int>[];

      void fail(String message) {
        buffered.clear();
        output.addError(VtFailure(
          code: VtErrorCode.internalError,
          message: message,
        ));
      }

      void consume(List<int> chunk) {
        buffered.addAll(chunk);
        while (true) {
          var delimiter = -1;
          for (var i = 0; i <= buffered.length - _headerDelimiter.length; i++) {
            var matches = true;
            for (var j = 0; j < _headerDelimiter.length; j++) {
              if (buffered[i + j] != _headerDelimiter[j]) {
                matches = false;
                break;
              }
            }
            if (matches) {
              delimiter = i;
              break;
            }
          }
          if (delimiter < 0) {
            if (buffered.length > _maxHeaderBytes) {
              fail('Debug adapter enviou um header DAP grande demais.');
            }
            return;
          }

          final header = ascii.decode(buffered.take(delimiter).toList(),
              allowInvalid: true);
          final lengthMatch =
              RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false)
                  .firstMatch(header);
          if (lengthMatch == null) {
            fail('Debug adapter enviou frame sem Content-Length.');
            return;
          }
          final length = int.parse(lengthMatch.group(1)!);
          if (length > _maxPayloadBytes) {
            fail('Debug adapter enviou frame acima do limite permitido.');
            return;
          }
          final payloadStart = delimiter + _headerDelimiter.length;
          if (buffered.length < payloadStart + length) return;

          final payload = buffered.sublist(payloadStart, payloadStart + length);
          buffered.removeRange(0, payloadStart + length);
          final Object? decoded;
          try {
            decoded = jsonDecode(utf8.decode(payload));
          } on FormatException catch (error) {
            fail('Debug adapter enviou JSON inválido: ${error.message}');
            return;
          }
          if (decoded is! Map) {
            fail('Debug adapter enviou payload JSON que não é um objeto.');
            return;
          }
          output.add(decoded.cast<String, Object?>());
        }
      }

      subscription = stream.listen(
        consume,
        onError: output.addError,
        onDone: output.close,
      );
      output.onPause = subscription.pause;
      output.onResume = subscription.resume;
      output.onCancel = subscription.cancel;
    });
  }
}
