// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'line_end.dart';
import 'path.dart';

/// How the string between the cans is drawn.
enum StringState {
  /// No partner online.
  slack,

  /// Dialing or waiting for the guest.
  pulling,

  /// Taut, bent over a peg labelled with the relay's city.
  relayed,
  direct,
}

/// Covers a partner who is just opening the app.
const pullingGrace = Duration(seconds: 20);

/// Connected with no path report yet counts as pulling: the first probe
/// comes within a second.
StringState stringStateFor(
  LineStatus status, {
  required PathReport? path,
  required DateTime now,
}) => switch (status.phase) {
  LinePhase.offline => StringState.slack,
  LinePhase.connecting => StringState.pulling,
  LinePhase.waiting =>
    now.difference(status.since) < pullingGrace
        ? StringState.pulling
        : StringState.slack,
  LinePhase.connected => switch (path) {
    null => StringState.pulling,
    PathReport(direct: true) => StringState.direct,
    PathReport(direct: false) => StringState.relayed,
  },
};

/// 0 (still) to 1.
double trembleFor(Duration? latency) {
  if (latency == null) return 0;
  final ms = latency.inMicroseconds / 1000;
  return ((ms - 10) / 250).clamp(0.0, 1.0);
}
