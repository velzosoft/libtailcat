// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/audio/pluck.dart';

double _rms(Int16List samples, int from, int to) {
  var sum = 0.0;
  for (var i = from; i < to; i++) {
    sum += samples[i] * samples[i].toDouble();
  }
  return math.sqrt(sum / (to - from));
}

void main() {
  group('synthesizePluck', () {
    test('is the same for the same seed and differs for another', () {
      expect(synthesizePluck(seed: 3), synthesizePluck(seed: 3));
      expect(synthesizePluck(seed: 3), isNot(synthesizePluck(seed: 4)));
    });

    test('lasts the requested duration', () {
      expect(synthesizePluck(), hasLength(16000 * 12 ~/ 10));
      expect(
        synthesizePluck(
          duration: const Duration(milliseconds: 250),
          sampleRate: 8000,
        ),
        hasLength(2000),
      );
      expect(synthesizePluck(duration: Duration.zero), isEmpty);
    });

    test('starts loud, dies away and ends at zero', () {
      final samples = synthesizePluck();
      final tenth = samples.length ~/ 10;
      final start = _rms(samples, 0, tenth);
      final end = _rms(samples, samples.length - tenth, samples.length);
      expect(start, greaterThan(1000));
      expect(end, lessThan(start / 4));
      expect(samples.last, 0);
    });

    test('rings near the requested pitch', () {
      final samples = synthesizePluck(frequency: 196);
      // The best-matching lag is the period. Search 40–320 Hz from 50 ms,
      // after the pluck's noise has settled into a tone.
      const from = 800, window = 3200;
      var bestLag = 0;
      var best = double.negativeInfinity;
      for (var lag = 16000 ~/ 320; lag <= 16000 ~/ 40; lag++) {
        var sum = 0.0;
        for (var i = from; i < from + window; i++) {
          sum += samples[i] * samples[i + lag].toDouble();
        }
        if (sum > best) {
          best = sum;
          bestLag = lag;
        }
      }
      expect(16000 / bestLag, closeTo(196, 196 * 0.1));
    });
  });
}
