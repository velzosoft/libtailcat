// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'clock.dart';
import 'rate_meter.dart';
import 'sequence_stats.dart';

/// Traffic on one channel, in payload bytes: libtailcat doesn't report bytes
/// on the wire.
final class ChannelStats {
  ChannelStats(
    this.name, {
    this.sequenced = false,
    this.maxPayloadSize,
    Clock clock = systemClock,
  }) : sent = RateMeter(clock: clock),
       received = RateMeter(clock: clock);

  /// Such as `WebSocket`, `touch` or `voice`.
  final String name;

  /// Whether received datagrams carry sequence numbers.
  final bool sequenced;

  final int? maxPayloadSize;

  final RateMeter sent;

  final RateMeter received;

  /// Only fed on a [sequenced] channel.
  final SequenceStats sequence = SequenceStats();

  int? _smallest;
  int? _largest;

  /// In either direction.
  int? get smallest => _smallest;

  /// In either direction.
  int? get largest => _largest;

  void recordSent(int bytes) {
    sent.add(bytes);
    _size(bytes);
  }

  void recordReceived(int bytes, {int? seq}) {
    received.add(bytes);
    _size(bytes);
    if (seq != null) sequence.add(seq);
  }

  void reset() {
    sent.reset();
    received.reset();
    sequence.reset();
    _smallest = null;
    _largest = null;
  }

  void _size(int bytes) {
    final smallest = _smallest;
    final largest = _largest;
    if (smallest == null || bytes < smallest) _smallest = bytes;
    if (largest == null || bytes > largest) _largest = bytes;
  }
}
