// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/telemetry/jitter.dart';

void main() {
  // 20 ms voice frames at 16 kHz: 320 samples apart.
  const frame = 320;
  const frameTime = Duration(milliseconds: 20);

  test('steady arrivals have no jitter', () {
    final estimator = JitterEstimator(clockRate: 16000);
    for (var i = 0; i < 100; i++) {
      estimator.add(timestamp: i * frame, arrival: frameTime * i);
    }
    expect(estimator.jitterUnits, 0);
    expect(estimator.jitter, Duration.zero);
  });

  test('arrivals alternating by ±d converge toward d', () {
    const d = Duration(milliseconds: 5);
    final estimator = JitterEstimator(clockRate: 16000);
    for (var i = 0; i < 400; i++) {
      final offset = i.isEven ? Duration.zero : d;
      estimator.add(timestamp: i * frame, arrival: frameTime * i + offset);
    }
    // Every step differs from the last by 5 ms, which is 80 samples.
    expect(estimator.jitterUnits, closeTo(80, 0.5));
    expect(estimator.jitter.inMicroseconds, closeTo(d.inMicroseconds, 50));
  });

  test('a single spike moves the estimate by 1/16', () {
    final estimator = JitterEstimator(clockRate: 16000)
      ..add(timestamp: 0, arrival: Duration.zero)
      ..add(timestamp: frame, arrival: frameTime + frameTime);
    expect(estimator.jitterUnits, closeTo(320 / 16, 1e-9));
  });

  test('timestamps that wrap past 2^32 are not a jump', () {
    final estimator = JitterEstimator(clockRate: 16000);
    const start = 0xFFFFFFFF - 2 * frame + 1;
    for (var i = 0; i < 6; i++) {
      estimator.add(
        timestamp: (start + i * frame) & 0xFFFFFFFF,
        arrival: frameTime * i,
      );
    }
    expect(estimator.jitterUnits, 0);
  });

  test('reset starts over', () {
    final estimator = JitterEstimator(clockRate: 16000)
      ..add(timestamp: 0, arrival: Duration.zero)
      ..add(timestamp: frame, arrival: frameTime * 3)
      ..reset();
    expect(estimator.jitterUnits, 0);
    estimator.add(timestamp: 5000, arrival: const Duration(seconds: 9));
    expect(estimator.jitterUnits, 0);
  });
}
