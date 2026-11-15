// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/audio/framer.dart';

Uint8List _pcm(int start, int count) {
  final data = ByteData(count * 2);
  for (var i = 0; i < count; i++) {
    data.setInt16(i * 2, start + i - 500, Endian.little);
  }
  return data.buffer.asUint8List();
}

List<int> _expected(int start, int count) => [
  for (var i = 0; i < count; i++) start + i - 500,
];

void main() {
  group('PcmFramer', () {
    test('returns exact frames and keeps the rest for later', () {
      final framer = PcmFramer(frameSamples: 4);
      final bytes = _pcm(0, 10);
      final first = framer.add(Uint8List.sublistView(bytes, 0, 14));
      expect(first, hasLength(1));
      expect(first.single, _expected(0, 4));
      final second = framer.add(Uint8List.sublistView(bytes, 14));
      expect(second, hasLength(1));
      expect(second.single, _expected(4, 4));
      // Two samples are left over; four more complete the next frame.
      expect(framer.add(_pcm(10, 2)), [_expected(8, 4)]);
    });

    test('joins samples split across chunks of odd sizes', () {
      final framer = PcmFramer(frameSamples: 320);
      final bytes = _pcm(0, 320 * 5);
      final frames = <Int16List>[];
      var offset = 0;
      for (var size = 1; offset < bytes.length; size = size % 37 + 1) {
        final end = (offset + size).clamp(0, bytes.length);
        frames.addAll(framer.add(Uint8List.sublistView(bytes, offset, end)));
        offset = end;
      }
      expect(frames, hasLength(5));
      for (var i = 0; i < 5; i++) {
        expect(frames[i], _expected(i * 320, 320));
      }
    });

    test('returns several frames from one large chunk', () {
      final framer = PcmFramer(frameSamples: 320);
      final frames = framer.add(_pcm(0, 320 * 3));
      expect(frames.map((frame) => frame.length), [320, 320, 320]);
      expect(frames.last, _expected(640, 320));
    });

    test('reset drops a partial frame', () {
      final framer = PcmFramer(frameSamples: 4);
      expect(framer.add(_pcm(0, 3)), isEmpty);
      framer.reset();
      expect(framer.add(_pcm(100, 4)), [_expected(100, 4)]);
    });
  });
}
