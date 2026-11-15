// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:collection';

import 'clock.dart';

/// Rates over the last [window], plus totals since creation or [reset].
final class RateMeter {
  RateMeter({
    this.window = const Duration(seconds: 2),
    this._clock = systemClock,
  });

  final Duration window;

  final Clock _clock;
  final Queue<({DateTime at, int bytes})> _recent = Queue();
  int _windowBytes = 0;
  int _totalCount = 0;
  int _totalBytes = 0;
  DateTime? _lastAt;

  void add(int bytes) {
    final now = _clock();
    _recent.add((at: now, bytes: bytes));
    _windowBytes += bytes;
    _totalCount++;
    _totalBytes += bytes;
    _lastAt = now;
    _prune(now);
  }

  int get totalCount => _totalCount;

  int get totalBytes => _totalBytes;

  double get perSecond {
    _prune(_clock());
    return _recent.length / _windowSeconds;
  }

  double get bitsPerSecond {
    _prune(_clock());
    return _windowBytes * 8 / _windowSeconds;
  }

  DateTime? get lastAt => _lastAt;

  void reset() {
    _recent.clear();
    _windowBytes = 0;
    _totalCount = 0;
    _totalBytes = 0;
    _lastAt = null;
  }

  double get _windowSeconds =>
      window.inMicroseconds / Duration.microsecondsPerSecond;

  void _prune(DateTime now) {
    final oldest = now.subtract(window);
    while (_recent.isNotEmpty && !_recent.first.at.isAfter(oldest)) {
      _windowBytes -= _recent.removeFirst().bytes;
    }
  }
}
