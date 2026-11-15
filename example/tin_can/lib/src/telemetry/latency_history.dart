// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:collection';

import 'clock.dart';

final class LatencySample {
  const LatencySample(this.at, this.latency);

  final DateTime at;

  /// Round-trip time.
  final Duration latency;
}

/// The latency measurements of the last [span].
final class LatencyHistory {
  LatencyHistory({
    this.span = const Duration(seconds: 60),
    this._clock = systemClock,
  });

  final Duration span;

  final Clock _clock;
  final Queue<LatencySample> _samples = Queue();

  void add(Duration latency) {
    final now = _clock();
    _samples.add(LatencySample(now, latency));
    _prune(now);
  }

  /// Oldest first.
  List<LatencySample> get samples {
    _prune(_clock());
    return List.unmodifiable(_samples);
  }

  Duration? get last {
    _prune(_clock());
    return _samples.isEmpty ? null : _samples.last.latency;
  }

  Duration? get min => _fold((a, b) => b < a ? b : a);

  Duration? get max => _fold((a, b) => b > a ? b : a);

  Duration? get average {
    _prune(_clock());
    if (_samples.isEmpty) return null;
    final total = _samples.fold<int>(
      0,
      (sum, sample) => sum + sample.latency.inMicroseconds,
    );
    return Duration(microseconds: (total / _samples.length).round());
  }

  int get count {
    _prune(_clock());
    return _samples.length;
  }

  void clear() => _samples.clear();

  Duration? _fold(Duration Function(Duration a, Duration b) pick) {
    _prune(_clock());
    if (_samples.isEmpty) return null;
    return _samples.map((sample) => sample.latency).reduce(pick);
  }

  void _prune(DateTime now) {
    final oldest = now.subtract(span);
    while (_samples.isNotEmpty && _samples.first.at.isBefore(oldest)) {
      _samples.removeFirst();
    }
  }
}
