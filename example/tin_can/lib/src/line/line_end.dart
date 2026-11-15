// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'identity.dart';
import 'session.dart';
import 'telemetry.dart';
import 'transport.dart';

enum LinePhase {
  /// The app is in the background or hasn't started.
  offline,

  /// The partner isn't there.
  waiting,

  /// The guest is dialing, or the host waits for `hello`.
  connecting,
  connected,
}

enum LineProblem {
  none,

  /// A `TailcatFailureException`; the line retries.
  network,

  /// The other side doesn't serve this protocol version.
  mismatch,
}

final class LineStatus {
  const LineStatus(this.phase, this.since, {this.problem = LineProblem.none});

  final LinePhase phase;

  final DateTime since;

  final LineProblem problem;

  @override
  String toString() => 'LineStatus(${phase.name}, ${problem.name})';
}

/// One end of a tied string while the app is in the foreground.
abstract class LineEnd {
  LineEnd({required this.telemetry, required this.clock});

  final LineTelemetry telemetry;

  final DateTime Function() clock;

  Role get role;

  LineStatus get status => _status;
  late LineStatus _status = LineStatus(LinePhase.offline, clock());

  final _statusChanges = StreamController<LineStatus>.broadcast();
  final _sessions = StreamController<Session>.broadcast();

  Stream<LineStatus> get statusChanges => _statusChanges.stream;

  Stream<Session> get sessions => _sessions.stream;

  Session? get session => _session;
  Session? _session;

  String get partnerName;

  List<OpenResource> get resources;

  Future<void> start();

  /// Says goodbye if a session is going. With [drain] the tunnel first
  /// delivers what was sent.
  Future<void> stop({bool drain = true});

  void setStatus(LinePhase phase, {LineProblem problem = LineProblem.none}) {
    if (phase == _status.phase && problem == _status.problem) return;
    _status = LineStatus(phase, clock(), problem: problem);
    if (!_statusChanges.isClosed) _statusChanges.add(_status);
  }

  void setSession(Session? session) {
    _session = session;
    if (session != null && !_sessions.isClosed) _sessions.add(session);
  }

  /// Call after the last [stop].
  Future<void> dispose() async {
    await _statusChanges.close();
    await _sessions.close();
  }
}

/// The guest's wait after [failures] timeouts in a row.
Duration dialBackoff(int failures) => switch (failures) {
  <= 1 => const Duration(seconds: 1),
  2 => const Duration(seconds: 2),
  3 => const Duration(seconds: 4),
  _ => const Duration(seconds: 10),
};

/// A sleep that [cancel] cuts short.
final class Sleeper {
  final _pending = <Completer<void>, Timer>{};

  Future<void> sleep(Duration duration) {
    final done = Completer<void>();
    _pending[done] = Timer(duration, () {
      _pending.remove(done);
      done.complete();
    });
    return done.future;
  }

  void cancel() {
    for (final MapEntry(key: done, value: timer) in _pending.entries) {
      timer.cancel();
      done.complete();
    }
    _pending.clear();
  }
}
