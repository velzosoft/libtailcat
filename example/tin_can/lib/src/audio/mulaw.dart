// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:typed_data';

/// G.711 μ-law: 16-bit samples in 8 logarithmic bits. Half of PCM16's size
/// and no codec library needed.
abstract final class MuLaw {
  static const int _bias = 0x84;
  static const int _clip = 32635;

  static final Int16List _decodeTable = Int16List.fromList([
    for (var u = 0; u < 256; u++) _decode(u),
  ]);

  static int encodeSample(int pcm16) {
    var sample = pcm16;
    final sign = sample < 0 ? 0x80 : 0x00;
    if (sample < 0) sample = -sample;
    if (sample > _clip) sample = _clip;
    sample += _bias;

    // The exponent is the position of the highest set bit above bit 7.
    var exponent = 7;
    for (var mask = 0x4000; (sample & mask) == 0 && exponent > 0; mask >>= 1) {
      exponent--;
    }
    final mantissa = (sample >> (exponent + 3)) & 0x0F;
    return ~(sign | (exponent << 4) | mantissa) & 0xFF;
  }

  static int decodeSample(int ulaw) => _decodeTable[ulaw & 0xFF];

  static Uint8List encode(Int16List pcm) {
    final out = Uint8List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      out[i] = encodeSample(pcm[i]);
    }
    return out;
  }

  static Int16List decode(Uint8List ulaw) {
    final out = Int16List(ulaw.length);
    for (var i = 0; i < ulaw.length; i++) {
      out[i] = _decodeTable[ulaw[i]];
    }
    return out;
  }

  static int _decode(int ulaw) {
    final u = ~ulaw & 0xFF;
    final sign = u & 0x80;
    final exponent = (u >> 4) & 0x07;
    final mantissa = u & 0x0F;
    final magnitude = (((mantissa << 3) + _bias) << exponent) - _bias;
    return sign != 0 ? -magnitude : magnitude;
  }
}
