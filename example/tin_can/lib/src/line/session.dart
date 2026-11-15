// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:typed_data';

import 'package:libtailcat/libtailcat.dart';

import '../telemetry/channel_stats.dart';
import '../telemetry/wire_tap.dart';
import 'datagrams.dart';
import 'identity.dart';
import 'meet.dart';
import 'messages.dart';
import 'path.dart';
import 'relays.dart';
import 'telemetry.dart';
import 'transport.dart';

enum SessionEnd {
  hungUp,
  partnerHungUp,
  cut,

  /// This side deletes the string too.
  partnerCut,

  /// The WebSocket ended without a goodbye.
  lost,

  /// The host accepted a newer WebSocket from the guest.
  replaced,
}

sealed class SessionEvent {
  const SessionEvent();
}

final class PartnerTouched extends SessionEvent {
  const PartnerTouched(this.touch);

  final TouchDatagram touch;
}

final class Plucked extends SessionEvent {
  const Plucked();
}

final class FingertipsMet extends SessionEvent {
  const FingertipsMet();
}

final class PartnerTalking extends SessionEvent {
  const PartnerTalking(this.on);

  final bool on;
}

/// 20 ms of the partner's voice arrived.
final class VoiceArrived extends SessionEvent {
  const VoiceArrived(this.frame, this.arrival);

  final VoiceDatagram frame;

  /// On the session's monotonic clock.
  final Duration arrival;
}

/// The guest's own probe, or on the host, what the guest reported.
final class PathReported extends SessionEvent {
  const PathReported(this.report);

  final PathReport report;
}

final class SessionEnded extends SessionEvent {
  const SessionEnded(this.reason);

  final SessionEnd reason;
}

/// A live line: the control WebSocket and the UDP flow, after hello.
///
/// Only the host decides when fingertips meet; only the guest reports the path.
final class Session {
  Session({
    required this.role,
    required this.partnerName,
    required this._control,
    required this._telemetry,
    this.embeddedRelay,
    this.pingInterval = const Duration(seconds: 2),
    this.echoInterval = const Duration(seconds: 1),
    this.touchInterval = const Duration(microseconds: 1000000 ~/ 60),
    this.touchTimeout = const Duration(milliseconds: 500),
  }) : _meet = role == Role.host ? MeetDetector() : null;

  final Role role;

  final String partnerName;

  /// Puts a city to relay codes.
  final RelayInfo? embeddedRelay;

  final Duration pingInterval;

  /// Echo datagrams also keep the UDP flow alive.
  final Duration echoInterval;

  final Duration touchInterval;

  /// A silent partner fingertip counts as lifted after this, in case the
  /// lift datagram was lost.
  final Duration touchTimeout;

  final MessageChannel _control;
  final LineTelemetry _telemetry;
  final MeetDetector? _meet;
  final _clock = Stopwatch()..start();
  final _events = StreamController<SessionEvent>.broadcast();
  final _ended = Completer<SessionEnd>();
  final _touchSeq = SeqCounter();
  final _voiceSeq = SeqCounter();
  final _echoSeq = SeqCounter();

  StreamSubscription<String>? _controlSubscription;
  DatagramFlow? _flow;
  StreamSubscription<Uint8List>? _flowSubscription;
  Timer? _pingTimer;
  Timer? _echoTimer;
  Timer? _touchTimer;
  Timer? _meetTimer;
  bool _firstDatagram = true;
  int _voiceSampleTime = 0;
  Duration _lastTouchSent = Duration.zero;
  Fingertip? _localTip;
  Fingertip _lastLocalTip = (x: 0.5, y: 0.5);
  TouchDatagram? _partnerTouch;
  Duration? _partnerTouchArrival;

  /// Ends after [SessionEnded].
  Stream<SessionEvent> get events => _events.stream;

  Future<SessionEnd> get ended => _ended.future;

  bool get isOpen => !_ended.isCompleted;

  /// The session's monotonic clock.
  Duration get elapsed => _clock.elapsed;

  DatagramFlow? get flow => _flow;

  bool get talking => _talking;
  bool _talking = false;

  bool get partnerTalking => _partnerTalking;
  bool _partnerTalking = false;

  TouchDatagram? get partnerTouch => _partnerTouch;

  Duration? get partnerTouchAge {
    final arrival = _partnerTouchArrival;
    return arrival == null ? null : elapsed - arrival;
  }

  /// `null` unless the partner's fingertip is down and fresh.
  Fingertip? get partnerTip {
    final touch = _partnerTouch;
    final age = partnerTouchAge;
    if (touch == null || !touch.isDown || age == null || age > touchTimeout) {
      return null;
    }
    return (x: touch.dx, y: touch.dy);
  }

  Fingertip? get localTip => _localTip;

  void start() {
    _telemetry.startSession();
    _controlSubscription = _control.messages.listen(
      _onMessage,
      onDone: () => _end(SessionEnd.lost),
    );
    _pingTimer = Timer.periodic(pingInterval, (_) => _ping());
  }

  /// Replaces any earlier flow. The guest echoes at once so the host sees
  /// the flow.
  void attachFlow(DatagramFlow flow) {
    if (!isOpen) {
      unawaited(flow.close());
      return;
    }
    final previous = _flow;
    if (previous != null) {
      unawaited(_flowSubscription?.cancel());
      unawaited(previous.close());
    }
    _flow = flow;
    _flowSubscription = flow.datagrams.listen(_onDatagram);
    _echoTimer?.cancel();
    _echoTimer = Timer.periodic(echoInterval, (_) => _echo());
    if (role == Role.guest) _echo();
  }

  /// Lifts the fingertip with `null`. Sends at most one datagram per
  /// [touchInterval] while down, plus one on lift.
  void touch(Fingertip? tip) {
    if (!isOpen) return;
    final wasDown = _localTip != null;
    _localTip = tip;
    if (tip == null) {
      _touchTimer?.cancel();
      _touchTimer = null;
      if (wasDown) _sendTouch(_lastLocalTip, down: false);
    } else {
      _lastLocalTip = tip;
      final since = elapsed - _lastTouchSent;
      if (since >= touchInterval) {
        _sendTouch(tip, down: true);
      } else {
        _touchTimer ??= Timer(touchInterval - since, () {
          _touchTimer = null;
          final latest = _localTip;
          if (latest != null && isOpen) _sendTouch(latest, down: true);
        });
      }
    }
    _checkMeet();
  }

  void pluck() => _send(const PluckMessage());

  void setTalking(bool on) {
    if (on == _talking || !isOpen) return;
    _talking = on;
    _send(TalkMessage(on: on));
  }

  /// 20 ms of voice: 320 μ-law samples.
  void sendVoice(Uint8List samples) {
    final frame = VoiceDatagram(
      seq: _voiceSeq.next(),
      sampleTime: _voiceSampleTime,
      samples: samples,
    );
    _voiceSampleTime =
        (_voiceSampleTime + VoiceDatagram.samplesPerFrame) & 0xFFFFFFFF;
    _sendDatagram(frame, 'voice');
  }

  /// The guest's own probe; also tells the host.
  void reportPath(PathReport report, {Duration? relayRtt}) {
    if (!isOpen) return;
    _telemetry.recordPath(report);
    _events.add(PathReported(report));
    _send(report.toMessage(relayRtt: relayRtt));
  }

  Future<void> hangUp() => _finish(const ByeMessage(), SessionEnd.hungUp);

  /// The partner deletes the string too.
  Future<void> cut() => _finish(const CutMessage(), SessionEnd.cut);

  Future<void> replace() async {
    _end(SessionEnd.replaced);
    await _control.close();
  }

  Future<void> _finish(ControlMessage goodbye, SessionEnd reason) async {
    if (!isOpen) return;
    _send(goodbye);
    _end(reason);
    await _control.close();
  }

  void _onMessage(String text) {
    final ControlMessage? message;
    try {
      message = ControlMessage.decode(text);
    } on FormatException catch (e) {
      _telemetry.control.recordReceived(text.length);
      _telemetry.log.info('ws', 'dropped a malformed message: ${e.message}');
      return;
    }
    _telemetry.controlReceived(text, message);
    switch (message) {
      case PingMessage(:final t):
        _send(PongMessage(t: t));
      case PongMessage(:final t):
        _telemetry.controlRtt.add(Duration(milliseconds: _nowMs - t));
      case PluckMessage():
        _events.add(const Plucked());
      case MeetMessage():
        // Only the host decides.
        if (role == Role.guest) _events.add(const FingertipsMet());
      case TalkMessage(:final on):
        _partnerTalking = on;
        _events.add(PartnerTalking(on));
      case PathMessage() when role == Role.host:
        final report = PathReport.fromMessage(
          message,
          at: _telemetry.clock(),
          embeddedRelay: embeddedRelay,
        );
        _telemetry.recordPath(report);
        final relayMs = message.relayMs;
        if (relayMs != null) {
          _telemetry.relayLatency.add(
            Duration(microseconds: (relayMs * 1000).round()),
          );
        }
        _events.add(PathReported(report));
      case ByeMessage():
        _telemetry.log.info('ws', 'the partner hung up');
        _end(SessionEnd.partnerHungUp);
        unawaited(_control.close());
      case CutMessage():
        _telemetry.log.info('ws', 'the partner cut the string');
        _end(SessionEnd.partnerCut);
        unawaited(_control.close());
      case PathMessage() ||
          PairMessage() ||
          PairedMessage() ||
          HelloMessage() ||
          WelcomeMessage() ||
          null:
        break;
    }
  }

  void _onDatagram(Uint8List bytes) {
    final datagram = Datagram.decode(bytes);
    if (datagram == null) return;
    if (_firstDatagram) {
      _firstDatagram = false;
      _telemetry.time('first datagram', elapsed);
      final flow = _flow;
      _telemetry.log.info(
        'udp',
        'first datagram on the flow '
            '${flow?.localEndpoint} ← ${flow?.remoteEndpoint}',
      );
    }
    final channel = _channelOf(datagram);
    _telemetry.tap.record(
      direction: WireDirection.received,
      channel: _channelName(datagram),
      bytes: bytes.length,
      summary: datagram.describe(),
      raw: WireTap.hex(bytes),
    );
    switch (datagram) {
      case TouchDatagram():
        channel.recordReceived(bytes.length, seq: datagram.seq);
        final previous = _partnerTouch;
        // UDP may reorder: keep only the newest position.
        if (previous == null ||
            isNewerSeq(datagram.seq, previous.seq) ||
            (partnerTouchAge ?? Duration.zero) > touchTimeout) {
          _partnerTouch = datagram;
          _partnerTouchArrival = elapsed;
          _events.add(PartnerTouched(datagram));
          _checkMeet();
        }
      case VoiceDatagram():
        channel.recordReceived(bytes.length, seq: datagram.seq);
        _events.add(VoiceArrived(datagram, elapsed));
      case EchoDatagram():
        channel.recordReceived(bytes.length, seq: datagram.seq);
        _sendDatagram(EchoReplyDatagram.to(datagram), 'echo reply');
      case EchoReplyDatagram(:final time):
        channel.recordReceived(bytes.length);
        final rtt = (_nowMs - time) & 0xFFFFFFFF;
        _telemetry.datagramRtt.add(Duration(milliseconds: rtt));
    }
  }

  void _ping() => _send(PingMessage(t: _nowMs));

  void _echo() => _sendDatagram(
    EchoDatagram(seq: _echoSeq.next(), time: _nowMs & 0xFFFFFFFF),
    'echo',
  );

  void _sendTouch(Fingertip tip, {required bool down}) {
    _lastTouchSent = elapsed;
    _sendDatagram(
      TouchDatagram.at(seq: _touchSeq.next(), x: tip.x, y: tip.y, down: down),
      'touch',
    );
  }

  /// Re-runs shortly while a meet is pending: still fingers send no events.
  void _checkMeet() {
    final meet = _meet;
    if (meet == null || !isOpen) return;
    _meetTimer?.cancel();
    _meetTimer = null;
    if (meet.update(elapsed, _localTip, partnerTip)) {
      _telemetry.log.info('meet', 'the fingertips met');
      _send(const MeetMessage());
      _events.add(const FingertipsMet());
    } else if (meet.isPending) {
      _meetTimer = Timer(const Duration(milliseconds: 50), _checkMeet);
    }
  }

  void _send(ControlMessage message) {
    if (!isOpen) return;
    final text = message.encode();
    _control.send(text);
    _telemetry.controlSent(message, text);
  }

  void _sendDatagram(Datagram datagram, String channelName) {
    final flow = _flow;
    if (flow == null || !isOpen) return;
    final bytes = datagram.encode();
    _channelOf(datagram).recordSent(bytes.length);
    _telemetry.tap.record(
      direction: WireDirection.sent,
      channel: channelName,
      bytes: bytes.length,
      summary: datagram.describe(),
      raw: WireTap.hex(bytes),
    );
    flow.send(bytes).catchError((Object error) {
      // A closed flow ends the session, handled elsewhere.
      if (error is! TailcatClosedException) {
        _telemetry.error('udp', error);
      }
    });
  }

  void _end(SessionEnd reason) {
    if (_ended.isCompleted) return;
    _clock.stop();
    for (final timer in [_pingTimer, _echoTimer, _touchTimer, _meetTimer]) {
      timer?.cancel();
    }
    unawaited(_controlSubscription?.cancel());
    unawaited(_flowSubscription?.cancel());
    final flow = _flow;
    if (flow != null) unawaited(flow.close());
    _telemetry.log.info('session', 'ended: ${reason.name}');
    _ended.complete(reason);
    _events.add(SessionEnded(reason));
    unawaited(_events.close());
  }

  int get _nowMs => _clock.elapsedMilliseconds;

  ChannelStats _channelOf(Datagram datagram) => switch (datagram) {
    TouchDatagram() => _telemetry.touch,
    VoiceDatagram() => _telemetry.voice,
    EchoDatagram() || EchoReplyDatagram() => _telemetry.echo,
  };

  static String _channelName(Datagram datagram) => switch (datagram) {
    TouchDatagram() => 'touch',
    VoiceDatagram() => 'voice',
    EchoDatagram() => 'echo',
    EchoReplyDatagram() => 'echo reply',
  };
}
