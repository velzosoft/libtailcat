// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:io';

import 'package:libtailcat/libtailcat.dart';

import '../telemetry/clock.dart';
import 'greeting.dart';
import 'identity.dart';
import 'line_end.dart';
import 'messages.dart';
import 'path.dart';
import 'relays.dart';
import 'session.dart';
import 'transport.dart';

/// The guest's end: dials the saved address with backoff, then reports path
/// probes to the host, which can't probe itself.
///
/// Each attempt uses a fresh `TailcatClient` with the same key, so nothing
/// carries over from a failed attempt or a restarted host.
final class Guest extends LineEnd {
  Guest({
    required this._network,
    required this._identity,
    required this.myName,
    required super.telemetry,
    super.clock = systemClock,
    this.dialTimeout = const Duration(seconds: 10),
    this.greetingTimeout = const Duration(seconds: 10),
    this.backoff = dialBackoff,
    this.pathMonitorFactory,
    this.onPartnerName,
  });

  final Network _network;
  GuestIdentity _identity;

  String myName;

  final Duration dialTimeout;

  final Duration greetingTimeout;

  final Duration Function(int failures) backoff;

  /// Tests shorten the intervals.
  final PathMonitor Function(GuestLink link, RelayInfo? relay)?
  pathMonitorFactory;

  /// Called when `welcome` carries a new partner name, to save it.
  final void Function(GuestIdentity identity)? onPartnerName;

  final _sleeper = Sleeper();
  late final RelayInfo? _relay = _embeddedRelay();
  GuestLink? _link;
  bool _running = false;
  Future<void>? _loop;

  @override
  Role get role => Role.guest;

  @override
  String get partnerName => _identity.partnerName;

  @override
  List<OpenResource> get resources => _link?.resources ?? const [];

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _loop = _dialLoop();
  }

  Future<void> _dialLoop() async {
    var failures = 0;
    while (_running) {
      telemetry
        ..dialAttempts += 1
        ..nextDialAt = null;
      setStatus(LinePhase.connecting, problem: status.problem);
      telemetry.log.info('dial', 'attempt ${telemetry.dialAttempts}');
      final link = _network.openGuest(
        address: _identity.hostAddress,
        privateKey: _identity.privateKey,
      );
      _link = link;
      PathMonitor? monitor;
      try {
        final session = await _connect(link);
        if (session == null) {
          failures++;
        } else {
          failures = 0;
          monitor = _monitorPath(link, session);
          final reason = await session.ended;
          setSession(null);
          if (reason == SessionEnd.cut || reason == SessionEnd.partnerCut) {
            _running = false;
          }
        }
      } on TimeoutException catch (e) {
        failures++;
        telemetry.error('dial', e);
        setStatus(LinePhase.waiting);
      } on ProtocolMismatchException catch (e) {
        failures = 99;
        telemetry.error('dial', e);
        setStatus(LinePhase.waiting, problem: LineProblem.mismatch);
      } on TailcatClosedException {
        // stop() closed the client.
        if (!_running) break;
        failures++;
      } on TailcatException catch (e) {
        failures++;
        telemetry.error('dial', e);
        setStatus(LinePhase.waiting, problem: LineProblem.network);
      } on IOException catch (e) {
        // E.g. a WebSocket upgrade that broke half-way.
        failures++;
        telemetry.error('dial', e);
        setStatus(LinePhase.waiting, problem: LineProblem.network);
      } finally {
        await monitor?.stop();
        if (identical(_link, link)) {
          _link = null;
          await link.close(drain: false);
        }
      }
      if (!_running) break;
      if (status.phase != LinePhase.waiting) setStatus(LinePhase.waiting);
      final delay = backoff(failures);
      telemetry.nextDialAt = clock().add(delay);
      telemetry.log.info(
        'dial',
        'next attempt in ${delay.inMilliseconds / 1000} s',
      );
      await _sleeper.sleep(delay);
      telemetry.nextDialAt = null;
    }
  }

  /// `null` when the host answered the WebSocket but not `hello`.
  Future<Session?> _connect(GuestLink link) async {
    final watch = Stopwatch()..start();
    final channel = await link.connect(linePath, timeout: dialTimeout);
    telemetry.time('WebSocket connect', watch.elapsed);
    telemetry.log.info(
      'ws',
      'WebSocket connected to $linePath in ${watch.elapsedMilliseconds} ms',
    );
    sendControl(channel, HelloMessage(name: myName), telemetry);
    final greeting = await readGreeting(
      channel,
      telemetry: telemetry,
      timeout: greetingTimeout,
    );
    final welcome = greeting.message;
    if (welcome is! WelcomeMessage || !_running) {
      await greeting.channel.close();
      return null;
    }
    if (welcome.name.isNotEmpty && welcome.name != _identity.partnerName) {
      _identity = _identity.withPartnerName(welcome.name);
      onPartnerName?.call(_identity);
    }
    final DatagramFlow flow;
    try {
      flow = await link.openFlow();
    } catch (_) {
      await greeting.channel.close();
      rethrow;
    }
    telemetry.log.info(
      'udp',
      'UDP flow opened: ${flow.localEndpoint} → ${flow.remoteEndpoint}',
    );
    final session = Session(
      role: Role.guest,
      partnerName: _identity.partnerName,
      control: greeting.channel,
      telemetry: telemetry,
      embeddedRelay: _relay,
    )..start();
    // Echoes at once: the host only sees the flow with its first datagram.
    session.attachFlow(flow);
    setSession(session);
    setStatus(LinePhase.connected);
    return session;
  }

  PathMonitor _monitorPath(GuestLink link, Session session) {
    final monitor =
        pathMonitorFactory?.call(link, _relay) ??
        PathMonitor(link: link, embeddedRelay: _relay, clock: clock);
    monitor.reports.listen(
      (report) => session.reportPath(report, relayRtt: monitor.lastRelayPing),
    );
    monitor.relayPings.listen(telemetry.relayLatency.add);
    monitor.errors.listen((error) => telemetry.error('path', error));
    monitor.start();
    return monitor;
  }

  RelayInfo? _embeddedRelay() {
    try {
      return _network.parseAddress(_identity.hostAddress).relay;
    } on TailcatException {
      return null;
    }
  }

  @override
  Future<void> stop({bool drain = true}) async {
    _running = false;
    _sleeper.cancel();
    final current = session;
    if (current != null) await current.hangUp();
    setSession(null);
    final link = _link;
    _link = null;
    if (link != null) await link.close(drain: drain);
    await _loop;
    _loop = null;
    setStatus(LinePhase.offline);
  }
}
