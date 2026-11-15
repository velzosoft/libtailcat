// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/telemetry/wire_tap.dart';

void main() {
  final now = DateTime(2026, 11, 15, 12);
  DateTime clock() => now;

  void touch(WireTap tap, int seq) => tap.record(
    direction: WireDirection.sent,
    channel: 'touch',
    bytes: 8,
    summary: 'seq $seq',
    raw: '01 00 ${seq.toRadixString(16).padLeft(2, '0')}',
  );

  test('records traffic with its time', () {
    final tap = WireTap(clock: clock);
    touch(tap, 1);
    final record = tap.records.single;
    expect(record.at, now);
    expect(record.direction, WireDirection.sent);
    expect(record.channel, 'touch');
    expect(record.bytes, 8);
    expect(record.summary, 'seq 1');
  });

  test('ignores traffic while paused', () {
    final tap = WireTap(clock: clock);
    touch(tap, 1);
    tap.paused = true;
    touch(tap, 2);
    expect(tap.records, hasLength(1));
    tap.paused = false;
    touch(tap, 3);
    expect(tap.records.map((r) => r.summary), ['seq 1', 'seq 3']);
  });

  test('keeps only the last records', () {
    final tap = WireTap(capacity: 2, clock: clock);
    for (var i = 0; i < 5; i++) {
      touch(tap, i);
    }
    expect(tap.records.map((r) => r.summary), ['seq 3', 'seq 4']);
    tap.clear();
    expect(tap.records, isEmpty);
  });

  test('announces changes', () async {
    final tap = WireTap(clock: clock);
    addTearDown(tap.close);
    var count = 0;
    tap.changes.listen((_) => count++);
    touch(tap, 1);
    tap.paused = true;
    touch(tap, 2); // ignored: no change
    await pumpEventQueue();
    expect(count, 2);
  });

  test('hex prints byte pairs and truncates long payloads', () {
    expect(WireTap.hex([1, 0, 42, 255]), '01 00 2a ff');
    expect(WireTap.hex([]), '');
    expect(
      WireTap.hex(List.filled(50, 0xab), max: 4),
      'ab ab ab ab … (+46 bytes)',
    );
    expect(WireTap.hex(List.filled(48, 0)).split(' '), hasLength(48));
  });
}
