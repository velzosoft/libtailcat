// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:math' as math;
import 'dart:typed_data';

import 'voice_format.dart';

/// A plucked string via Karplus–Strong, so the app ships no sound files.
///
/// A one-period delay line starts as noise; each step feeds back the decayed
/// average of the two oldest samples, a low-pass that leaves the fundamental.
/// The last 30 ms fade out to avoid a click.
Int16List synthesizePluck({
  double frequency = 196.0,
  Duration duration = const Duration(milliseconds: 1200),
  int sampleRate = VoiceFormat.sampleRate,
  double decay = 0.996,
  double amplitude = 0.6,
  int seed = 1,
}) {
  final length = duration.inMicroseconds * sampleRate ~/ 1000000;
  final out = Int16List(length);
  if (length == 0) return out;

  final period = math.max(2, (sampleRate / frequency).round());
  final random = math.Random(seed);
  final line = Float64List(period);
  for (var i = 0; i < period; i++) {
    line[i] = random.nextDouble() * 2 - 1;
  }

  final fadeSamples = math.min(length, sampleRate * 30 ~/ 1000);
  final fadeStart = length - fadeSamples;
  var index = 0;
  for (var i = 0; i < length; i++) {
    final next = (index + 1) % period;
    final current = line[index];
    line[index] = decay * 0.5 * (current + line[next]);
    index = next;

    var sample = current * amplitude;
    if (i >= fadeStart) sample *= (length - 1 - i) / fadeSamples;
    out[i] = (sample * 32767).round().clamp(-32768, 32767);
  }
  return out;
}
