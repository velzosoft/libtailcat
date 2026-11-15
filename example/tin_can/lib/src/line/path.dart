// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'package:libtailcat/libtailcat.dart';

import '../telemetry/clock.dart';
import 'messages.dart';
import 'relays.dart';
import 'transport.dart';

/// One `discoPing` result.
final class PathReport {
  const PathReport({
    required this.at,
    required this.direct,
    required this.latency,
    this.reportedByPartner = false,
    this.endpoint,
    this.relay,
    this.relayCode,
  });

  factory PathReport.fromProbe(
    TailcatPath path, {
    required DateTime at,
    RelayInfo? embeddedRelay,
  }) => PathReport(
    at: at,
    direct: path.isDirect,
    latency: path.latency,
    endpoint: path.endpoint,
    relayCode: path.derpRegionCode,
    relay: path.isDirect
        ? null
        : Relays.fromCode(path.derpRegionCode, embedded: embeddedRelay),
  );

  factory PathReport.fromMessage(
    PathMessage message, {
    required DateTime at,
    RelayInfo? embeddedRelay,
  }) => PathReport(
    at: at,
    direct: message.direct,
    latency: Duration(microseconds: (message.ms * 1000).round()),
    reportedByPartner: true,
    relayCode: message.relay,
    relay: message.direct
        ? null
        : Relays.fromCode(message.relay, embedded: embeddedRelay),
  );

  /// When measured, or received.
  final DateTime at;

  final bool direct;

  final Duration latency;

  /// Only a client can probe, so the host shows what the guest reported.
  final bool reportedByPartner;

  /// The other side's real `ip:port` when direct and probed here. Sensitive.
  final String? endpoint;

  final RelayInfo? relay;

  final String? relayCode;

  /// Leaves out the endpoint: it's the host's own address.
  PathMessage toMessage({Duration? relayRtt}) => PathMessage(
    direct: direct,
    ms: _ms(latency),
    relay: direct ? null : (relay?.code ?? relayCode),
    relayMs: relayRtt == null ? null : _ms(relayRtt),
  );

  static double _ms(Duration duration) =>
      (duration.inMicroseconds / 100).round() / 10;

  @override
  String toString() => direct
      ? 'direct, ${latency.inMilliseconds} ms'
      : 'via ${relay?.label ?? relayCode}, ${latency.inMilliseconds} ms';
}

/// The guest's path probes. Probing nudges NAT traversal, so probing fast
/// until direct moves a new connection off the relay sooner.
final class PathMonitor {
  PathMonitor({
    required this._link,
    this._embeddedRelay,
    this._clock = systemClock,
    this.fastInterval = const Duration(seconds: 1),
    this.slowInterval = const Duration(seconds: 5),
    this.relayInterval = const Duration(seconds: 5),
  });

  final GuestLink _link;
  final RelayInfo? _embeddedRelay;
  final Clock _clock;

  /// Until the path is direct.
  final Duration fastInterval;

  final Duration slowInterval;

  final Duration relayInterval;

  final _reports = StreamController<PathReport>.broadcast();
  final _relayPings = StreamController<Duration>.broadcast();
  final _errors = StreamController<TailcatException>.broadcast();
  final _sleeps = <Completer<void>>{};
  bool _running = false;

  Stream<PathReport> get reports => _reports.stream;

  Stream<Duration> get relayPings => _relayPings.stream;

  Stream<TailcatException> get errors => _errors.stream;

  PathReport? get last => _last;
  PathReport? _last;

  Duration? get lastRelayPing => _lastRelayPing;
  Duration? _lastRelayPing;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_probeLoop());
    unawaited(_relayLoop());
  }

  /// A probe in flight finishes in the background.
  Future<void> stop() async {
    _running = false;
    for (final sleep in _sleeps.toList()) {
      sleep.complete();
    }
    _sleeps.clear();
    await _reports.close();
    await _relayPings.close();
    await _errors.close();
  }

  Future<void> _probeLoop() async {
    while (_running) {
      try {
        final path = await _link.discoPing();
        if (!_running) return;
        final report = PathReport.fromProbe(
          path,
          at: _clock(),
          embeddedRelay: _embeddedRelay,
        );
        _last = report;
        _reports.add(report);
      } on TailcatException catch (e) {
        if (!_running || e is TailcatClosedException) return;
        _errors.add(e);
      }
      await _sleep(_last?.direct ?? false ? slowInterval : fastInterval);
    }
  }

  Future<void> _relayLoop() async {
    while (_running) {
      try {
        final rtt = await _link.ping();
        if (!_running) return;
        _lastRelayPing = rtt;
        _relayPings.add(rtt);
      } on TailcatException catch (e) {
        if (!_running || e is TailcatClosedException) return;
        _errors.add(e);
      }
      await _sleep(relayInterval);
    }
  }

  /// Cut short by [stop].
  Future<void> _sleep(Duration duration) {
    if (!_running) return Future.value();
    final done = Completer<void>();
    _sleeps.add(done);
    final timer = Timer(duration, () {
      if (!done.isCompleted) done.complete();
    });
    return done.future.whenComplete(() {
      timer.cancel();
      _sleeps.remove(done);
    });
  }
}
