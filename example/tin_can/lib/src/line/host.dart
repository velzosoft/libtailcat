// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'package:libtailcat/libtailcat.dart';

import '../telemetry/clock.dart';
import 'datagrams.dart';
import 'greeting.dart';
import 'identity.dart';
import 'line_end.dart';
import 'messages.dart';
import 'session.dart';
import 'transport.dart';

/// The host's end: a server with the saved keys and region (so the address
/// matches the guest's copy) and only the guest allowed. The guest opens
/// every connection; a newer WebSocket replaces the older one.
final class Host extends LineEnd {
  Host({
    required this._network,
    required this._identity,
    required this.myName,
    required super.telemetry,
    super.clock = systemClock,
    this.greetingTimeout = const Duration(seconds: 10),
    this.udpIdleTimeout = const Duration(seconds: 30),
    this.onPartnerName,
  });

  final Network _network;
  HostIdentity _identity;

  String myName;

  final Duration greetingTimeout;

  final Duration udpIdleTimeout;

  /// Called when `hello` carries a new partner name, to save it.
  final void Function(HostIdentity identity)? onPartnerName;

  final _sleeper = Sleeper();
  final _subscriptions = <StreamSubscription<Object?>>[];
  HostLink? _link;
  DatagramFlow? _pendingFlow;
  bool _running = false;

  HostLink? get link => _link;

  @override
  Role get role => Role.host;

  @override
  String get partnerName => _identity.partnerName;

  @override
  List<OpenResource> get resources => _link?.resources ?? const [];

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    setStatus(LinePhase.waiting);
    var failures = 0;
    while (_running && _link == null) {
      try {
        await _startServer();
      } on TailcatException catch (e) {
        telemetry.error('server', e);
        if (!_running) return;
        failures++;
        setStatus(LinePhase.waiting, problem: LineProblem.network);
        await _sleeper.sleep(dialBackoff(failures));
      }
    }
  }

  Future<void> _startServer() async {
    final watch = Stopwatch()..start();
    final link = await _network.startHost(
      HostConfig(
        privateKey: _identity.privateKey,
        presharedKey: _identity.presharedKey,
        region: _identity.region,
        regionId: _identity.regionId,
        allowedClients: [_identity.partnerKey],
        udpIdleTimeout: udpIdleTimeout,
        paths: const {linePath},
      ),
    );
    if (!_running) {
      await link.close(drain: false);
      return;
    }
    _link = link;
    telemetry.time('server start', watch.elapsed);
    telemetry.log.info(
      'server',
      'started in ${watch.elapsedMilliseconds} ms on relay '
          '${link.addressFacts.relay?.label ?? '?'}, '
          'tunnel address ${link.tunnelAddress}, allowlist: the guest only',
    );
    telemetry.log.info(
      'server',
      'listening: TCP $controlPort (HTTP for WebSockets), '
          'UDP $datagramPort (realtime)',
    );
    _subscriptions
      ..add(link.channels.listen(_onChannel))
      ..add(link.flows.listen(_onFlow));
    setStatus(session == null ? LinePhase.waiting : LinePhase.connected);
  }

  Future<void> _onChannel(IncomingChannel incoming) async {
    telemetry.log.info(
      'ws',
      'WebSocket upgraded on ${incoming.path} from ${incoming.remoteEndpoint}',
    );
    if (session == null) setStatus(LinePhase.connecting);
    final Greeting greeting;
    try {
      greeting = await readGreeting(
        incoming.channel,
        telemetry: telemetry,
        timeout: greetingTimeout,
      );
    } on TimeoutException {
      telemetry.log.info('ws', 'no hello in time; closed');
      if (session == null) setStatus(LinePhase.waiting);
      return;
    }
    final hello = greeting.message;
    if (hello is! HelloMessage || !_running) {
      await greeting.channel.close();
      if (session == null) setStatus(LinePhase.waiting);
      return;
    }
    if (hello.name.isNotEmpty && hello.name != _identity.partnerName) {
      _identity = _identity.withPartnerName(hello.name);
      onPartnerName?.call(_identity);
    }
    sendControl(greeting.channel, WelcomeMessage(name: myName), telemetry);

    final previous = session;
    final next = Session(
      role: Role.host,
      partnerName: _identity.partnerName,
      control: greeting.channel,
      telemetry: telemetry,
      embeddedRelay: _link?.addressFacts.relay,
    )..start();
    if (previous != null) {
      telemetry.log.info('session', 'a newer WebSocket replaces the old one');
      await previous.replace();
    }
    setSession(next);
    setStatus(LinePhase.connected);
    final flow = _pendingFlow;
    _pendingFlow = null;
    if (flow != null) next.attachFlow(flow);
    unawaited(
      next.ended.then((_) {
        if (!identical(session, next)) return;
        setSession(null);
        if (_running) setStatus(LinePhase.waiting);
      }),
    );
  }

  void _onFlow(DatagramFlow flow) {
    telemetry.log.info(
      'udp',
      'UDP flow seen: ${flow.localEndpoint} ← ${flow.remoteEndpoint}',
    );
    final current = session;
    if (current != null && current.isOpen) {
      current.attachFlow(flow);
    } else {
      // The guest's first echo can beat the session.
      final stale = _pendingFlow;
      if (stale != null) unawaited(stale.close());
      _pendingFlow = flow;
    }
  }

  @override
  Future<void> stop({bool drain = true}) async {
    _running = false;
    _sleeper.cancel();
    final current = session;
    if (current != null) await current.hangUp();
    setSession(null);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final pending = _pendingFlow;
    _pendingFlow = null;
    if (pending != null) await pending.close();
    final link = _link;
    _link = null;
    if (link != null) {
      final watch = Stopwatch()..start();
      await link.close(drain: drain);
      telemetry.log.info(
        'server',
        'closed${drain ? ' with drain' : ''} in ${watch.elapsedMilliseconds} ms',
      );
    }
    setStatus(LinePhase.offline);
  }
}
