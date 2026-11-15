// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/telemetry/latency_history.dart';

void main() {
  var now = DateTime(2026, 11, 15, 12);
  DateTime clock() => now;
  void advance(Duration by) => now = now.add(by);
  Duration ms(int value) => Duration(milliseconds: value);

  setUp(() => now = DateTime(2026, 11, 15, 12));

  test('is empty at first', () {
    final history = LatencyHistory(clock: clock);
    expect(history.samples, isEmpty);
    expect(history.count, 0);
    expect(history.last, isNull);
    expect(history.min, isNull);
    expect(history.max, isNull);
    expect(history.average, isNull);
  });

  test('summarises the samples within the span', () {
    final history = LatencyHistory(clock: clock);
    for (final value in [30, 10, 20]) {
      history.add(ms(value));
      advance(const Duration(seconds: 1));
    }
    expect(history.count, 3);
    expect(history.last, ms(20));
    expect(history.min, ms(10));
    expect(history.max, ms(30));
    expect(history.average, ms(20));
    expect(history.samples.map((s) => s.latency), [ms(30), ms(10), ms(20)]);
    expect(history.samples.first.at, DateTime(2026, 11, 15, 12));
  });

  test('drops samples older than the span', () {
    final history = LatencyHistory(
      span: const Duration(seconds: 10),
      clock: clock,
    )..add(ms(100));
    advance(const Duration(seconds: 6));
    history.add(ms(40));
    advance(const Duration(seconds: 6));
    expect(history.count, 1);
    expect(history.max, ms(40));
    expect(history.last, ms(40));
    advance(const Duration(seconds: 5));
    expect(history.count, 0);
    expect(history.last, isNull);
  });

  test('the samples list cannot be changed from outside', () {
    final history = LatencyHistory(clock: clock)..add(ms(1));
    expect(() => history.samples.clear(), throwsUnsupportedError);
  });

  test('clear forgets everything', () {
    final history = LatencyHistory(clock: clock)
      ..add(ms(5))
      ..clear();
    expect(history.count, 0);
  });
}
