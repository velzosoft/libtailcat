// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Tying a string: both sides check the same six symbols before saving.
library;

import 'dart:async';

import 'package:libtailcat/libtailcat.dart';

import '../telemetry/clock.dart';
import 'greeting.dart';
import 'identity.dart';
import 'messages.dart';
import 'safety_code.dart';
import 'telemetry.dart';
import 'transport.dart';

enum PairingStage {
  starting,

  /// Host only: showing the QR code.
  waiting,

  /// Both show the symbols; the host's user confirms them.
  checking,

  /// Host only.
  confirming,
  paired,
  cancelled,
  failed,
}

/// A pairing step, for the screens' technical side.
final class PairingStep {
  const PairingStep(this.label, this.at);

  final String label;

  /// Since the start of the pairing.
  final Duration at;

  @override
  String toString() => '${at.inMilliseconds} ms  $label';
}

abstract class _Pairing {
  _Pairing({
    required this.network,
    required this.telemetry,
    required this.myName,
    required this.clock,
  });

  final Network network;
  final LineTelemetry telemetry;
  final String myName;
  final Clock clock;

  final _watch = Stopwatch();
  final _changes = StreamController<void>.broadcast();
  final List<PairingStep> _steps = [];

  List<PairingStep> get steps => List.unmodifiable(_steps);

  Stream<void> get changes => _changes.stream;

  PairingStage get stage => _stage;
  PairingStage _stage = PairingStage.starting;

  Object? get error => _error;
  Object? _error;

  /// Known once both keys are.
  SafetyCode? get code => _code;
  SafetyCode? _code;

  String? get partnerName => _partnerName;
  String? _partnerName;

  bool get isOver => switch (_stage) {
    PairingStage.paired ||
    PairingStage.cancelled ||
    PairingStage.failed => true,
    _ => false,
  };

  void step(String label) {
    _steps.add(PairingStep(label, _watch.elapsed));
    telemetry.log.info('pair', label);
    _notify();
  }

  void setStage(PairingStage stage, {Object? error}) {
    _stage = stage;
    if (error != null) {
      _error = error;
      telemetry.error('pair', error);
    }
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}

/// The host's side. Serves `/v1/pair` with an open allowlist; the first guest
/// to send `pair` gets the symbols, others are turned away.
///
/// After [confirm] the line restarts the server with only the guest allowed.
/// `allowClient` alone would keep already-connected clients, which the host
/// can't tell apart. [cancel] discards the keys, so the shown invite dies.
final class HostPairing extends _Pairing {
  HostPairing({
    required super.network,
    required super.telemetry,
    required super.myName,
    super.clock = systemClock,
    this.region,
  });

  /// `null` picks the nearest public relay.
  final Map<String, Object?>? region;

  TailcatKeys? _keys;
  HostLink? _link;
  MessageChannel? _channel;
  StreamSubscription<IncomingChannel>? _incoming;

  /// Secret.
  TailcatAddress? get address => _address;
  TailcatAddress? _address;

  AddressFacts? get addressFacts => _addressFacts;
  AddressFacts? _addressFacts;

  String? get serverKey => _keys?.publicKey;

  String? get tunnelAddress => _tunnelAddress;
  String? _tunnelAddress;

  String? get guestKey => _guestKey;
  String? _guestKey;

  /// Until the string is tied, anyone with the address may connect.
  bool get allowlistOpen => stage != PairingStage.paired;

  List<OpenResource> get resources => _link?.resources ?? const [];

  Future<void> start() async {
    _watch.start();
    try {
      final keys = _keys = network.generateKeys();
      step('generated the server keys (public ${keys.publicKey})');
      final link = await network.startHost(
        HostConfig(
          privateKey: keys.privateKey,
          presharedKey: keys.presharedKey,
          region: region,
          paths: const {pairPath},
        ),
      );
      if (stage == PairingStage.cancelled) {
        await link.close(drain: false);
        return;
      }
      _link = link;
      _address = link.address;
      _addressFacts = link.addressFacts;
      _tunnelAddress = link.tunnelAddress;
      telemetry.time('server start', _watch.elapsed);
      step(
        'server started on relay ${link.addressFacts.relay?.label ?? '?'}, '
        'allowlist open, serving $pairPath',
      );
      _incoming = link.channels.listen(_onChannel);
      setStage(PairingStage.waiting);
    } on TailcatException catch (e) {
      setStage(PairingStage.failed, error: e);
    }
  }

  Future<void> _onChannel(IncomingChannel incoming) async {
    if (stage != PairingStage.waiting) {
      telemetry.log.info(
        'pair',
        'turned away a second guest from ${incoming.remoteEndpoint}',
      );
      await incoming.channel.close(4409, 'busy');
      return;
    }
    step('WebSocket upgraded on $pairPath from ${incoming.remoteEndpoint}');
    final Greeting greeting;
    try {
      greeting = await readGreeting(
        incoming.channel,
        telemetry: telemetry,
        timeout: const Duration(seconds: 30),
      );
    } on TimeoutException {
      return;
    }
    final pair = greeting.message;
    if (pair is! PairMessage || stage != PairingStage.waiting) {
      await greeting.channel.close();
      return;
    }
    _channel = greeting.channel;
    _partnerName = pair.name;
    _guestKey = pair.key;
    _code = SafetyCode.compute(hostKey: _link!.publicKey, guestKey: pair.key);
    step('"pair" from ${pair.name}, key ${pair.key}');
    setStage(PairingStage.checking);
    // A guest leaving before confirmation frees the slot for the next one.
    greeting.channel.messages.listen(
      null,
      onDone: () {
        if (stage != PairingStage.checking) return;
        _channel = null;
        _code = null;
        _partnerName = null;
        _guestKey = null;
        step('the guest left before the symbols were confirmed');
        setStage(PairingStage.waiting);
      },
    );
  }

  /// The user confirmed the symbols match.
  Future<HostIdentity> confirm({
    required Future<void> Function(HostIdentity identity) save,
  }) async {
    final keys = _keys;
    final link = _link;
    final channel = _channel;
    final guestKey = _guestKey;
    if (stage != PairingStage.checking ||
        keys == null ||
        link == null ||
        channel == null ||
        guestKey == null) {
      throw StateError('nothing to confirm');
    }
    setStage(PairingStage.confirming);
    final facts = link.addressFacts;
    final identity = HostIdentity(
      privateKey: keys.privateKey,
      presharedKey: keys.presharedKey,
      // Same keys and region give the same address, so the guest's copy
      // keeps working.
      region: facts.regions.isEmpty ? null : facts.regions.first,
      regionId: facts.regions.isEmpty && facts.regionId != 0
          ? facts.regionId
          : null,
      partnerKey: guestKey,
      partnerName: partnerName ?? '',
      tiedAt: clock(),
    );
    await save(identity);
    step('saved the string: keys, relay region, the guest\'s key');
    sendControl(channel, PairedMessage(name: myName), telemetry);
    await channel.close(1000, 'paired');
    step('sent "paired"');
    await _incoming?.cancel();
    await link.close();
    _link = null;
    step('closed the open server; restarting with the allowlist closed');
    setStage(PairingStage.paired);
    return identity;
  }

  Future<void> cancel() async {
    if (isOver) return;
    setStage(PairingStage.cancelled);
    await _incoming?.cancel();
    await _channel?.close(4000, 'cancelled');
    await _link?.close(drain: false);
    _link = null;
    _keys = null;
    step('cancelled; the keys are thrown away');
  }
}

/// The guest's side: sends `pair` on `/v1/pair` and saves on `paired`.
final class GuestPairing extends _Pairing {
  GuestPairing({
    required super.network,
    required super.telemetry,
    required super.myName,
    super.clock = systemClock,
    this.connectTimeout = const Duration(seconds: 30),
  });

  final Duration connectTimeout;

  /// The whole [text] if it is an address, else the first word that is.
  static TailcatAddress? findInvite(Network network, String text) {
    final candidates = [text.trim(), ...text.split(RegExp(r'\s+'))];
    for (final candidate in candidates) {
      if (candidate.isEmpty) continue;
      final address = TailcatAddress(candidate);
      try {
        network.parseAddress(address);
        return address;
      } on TailcatArgumentException {
        continue;
      }
    }
    return null;
  }

  GuestLink? _link;
  MessageChannel? _channel;

  /// Secret.
  TailcatAddress? get invite => _invite;
  TailcatAddress? _invite;

  AddressFacts? get inviteFacts => _facts;
  AddressFacts? _facts;

  String? get clientKey => _clientKey;
  String? _clientKey;

  List<OpenResource> get resources => _link?.resources ?? const [];

  /// [save] stores the string once the host confirms.
  Future<void> start(
    TailcatAddress invite, {
    required Future<void> Function(GuestIdentity identity) save,
  }) async {
    _watch.start();
    _invite = invite;
    try {
      final facts = _facts = network.parseAddress(invite);
      step(
        'parsed the invite: server ${facts.publicKey}, relay '
        '${facts.relay?.label ?? 'by region id ${facts.regionId}'}',
      );
      final keys = network.generateKeys();
      step('generated the client key (public ${keys.publicKey})');
      _clientKey = keys.publicKey;
      final link = _link = network.openGuest(
        address: invite,
        privateKey: keys.privateKey,
      );
      final channel = await link.connect(pairPath, timeout: connectTimeout);
      if (isOver) {
        await channel.close();
        return;
      }
      telemetry.time('WebSocket connect', _watch.elapsed);
      step('WebSocket connected to $pairPath');
      sendControl(
        channel,
        PairMessage(name: myName, key: link.publicKey),
        telemetry,
      );
      _code = SafetyCode.compute(
        hostKey: facts.publicKey,
        guestKey: link.publicKey,
      );
      step('sent "pair"; showing the symbols');
      setStage(PairingStage.checking);
      _channel = channel;
      final greeting = await readGreeting(channel, telemetry: telemetry);
      final paired = greeting.message;
      if (paired is! PairedMessage) {
        if (!isOver) {
          step('the host closed the connection without confirming');
          setStage(PairingStage.cancelled);
        }
        await _close();
        return;
      }
      _partnerName = paired.name;
      step('"paired" from ${paired.name}');
      await save(
        GuestIdentity(
          privateKey: keys.privateKey,
          publicKey: keys.publicKey,
          hostAddress: invite,
          partnerName: paired.name,
          tiedAt: clock(),
        ),
      );
      step('saved the string: client key and the host\'s address');
      await _close();
      setStage(PairingStage.paired);
    } on TailcatArgumentException catch (e) {
      setStage(PairingStage.failed, error: e);
      await _close();
    } on TimeoutException catch (e) {
      if (!isOver) setStage(PairingStage.failed, error: e);
      await _close();
    } on ProtocolMismatchException catch (e) {
      setStage(PairingStage.failed, error: e);
      await _close();
    } on Exception catch (e) {
      if (!isOver) setStage(PairingStage.failed, error: e);
      await _close();
    }
  }

  Future<void> cancel() async {
    if (isOver) return;
    setStage(PairingStage.cancelled);
    step('cancelled');
    await _close();
  }

  Future<void> _close() async {
    final channel = _channel;
    _channel = null;
    await channel?.close();
    final link = _link;
    _link = null;
    await link?.close();
  }
}
