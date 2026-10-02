import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:techvt/infrastructure/devtools/dap_framer.dart';

List<int> _frame(Map<String, Object?> payload) {
  final body = utf8.encode(jsonEncode(payload));
  return [
    ...ascii.encode('Content-Length: ${body.length}\r\n\r\n'),
    ...body,
  ];
}

void main() {
  test('reassembles a UTF-8 frame split across byte chunks', () async {
    final bytes = _frame({'event': 'output', 'text': 'Olá, mundo 👋'});
    final split = bytes.indexOf(0xc3);
    final chunks = [
      bytes.sublist(0, split + 1),
      bytes.sublist(split + 1),
    ];

    final frames = await Stream<List<int>>.fromIterable(chunks)
        .transform(DapFramer())
        .toList();

    expect(frames, [
      {'event': 'output', 'text': 'Olá, mundo 👋'},
    ]);
  });

  test('emits multiple frames from a single chunk', () async {
    final bytes = [
      ..._frame({'seq': 1}),
      ..._frame({'seq': 2})
    ];
    final frames =
        await Stream<List<int>>.value(bytes).transform(DapFramer()).toList();

    expect(frames.map((frame) => frame['seq']), [1, 2]);
  });

  test('reports frames without Content-Length', () async {
    await expectLater(
      Stream<List<int>>.value(ascii.encode('X-Header: value\r\n\r\n{}'))
          .transform(DapFramer()),
      emitsError(isA<Exception>()),
    );
  });
}
