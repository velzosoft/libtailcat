// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/audio/mulaw.dart';

void main() {
  group('MuLaw', () {
    test('matches the G.711 reference values', () {
      expect(MuLaw.encodeSample(0), 0xFF);
      expect(MuLaw.decodeSample(0xFF), 0);
      expect(MuLaw.decodeSample(0x80), 32124);
      expect(MuLaw.decodeSample(0x00), -32124);
      expect(MuLaw.encodeSample(32767), 0x80);
      expect(MuLaw.encodeSample(-32768), 0x00);
    });

    test('round-trips every 16-bit sample within half a step', () {
      for (var x = -32768; x <= 32767; x++) {
        final y = MuLaw.decodeSample(MuLaw.encodeSample(x));
        final bound = math.max(8, x.abs() ~/ 16);
        expect((x - y).abs(), lessThanOrEqualTo(bound), reason: 'sample $x');
      }
    });

    test('keeps the sign and the order of samples', () {
      for (var x = 1; x <= 32767; x += 97) {
        expect(MuLaw.decodeSample(MuLaw.encodeSample(x)), isNonNegative);
        expect(MuLaw.decodeSample(MuLaw.encodeSample(-x)), isNonPositive);
      }
      var previous = -32768;
      for (var u = 0x00; u <= 0x7F; u++) {
        final value = MuLaw.decodeSample(u);
        expect(value, greaterThan(previous), reason: 'byte $u');
        previous = value;
      }
    });

    test('encodes and decodes whole buffers', () {
      final pcm = Int16List.fromList([0, 1000, -1000, 32767, -32768, 12]);
      final encoded = MuLaw.encode(pcm);
      expect(encoded, hasLength(pcm.length));
      expect(encoded, [for (final x in pcm) MuLaw.encodeSample(x)]);
      final decoded = MuLaw.decode(encoded);
      expect(decoded, [for (final u in encoded) MuLaw.decodeSample(u)]);
    });
  });
}
