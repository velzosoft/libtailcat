// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/telemetry/rate_meter.dart';

void main() {
  var now = DateTime(2026, 11, 15, 12);
  DateTime clock() => now;
  void advance(int milliseconds) =>
      now = now.add(Duration(milliseconds: milliseconds));

  setUp(() => now = DateTime(2026, 11, 15, 12));

  test('starts empty', () {
    final meter = RateMeter(clock: clock);
    expect(meter.totalCount, 0);
    expect(meter.totalBytes, 0);
    expect(meter.perSecond, 0);
    expect(meter.bitsPerSecond, 0);
    expect(meter.lastAt, isNull);
  });

  test('averages over the window and keeps totals', () {
    final meter = RateMeter(clock: clock);
    for (var i = 0; i < 10; i++) {
      meter.add(100);
      advance(100);
    }
    // 10 messages of 100 bytes within the 2 s window.
    expect(meter.perSecond, 5);
    expect(meter.bitsPerSecond, 10 * 100 * 8 / 2);
    expect(meter.totalCount, 10);
    expect(meter.totalBytes, 1000);
    expect(meter.lastAt, DateTime(2026, 11, 15, 12, 0, 0, 900));
  });

  test('forgets entries older than the window, but not the totals', () {
    final meter = RateMeter(window: const Duration(seconds: 1), clock: clock)
      ..add(10)
      ..add(10);
    advance(500);
    meter.add(30);
    expect(meter.perSecond, 3);
    advance(600);
    expect(meter.perSecond, 1);
    expect(meter.bitsPerSecond, 30 * 8);
    advance(1000);
    expect(meter.perSecond, 0);
    expect(meter.bitsPerSecond, 0);
    expect(meter.totalCount, 3);
    expect(meter.totalBytes, 50);
  });

  test('reset forgets everything', () {
    final meter = RateMeter(clock: clock)
      ..add(5)
      ..reset();
    expect(meter.totalCount, 0);
    expect(meter.totalBytes, 0);
    expect(meter.perSecond, 0);
    expect(meter.lastAt, isNull);
  });
}
