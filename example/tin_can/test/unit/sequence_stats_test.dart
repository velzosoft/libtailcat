// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/telemetry/sequence_stats.dart';

void main() {
  SequenceStats feed(Iterable<int> seqs) {
    final stats = SequenceStats();
    seqs.forEach(stats.add);
    return stats;
  }

  test('expects nothing before the first datagram', () {
    final stats = SequenceStats();
    expect(stats.expected, 0);
    expect(stats.lost, 0);
    expect(stats.lossRatio, 0);
    expect(stats.last, isNull);
  });

  test('counts an in-order run without loss', () {
    final stats = feed([for (var i = 10; i < 110; i++) i]);
    expect(stats.received, 100);
    expect(stats.expected, 100);
    expect(stats.lost, 0);
    expect(stats.reordered, 0);
    expect(stats.duplicates, 0);
    expect(stats.last, 109);
  });

  test('counts gaps as loss', () {
    final stats = feed([1, 2, 5, 6, 10]);
    expect(stats.expected, 10);
    expect(stats.lost, 5);
    expect(stats.lossRatio, 0.5);
  });

  test('a late datagram fills its gap and counts as reordered', () {
    final stats = feed([1, 2, 4, 3, 5]);
    expect(stats.lost, 0);
    expect(stats.reordered, 1);
    expect(stats.duplicates, 0);
    expect(stats.last, 5);
  });

  test('a datagram from before the first one widens the range', () {
    final stats = feed([5, 6, 4]);
    expect(stats.expected, 3);
    expect(stats.lost, 0);
    expect(stats.reordered, 1);
  });

  test('counts duplicates once, not as loss or reordering', () {
    final stats = feed([1, 2, 2, 3, 1]);
    expect(stats.received, 5);
    expect(stats.duplicates, 2);
    expect(stats.reordered, 0);
    expect(stats.lost, 0);
  });

  test('wraps from 65535 to 0 without counting loss', () {
    final stats = feed([65533, 65534, 65535, 0, 1, 2]);
    expect(stats.expected, 6);
    expect(stats.lost, 0);
    expect(stats.reordered, 0);
    expect(stats.last, 2);
  });

  test('reordering across the wrap is still reordering', () {
    final stats = feed([65534, 0, 65535, 1]);
    expect(stats.expected, 4);
    expect(stats.lost, 0);
    expect(stats.reordered, 1);
  });

  test('keeps counting over many wraps', () {
    final stats = SequenceStats();
    for (var i = 0; i < 3 * 65536; i++) {
      if (i % 100 != 0) stats.add(i & 0xFFFF);
    }
    expect(stats.expected, 3 * 65536 - 1);
    expect(stats.lost, (3 * 65536 / 100).ceil() - 1);
    expect(stats.duplicates, 0);
  });

  test('reset forgets everything', () {
    final stats = feed([1, 3, 3])..reset();
    expect(stats.received, 0);
    expect(stats.expected, 0);
    expect(stats.duplicates, 0);
    expect(stats.last, isNull);
    stats.add(40000);
    expect(stats.expected, 1);
  });
}
