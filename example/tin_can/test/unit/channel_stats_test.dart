// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/telemetry/channel_stats.dart';

void main() {
  final now = DateTime(2026, 11, 15, 12);
  DateTime clock() => now;

  test('counts both directions separately', () {
    final stats = ChannelStats('touch', clock: clock)
      ..recordSent(8)
      ..recordSent(8)
      ..recordReceived(8);
    expect(stats.sent.totalCount, 2);
    expect(stats.sent.totalBytes, 16);
    expect(stats.received.totalCount, 1);
  });

  test('tracks the smallest and largest payload in either direction', () {
    final stats = ChannelStats(
      'voice',
      sequenced: true,
      maxPayloadSize: 1232,
      clock: clock,
    );
    expect(stats.smallest, isNull);
    expect(stats.largest, isNull);
    stats
      ..recordSent(327)
      ..recordReceived(7)
      ..recordReceived(327);
    expect(stats.smallest, 7);
    expect(stats.largest, 327);
    expect(stats.maxPayloadSize, 1232);
  });

  test('received sequence numbers feed the sequence stats', () {
    final stats = ChannelStats('echo', sequenced: true, clock: clock)
      ..recordReceived(7, seq: 1)
      ..recordReceived(7, seq: 3)
      ..recordReceived(7);
    expect(stats.sequence.received, 2);
    expect(stats.sequence.lost, 1);
  });

  test('reset forgets everything', () {
    final stats = ChannelStats('ws', clock: clock)
      ..recordSent(100)
      ..recordReceived(50, seq: 9)
      ..reset();
    expect(stats.sent.totalCount, 0);
    expect(stats.received.totalCount, 0);
    expect(stats.sequence.received, 0);
    expect(stats.smallest, isNull);
    expect(stats.largest, isNull);
  });
}
