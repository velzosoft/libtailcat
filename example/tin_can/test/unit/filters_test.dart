// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/audio/filters.dart';

const _rate = 16000;

Int16List _sine(double frequency) => Int16List.fromList([
  for (var i = 0; i < _rate; i++)
    (10000 * math.sin(2 * math.pi * frequency * i / _rate)).round(),
]);

double _rms(Int16List samples, {int from = 0}) {
  var sum = 0.0;
  for (var i = from; i < samples.length; i++) {
    sum += samples[i] * samples[i].toDouble();
  }
  return math.sqrt(sum / (samples.length - from));
}

/// RMS ratio after the filter, skipping the first 100 ms of settling.
double _gain(double frequency) {
  final input = _sine(frequency);
  final output = Int16List.fromList(input);
  TelephoneFilter().processInPlace(output);
  const settle = _rate ~/ 10;
  return _rms(output, from: settle) / _rms(input, from: settle);
}

void main() {
  group('TelephoneFilter', () {
    test('passes the middle of the voice band', () {
      expect(_gain(1000), greaterThan(0.7));
      expect(_gain(1800), greaterThan(0.7));
    });

    test('cuts below 300 Hz and above 3400 Hz', () {
      expect(_gain(100), lessThan(0.25));
      expect(_gain(6000), lessThan(0.25));
    });

    test('clamps to 16 bits', () {
      final loud = Int16List.fromList([
        for (var i = 0; i < _rate; i++) i.isEven ? 32767 : -32768,
      ]);
      // Would throw or wrap around if the output left the 16-bit range.
      TelephoneFilter().processInPlace(loud);
      expect(loud.every((x) => x >= -32768 && x <= 32767), isTrue);
    });

    test('reset forgets the previous signal', () {
      final filter = TelephoneFilter();
      final first = _sine(1000);
      filter.processInPlace(first);
      filter.reset();
      final impulse = Int16List(64)..[0] = 10000;
      final fresh = Int16List.fromList(impulse);
      TelephoneFilter().processInPlace(fresh);
      filter.processInPlace(impulse);
      expect(impulse, fresh);
    });
  });

  group('Biquad', () {
    test('a low-pass passes DC and a high-pass blocks it', () {
      final low = Biquad.lowPass(1000, 16000);
      final high = Biquad.highPass(1000, 16000);
      var lowOut = 0.0, highOut = 0.0;
      for (var i = 0; i < 2000; i++) {
        lowOut = low.process(1);
        highOut = high.process(1);
      }
      expect(lowOut, closeTo(1, 1e-6));
      expect(highOut, closeTo(0, 1e-6));
    });

    test('a peaking section with 0 dB changes nothing', () {
      final flat = Biquad.peaking(1800, 16000, gainDb: 0);
      for (final x in [1.0, -0.5, 0.25, 0.0, 3.0]) {
        expect(flat.process(x), closeTo(x, 1e-12));
      }
    });
  });
}
