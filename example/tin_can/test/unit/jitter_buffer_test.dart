// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/audio/jitter_buffer.dart';

/// A frame tagged with [seq] in its first sample.
Int16List _frame(int seq) => Int16List(4)..[0] = seq.toSigned(16);

/// The sequence numbers played over [turns]; `null` for silence.
List<int?> _play(JitterBuffer buffer, int turns) => [
  for (var i = 0; i < turns; i++) buffer.pop()?[0].toUnsigned(16),
];

void main() {
  group('JitterBuffer', () {
    test('fills to its depth, then plays in order', () {
      final buffer = JitterBuffer(depthFrames: 3);
      buffer.push(10, _frame(10));
      buffer.push(11, _frame(11));
      expect(buffer.pop(), isNull);
      expect(buffer.isPlaying, isFalse);
      expect(buffer.concealed, 0);
      buffer.push(12, _frame(12));
      expect(buffer.depth, 3);
      expect(buffer.depthDuration, const Duration(milliseconds: 60));
      expect(_play(buffer, 3), [10, 11, 12]);
      expect(buffer.isPlaying, isTrue);
      expect(buffer.played, 3);
    });

    test('puts frames that arrive out of order back in order', () {
      final buffer = JitterBuffer(depthFrames: 3);
      for (final seq in [2, 0, 1, 4, 3]) {
        expect(buffer.push(seq, _frame(seq)), isTrue);
      }
      expect(_play(buffer, 5), [0, 1, 2, 3, 4]);
      expect(buffer.lost, 0);
    });

    test('plays silence for a missing frame and counts it lost', () {
      final buffer = JitterBuffer(depthFrames: 3);
      for (final seq in [0, 1, 3, 4]) {
        buffer.push(seq, _frame(seq));
      }
      expect(_play(buffer, 5), [0, 1, null, 3, 4]);
      expect(buffer.lost, 1);
      expect(buffer.concealed, 1);
      expect(buffer.played, 4);
    });

    test('drops a frame that arrives after its turn', () {
      final buffer = JitterBuffer(depthFrames: 2);
      for (final seq in [0, 2, 3]) {
        buffer.push(seq, _frame(seq));
      }
      expect(_play(buffer, 2), [0, null]);
      expect(buffer.push(1, _frame(1)), isFalse);
      expect(buffer.late, 1);
      expect(_play(buffer, 2), [2, 3]);
    });

    test('drops a duplicate', () {
      final buffer = JitterBuffer(depthFrames: 2);
      expect(buffer.push(5, _frame(5)), isTrue);
      expect(buffer.push(5, _frame(5)), isFalse);
      expect(buffer.duplicates, 1);
      expect(buffer.depth, 1);
    });

    test('goes back to filling when it runs dry, and resumes', () {
      final buffer = JitterBuffer(depthFrames: 2);
      buffer
        ..push(0, _frame(0))
        ..push(1, _frame(1));
      expect(_play(buffer, 3), [0, 1, null]);
      expect(buffer.underruns, 1);
      expect(buffer.concealed, 1);
      expect(buffer.isPlaying, isFalse);

      // Silence while it fills again counts as nothing.
      expect(_play(buffer, 5), everyElement(isNull));
      expect(buffer.concealed, 1);

      // The next talk spurt carries on counting.
      buffer.push(2, _frame(2));
      expect(buffer.pop(), isNull);
      buffer.push(3, _frame(3));
      expect(_play(buffer, 2), [2, 3]);
    });

    test('treats an already played frame as late while filling', () {
      final buffer = JitterBuffer(depthFrames: 1);
      buffer.push(7, _frame(7));
      expect(_play(buffer, 2), [7, null]);
      expect(buffer.push(7, _frame(7)), isFalse);
      expect(buffer.late, 1);
    });

    test('takes a sender that starts counting again', () {
      final buffer = JitterBuffer(depthFrames: 1);
      buffer.push(5000, _frame(5000));
      expect(_play(buffer, 2), [5000, null]);
      expect(buffer.push(0, _frame(0)), isTrue);
      expect(_play(buffer, 1), [0]);
    });

    test('wraps around after sequence number 65535', () {
      final buffer = JitterBuffer(depthFrames: 3);
      for (final seq in [65535, 65534, 0, 1]) {
        buffer.push(seq, _frame(seq));
      }
      expect(_play(buffer, 4), [65534, 65535, 0, 1]);
      expect(buffer.push(65535, _frame(65535)), isFalse);
      expect(buffer.late, 1);
    });

    test('drops the oldest frames when it overflows', () {
      final buffer = JitterBuffer(depthFrames: 2, maxFrames: 4);
      for (var seq = 0; seq < 6; seq++) {
        buffer.push(seq, _frame(seq));
      }
      expect(buffer.depth, 4);
      expect(buffer.overflows, 2);
      expect(_play(buffer, 4), [2, 3, 4, 5]);
    });

    test('reset empties the buffer and its counters', () {
      final buffer = JitterBuffer(depthFrames: 1);
      buffer
        ..push(1, _frame(1))
        ..push(1, _frame(1));
      buffer.pop();
      buffer.reset();
      expect(buffer.depth, 0);
      expect(buffer.isPlaying, isFalse);
      expect(buffer.played, 0);
      expect(buffer.duplicates, 0);
      expect(buffer.push(1, _frame(1)), isTrue);
    });
  });
}
