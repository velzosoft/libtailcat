// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:libtailcat/libtailcat.dart';

import '../audio/voice_engine.dart';
import '../line/guest.dart';
import '../line/host.dart';
import '../line/identity.dart';
import '../line/line_end.dart';
import '../line/messages.dart';
import '../line/pairing.dart';
import '../line/session.dart';
import '../line/telemetry.dart';
import '../line/transport.dart';
import '../store/string_store.dart';

/// Which screen the app shows.
enum AppMode {
  loading,

  welcome,

  /// The host's pairing.
  tying,

  /// The guest's pairing.
  catching,

  line,
}

/// The app's state, plus session events for effects (haptics, twang, burst).
final class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    required this.network,
    required this.voice,
    LineTelemetry? telemetry,
  }) : telemetry = telemetry ?? LineTelemetry();

  final StringStore store;

  /// libtailcat, or a fake in tests.
  final Network network;

  final VoiceEngine voice;

  final LineTelemetry telemetry;

  final _effects = StreamController<SessionEvent>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  StreamSubscription<SessionEvent>? _sessionEvents;
  StreamSubscription<void>? _pairingChanges;

  AppMode get mode => _mode;
  AppMode _mode = AppMode.loading;

  /// Empty when not set.
  String get myName => _myName;
  String _myName = '';

  StringIdentity? get identity => _identity;
  StringIdentity? _identity;

  LineEnd? get line => _line;
  LineEnd? _line;

  HostPairing? get tying => _tying;
  HostPairing? _tying;

  GuestPairing? get catching => _catching;
  GuestPairing? _catching;

  /// A one-time notice for the next screen, such as "Bea cut the string".
  String? takeNotice() {
    final notice = _notice;
    _notice = null;
    return notice;
  }

  String? _notice;

  /// The line runs only in the foreground.
  bool get inForeground => _inForeground;
  bool _inForeground = true;

  Stream<SessionEvent> get effects => _effects.stream;

  /// The host reads its own address; the guest the one it saved.
  AddressFacts? get addressFacts {
    switch (_identity) {
      case HostIdentity():
        final line = _line;
        return line is Host ? line.link?.addressFacts : null;
      case final GuestIdentity guest:
        try {
          return _guestFacts ??= network.parseAddress(guest.hostAddress);
        } on TailcatException {
          return null;
        }
      case null:
        return null;
    }
  }

  AddressFacts? _guestFacts;

  String? get ownPublicKey => switch (_identity) {
    HostIdentity() => addressFacts?.publicKey,
    final GuestIdentity guest => guest.publicKey,
    null => null,
  };

  String? get partnerPublicKey => switch (_identity) {
    final HostIdentity host => host.partnerKey,
    GuestIdentity() => addressFacts?.publicKey,
    null => null,
  };

  bool get talking => voice.isTalking;

  Future<void> init() async {
    _myName = await store.loadName();
    _identity = await store.load();
    await voice.start();
    telemetry.log.info(
      'app',
      'started; ${_identity == null ? 'no string' : 'a string is tied'}',
    );
    if (_identity == null) {
      _setMode(AppMode.welcome);
    } else {
      _setMode(AppMode.line);
      await _startLine();
    }
  }

  Future<void> setName(String name) async {
    _myName = cleanName(name);
    await store.saveName(_myName);
    switch (_line) {
      case final Host host:
        host.myName = _myName;
      case final Guest guest:
        guest.myName = _myName;
      case _:
        break;
    }
    notifyListeners();
  }

  Future<void> tie() async {
    final pairing = _tying = HostPairing(
      network: network,
      telemetry: telemetry,
      myName: _myName,
    );
    _watchPairing(pairing.changes);
    _setMode(AppMode.tying);
    await pairing.start();
  }

  /// The symbols match; the line's server restarts with the allowlist closed.
  Future<void> confirmTie() async {
    final pairing = _tying;
    if (pairing == null) return;
    final identity = await pairing.confirm(save: store.save);
    _identity = identity;
    await _endPairing();
    _setMode(AppMode.line);
    await _startLine();
  }

  void startCatching() => _setMode(AppMode.catching);

  /// Returns an error message when [text] holds no invite.
  String? catchInvite(String text) {
    final TailcatAddress? invite;
    try {
      invite = GuestPairing.findInvite(network, text);
    } on TailcatException catch (e) {
      return 'libtailcat is not available: ${e.message}';
    }
    if (invite == null) {
      return 'That is not a Tin Can invite. Ask for a new QR code.';
    }
    final pairing = _catching = GuestPairing(
      network: network,
      telemetry: telemetry,
      myName: _myName,
    );
    _watchPairing(pairing.changes);
    _setMode(AppMode.catching);
    unawaited(
      pairing.start(
        invite,
        save: (identity) async {
          await store.save(identity);
          _identity = identity;
        },
      ),
    );
    return null;
  }

  Future<void> cancelPairing() async {
    await _tying?.cancel();
    await _catching?.cancel();
    await _endPairing();
    _setMode(AppMode.welcome);
  }

  void _watchPairing(Stream<void> changes) {
    unawaited(_pairingChanges?.cancel());
    _pairingChanges = changes.listen((_) {
      final guest = _catching;
      if (guest != null &&
          guest.stage == PairingStage.paired &&
          _identity != null &&
          _mode == AppMode.catching) {
        unawaited(_caught());
      }
      notifyListeners();
    });
  }

  Future<void> _caught() async {
    await _endPairing();
    _setMode(AppMode.line);
    await _startLine();
  }

  Future<void> _endPairing() async {
    await _pairingChanges?.cancel();
    _pairingChanges = null;
    await _tying?.dispose();
    await _catching?.dispose();
    _tying = null;
    _catching = null;
  }

  Future<void> _startLine() async {
    final identity = _identity;
    if (identity == null) return;
    final line = _line = switch (identity) {
      HostIdentity() => Host(
        network: network,
        identity: identity,
        myName: _myName,
        telemetry: telemetry,
        onPartnerName: _renamed,
      ),
      GuestIdentity() => Guest(
        network: network,
        identity: identity,
        myName: _myName,
        telemetry: telemetry,
        onPartnerName: _renamed,
      ),
    };
    _subscriptions
      ..add(line.statusChanges.listen((_) => notifyListeners()))
      ..add(line.sessions.listen(_onSession));
    notifyListeners();
    if (_inForeground) await line.start();
  }

  void _renamed(StringIdentity identity) {
    _identity = identity;
    unawaited(store.save(identity));
    notifyListeners();
  }

  void _onSession(Session session) {
    voice.resetPartner();
    unawaited(_sessionEvents?.cancel());
    _sessionEvents = session.events.listen((event) {
      switch (event) {
        case VoiceArrived(:final frame, :final arrival):
          voice.metrics.networkRoundTrip = telemetry.datagramRtt.last;
          voice.receive(
            seq: frame.seq,
            sampleTime: frame.sampleTime,
            samples: frame.samples,
            arrival: arrival,
          );
          return;
        case PartnerTouched():
          // The line screen repaints the fingertip every frame anyway.
          return;
        case Plucked():
          voice.pluck();
        case SessionEnded(reason: SessionEnd.partnerCut):
          unawaited(
            _forget('${line?.partnerName ?? 'Your partner'} cut the string.'),
          );
        case SessionEnded():
          unawaited(stopTalking());
        case _:
          break;
      }
      _effects.add(event);
      notifyListeners();
    });
    notifyListeners();
  }

  /// `false` when there is no session or the microphone was denied.
  Future<bool> startTalking() async {
    final session = _line?.session;
    if (session == null || !session.isOpen) return false;
    final started = await voice.startTalking(session.sendVoice);
    if (started) session.setTalking(true);
    notifyListeners();
    return started;
  }

  Future<void> stopTalking() async {
    await voice.stopTalking();
    _line?.session?.setTalking(false);
    notifyListeners();
  }

  void pluck() {
    _line?.session?.pluck();
    voice.pluck();
  }

  /// Tells the partner if they're there, and deletes the keys for good.
  Future<void> cut() async {
    final session = _line?.session;
    if (session != null && session.isOpen) await session.cut();
    await _forget(null);
  }

  Future<void> _forget(String? notice) async {
    await stopTalking();
    final line = _line;
    _line = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _sessionEvents?.cancel();
    _sessionEvents = null;
    if (line != null) {
      await line.stop();
      await line.dispose();
    }
    await store.cut();
    _identity = null;
    _guestFacts = null;
    telemetry.log.info('app', 'the string is cut; its keys are deleted');
    _notice = notice;
    _setMode(AppMode.welcome);
  }

  /// Hangs up. Without a server nothing can wake the app, so the line exists
  /// only while both apps are open.
  Future<void> enterBackground() async {
    if (!_inForeground) return;
    _inForeground = false;
    telemetry.log.info('app', 'to the background: hanging up');
    await stopTalking();
    if (_tying != null || _catching != null) await cancelPairing();
    await _line?.stop();
    notifyListeners();
  }

  Future<void> enterForeground() async {
    if (_inForeground) return;
    _inForeground = true;
    telemetry.log.info('app', 'to the foreground');
    notifyListeners();
    await _line?.start();
  }

  void _setMode(AppMode mode) {
    _mode = mode;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_sessionEvents?.cancel());
    unawaited(_pairingChanges?.cancel());
    unawaited(_effects.close());
    unawaited(voice.dispose());
    super.dispose();
  }
}
