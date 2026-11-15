// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/audio/mixer.dart';

void main() {
  group('Mixer', () {
    test('passes voice through unchanged while idle', () {
      final mixer = Mixer();
      final voice = Int16List.fromList([1, -2, 3, -4]);
      expect(mixer.isIdle, isTrue);
      expect(mixer.mix(voice, 4), voice);
      expect(mixer.mix(null, 3), [0, 0, 0]);
    });

    test('plays a one-shot across calls until it ends', () {
      final mixer = Mixer()..play(Int16List.fromList([10, 20, 30, 40, 50]));
      expect(mixer.isIdle, isFalse);
      expect(mixer.mix(Int16List.fromList([1, 1, 1]), 3), [11, 21, 31]);
      expect(mixer.mix(null, 3), [40, 50, 0]);
      expect(mixer.isIdle, isTrue);
      expect(mixer.mix(null, 2), [0, 0]);
    });

    test('overlaps one-shots and applies their gain', () {
      final mixer = Mixer()
        ..play(Int16List.fromList([100, 100]))
        ..play(Int16List.fromList([10, 10, 10]), gain: 0.5);
      expect(mixer.mix(null, 4), [105, 105, 5, 0]);
    });

    test('clamps the sum to 16 bits', () {
      final mixer = Mixer()
        ..play(Int16List.fromList([30000, -30000]))
        ..play(Int16List.fromList([30000, -30000]));
      expect(mixer.mix(Int16List.fromList([1000, -1000]), 2), [32767, -32768]);
    });

    test('clear stops every one-shot', () {
      final mixer = Mixer()..play(Int16List.fromList([5, 5, 5]));
      mixer.clear();
      expect(mixer.isIdle, isTrue);
      expect(mixer.mix(null, 2), [0, 0]);
    });
  });
}
