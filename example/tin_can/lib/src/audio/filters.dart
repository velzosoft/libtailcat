// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:math' as math;
import 'dart:typed_data';

/// A biquad section (RBJ Audio EQ Cookbook), in transposed direct form II.
final class Biquad {
  Biquad._(double b0, double b1, double b2, double a0, double a1, double a2)
    : _b0 = b0 / a0,
      _b1 = b1 / a0,
      _b2 = b2 / a0,
      _a1 = a1 / a0,
      _a2 = a2 / a0;

  factory Biquad.highPass(
    double cutoff,
    double sampleRate, {
    double q = 0.7071,
  }) {
    final (cos, alpha) = _prepare(cutoff, sampleRate, q);
    return Biquad._(
      (1 + cos) / 2,
      -(1 + cos),
      (1 + cos) / 2,
      1 + alpha,
      -2 * cos,
      1 - alpha,
    );
  }

  factory Biquad.lowPass(
    double cutoff,
    double sampleRate, {
    double q = 0.7071,
  }) {
    final (cos, alpha) = _prepare(cutoff, sampleRate, q);
    return Biquad._(
      (1 - cos) / 2,
      1 - cos,
      (1 - cos) / 2,
      1 + alpha,
      -2 * cos,
      1 - alpha,
    );
  }

  factory Biquad.peaking(
    double centre,
    double sampleRate, {
    required double gainDb,
    double q = 1.0,
  }) {
    final (cos, alpha) = _prepare(centre, sampleRate, q);
    final a = math.pow(10, gainDb / 40).toDouble();
    return Biquad._(
      1 + alpha * a,
      -2 * cos,
      1 - alpha * a,
      1 + alpha / a,
      -2 * cos,
      1 - alpha / a,
    );
  }

  final double _b0, _b1, _b2, _a1, _a2;
  double _z1 = 0, _z2 = 0;

  double process(double x) {
    final y = _b0 * x + _z1;
    _z1 = _b1 * x - _a1 * y + _z2;
    _z2 = _b2 * x - _a2 * y;
    return y;
  }

  void reset() {
    _z1 = 0;
    _z2 = 0;
  }

  static (double cos, double alpha) _prepare(
    double frequency,
    double sampleRate,
    double q,
  ) {
    final w0 = 2 * math.pi * frequency / sampleRate;
    return (math.cos(w0), math.sin(w0) / (2 * q));
  }
}

/// The 300–3400 Hz telephone band, plus a +4 dB peak at 1.8 kHz for the boxy
/// colour of a can.
final class TelephoneFilter {
  TelephoneFilter({double sampleRate = 16000})
    : _sections = [
        Biquad.highPass(lowCutoff, sampleRate),
        Biquad.highPass(lowCutoff, sampleRate),
        Biquad.lowPass(highCutoff, sampleRate),
        Biquad.lowPass(highCutoff, sampleRate),
        Biquad.peaking(1800, sampleRate, gainDb: 4),
      ];

  static const lowCutoff = 300.0;

  static const highCutoff = 3400.0;

  final List<Biquad> _sections;

  void processInPlace(Int16List samples) {
    for (var i = 0; i < samples.length; i++) {
      var y = samples[i].toDouble();
      for (final section in _sections) {
        y = section.process(y);
      }
      samples[i] = y.round().clamp(-32768, 32767);
    }
  }

  void reset() {
    for (final section in _sections) {
      section.reset();
    }
  }
}
