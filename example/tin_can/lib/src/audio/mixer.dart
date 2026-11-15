// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:typed_data';

/// Mixes voice with overlapping one-shot sounds (the pluck), clamped to 16
/// bits.
final class Mixer {
  final List<_OneShot> _playing = [];

  bool get isIdle => _playing.isEmpty;

  void play(Int16List samples, {double gain = 1}) {
    if (samples.isEmpty) return;
    _playing.add(_OneShot(samples, gain));
  }

  /// [voice] (silence when `null`) plus the next [length] samples of each
  /// one-shot.
  Int16List mix(Int16List? voice, int length) {
    final out = Int16List(length);
    if (_playing.isEmpty) {
      if (voice != null) out.setRange(0, length.clamp(0, voice.length), voice);
      return out;
    }
    final sum = Float64List(length);
    if (voice != null) {
      for (var i = 0; i < length && i < voice.length; i++) {
        sum[i] = voice[i].toDouble();
      }
    }
    for (final shot in _playing) {
      final take = (shot.samples.length - shot.position).clamp(0, length);
      for (var i = 0; i < take; i++) {
        sum[i] += shot.samples[shot.position + i] * shot.gain;
      }
      shot.position += take;
    }
    _playing.removeWhere((shot) => shot.position >= shot.samples.length);
    for (var i = 0; i < length; i++) {
      out[i] = sum[i].round().clamp(-32768, 32767);
    }
    return out;
  }

  void clear() => _playing.clear();
}

final class _OneShot {
  _OneShot(this.samples, this.gain);

  final Int16List samples;
  final double gain;
  int position = 0;
}
