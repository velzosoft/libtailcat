// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// RFC 3550 §6.4.1 interarrival jitter: a running average of |D| with gain
/// 1/16, where D is arrival spacing minus send spacing.
final class JitterEstimator {
  JitterEstimator({required this.clockRate});

  /// Timestamp units per second (16000 for 16 kHz sample time).
  final int clockRate;

  static const int _wrap = 0x100000000;

  int? _lastTimestamp;
  Duration? _lastArrival;
  double _jitter = 0;

  /// [timestamp] is a u32 that may wrap; [arrival] is on a monotonic clock.
  void add({required int timestamp, required Duration arrival}) {
    final sent = timestamp & 0xFFFFFFFF;
    final lastTimestamp = _lastTimestamp;
    final lastArrival = _lastArrival;
    _lastTimestamp = sent;
    _lastArrival = arrival;
    if (lastTimestamp == null || lastArrival == null) return;

    var sentApart = (sent - lastTimestamp) % _wrap;
    if (sentApart >= _wrap ~/ 2) sentApart -= _wrap;
    final arrivedApart =
        (arrival - lastArrival).inMicroseconds *
        clockRate /
        Duration.microsecondsPerSecond;
    final d = arrivedApart - sentApart;
    _jitter += (d.abs() - _jitter) / 16;
  }

  double get jitterUnits => _jitter;

  Duration get jitter => Duration(
    microseconds: (_jitter * Duration.microsecondsPerSecond / clockRate)
        .round(),
  );

  void reset() {
    _lastTimestamp = null;
    _lastArrival = null;
    _jitter = 0;
  }
}
