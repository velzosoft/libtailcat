// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';

import 'package:libtailcat/libtailcat.dart';

import '../telemetry/channel_stats.dart';
import '../telemetry/clock.dart';
import '../telemetry/event_log.dart';
import '../telemetry/latency_history.dart';
import '../telemetry/masking.dart';
import '../telemetry/wire_tap.dart';
import 'messages.dart';
import 'path.dart';

/// Everything the line measures, for the X-ray overlay and the Inspector.
///
/// Byte counts are payload bytes counted by the app; libtailcat doesn't report
/// bytes on the wire.
final class LineTelemetry {
  LineTelemetry({this.clock = systemClock})
    : log = EventLog(clock: clock),
      tap = WireTap(clock: clock),
      control = ChannelStats('WebSocket', clock: clock),
      touch = ChannelStats(
        'touch',
        sequenced: true,
        maxPayloadSize: TailcatDatagramSocket.maxPayloadSize,
        clock: clock,
      ),
      voice = ChannelStats(
        'voice',
        sequenced: true,
        maxPayloadSize: TailcatDatagramSocket.maxPayloadSize,
        clock: clock,
      ),
      echo = ChannelStats(
        'echo',
        sequenced: true,
        maxPayloadSize: TailcatDatagramSocket.maxPayloadSize,
        clock: clock,
      ),
      pathLatency = LatencyHistory(clock: clock),
      relayLatency = LatencyHistory(clock: clock),
      controlRtt = LatencyHistory(clock: clock),
      datagramRtt = LatencyHistory(clock: clock);

  final Clock clock;

  final Masking masking = Masking();

  final EventLog log;

  final WireTap tap;

  final ChannelStats control;

  final ChannelStats touch;

  final ChannelStats voice;

  /// Echo and echo-reply datagrams.
  final ChannelStats echo;

  /// `TailcatClient.discoPing()` round trips.
  final LatencyHistory pathLatency;

  /// `TailcatClient.ping()` round trips, over the relay.
  final LatencyHistory relayLatency;

  /// The app's `ping`/`pong` over the WebSocket.
  final LatencyHistory controlRtt;

  final LatencyHistory datagramRtt;

  /// In the order they happened.
  final Map<String, Duration> timings = {};

  PathReport? get path => _path;
  PathReport? _path;

  /// Switches between relayed and direct this session.
  int get pathChanges => _pathChanges;
  int _pathChanges = 0;

  /// From the start of the session.
  Duration? get timeToFirstDirect => _timeToFirstDirect;
  Duration? _timeToFirstDirect;

  DateTime? _sessionStart;

  DateTime? get sessionStart => _sessionStart;

  /// Since the last session.
  int dialAttempts = 0;

  DateTime? nextDialAt;

  String? lastError;

  void startSession() {
    _sessionStart = clock();
    _path = null;
    _pathChanges = 0;
    _timeToFirstDirect = null;
    dialAttempts = 0;
    nextDialAt = null;
    for (final channel in [control, touch, voice, echo]) {
      channel.reset();
    }
    timings.remove('first datagram');
  }

  void recordPath(PathReport report) {
    final previous = _path;
    _path = report;
    pathLatency.add(report.latency);
    final start = _sessionStart;
    if (report.direct && _timeToFirstDirect == null && start != null) {
      _timeToFirstDirect = report.at.difference(start);
    }
    if (previous == null || previous.direct != report.direct) {
      if (previous != null) _pathChanges++;
      final by = report.reportedByPartner ? ' (reported by the guest)' : '';
      log.add('path', [
        if (report.direct) ...[
          'direct',
          if (report.endpoint case final endpoint?) ...[
            ' via ',
            Sensitive(SensitiveKind.endpoint, endpoint),
          ],
        ] else
          'relayed via ${report.relay?.label ?? report.relayCode ?? 'relay'}',
        ', ${_ms(report.latency)}$by',
      ]);
    }
  }

  void controlSent(ControlMessage message, String text) {
    control.recordSent(utf8.encode(text).length);
    tap.record(
      direction: WireDirection.sent,
      channel: 'ws',
      bytes: text.length,
      summary: message.type,
      raw: text,
    );
  }

  /// [message] is `null` for an unknown type.
  void controlReceived(String text, ControlMessage? message) {
    control.recordReceived(utf8.encode(text).length);
    tap.record(
      direction: WireDirection.received,
      channel: 'ws',
      bytes: text.length,
      summary: message?.type ?? 'unknown type, ignored',
      raw: text,
    );
  }

  void time(String label, Duration duration) {
    timings[label] = duration;
  }

  /// A [TailcatException]'s message never contains a secret.
  void error(String category, Object error) {
    final text = switch (error) {
      TailcatException() => '${error.runtimeType}: ${error.message}',
      _ => '$error',
    };
    lastError = text;
    log.info(category, text);
  }

  /// `0.3 ms` or `84 ms`.
  static String _ms(Duration duration) {
    final ms = duration.inMicroseconds / 1000;
    return ms < 10 ? '${ms.toStringAsFixed(1)} ms' : '${ms.round()} ms';
  }

  Future<void> close() async {
    await masking.close();
    await log.close();
    await tap.close();
  }
}
