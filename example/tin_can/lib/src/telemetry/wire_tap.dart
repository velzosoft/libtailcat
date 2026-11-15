// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:collection';

import 'clock.dart';

enum WireDirection { sent, received }

/// One message or datagram as it went over the tunnel.
final class WireRecord {
  const WireRecord({
    required this.at,
    required this.direction,
    required this.channel,
    required this.bytes,
    required this.summary,
    this.raw,
  });

  final DateTime at;

  final WireDirection direction;

  /// `ws`, `touch`, `voice`, `echo` or `echo reply`.
  final String channel;

  /// Payload bytes.
  final int bytes;

  /// The decoded fields, such as `seq 412 x 0.513 y 0.207 down`.
  final String summary;

  /// A WebSocket message's JSON, or a datagram in hex.
  final String? raw;
}

/// A live, pausable tap of the last [capacity] records of traffic.
final class WireTap {
  WireTap({this.capacity = 200, this._clock = systemClock});

  final int capacity;

  final Clock _clock;
  final Queue<WireRecord> _records = Queue();
  final StreamController<void> _changes = StreamController.broadcast();
  bool _paused = false;

  /// While paused, new traffic is ignored.
  bool get paused => _paused;

  set paused(bool value) {
    if (value == _paused) return;
    _paused = value;
    _changes.add(null);
  }

  void record({
    required WireDirection direction,
    required String channel,
    required int bytes,
    required String summary,
    String? raw,
  }) {
    if (_paused) return;
    _records.add(
      WireRecord(
        at: _clock(),
        direction: direction,
        channel: channel,
        bytes: bytes,
        summary: summary,
        raw: raw,
      ),
    );
    while (_records.length > capacity) {
      _records.removeFirst();
    }
    _changes.add(null);
  }

  /// Oldest first.
  List<WireRecord> get records => List.unmodifiable(_records);

  Stream<void> get changes => _changes.stream;

  void clear() {
    _records.clear();
    _changes.add(null);
  }

  Future<void> close() => _changes.close();

  /// Space-separated hex, such as `01 00 2a ff`, cut after [max] bytes.
  static String hex(List<int> bytes, {int max = 48}) {
    final shown = bytes.length > max ? bytes.take(max) : bytes;
    final text = shown
        .map((byte) => (byte & 0xFF).toRadixString(16).padLeft(2, '0'))
        .join(' ');
    return bytes.length > max ? '$text … (+${bytes.length - max} bytes)' : text;
  }
}
