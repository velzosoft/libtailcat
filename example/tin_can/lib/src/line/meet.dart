// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:math' as math;

/// 0..1 on each axis of the canvas.
typedef Fingertip = ({double x, double y});

/// Fingertips meet when both are down within [distance] for [hold]. They must
/// part by [rearmDistance], or lift, before meeting again.
final class MeetDetector {
  MeetDetector({
    this.distance = 0.06,
    this.rearmDistance = 0.12,
    this.hold = const Duration(milliseconds: 250),
  });

  /// A fraction of the canvas.
  final double distance;

  final double rearmDistance;

  final Duration hold;

  Duration? _closeSince;
  bool _armed = true;

  /// The caller should check again shortly even if nothing moves.
  bool get isPending => _armed && _closeSince != null;

  /// [now] is on any monotonic timeline; `null` means that finger is up.
  /// Returns `true` once per meet.
  bool update(Duration now, Fingertip? local, Fingertip? partner) {
    if (local == null || partner == null) {
      _closeSince = null;
      _armed = true;
      return false;
    }
    final apart = math.sqrt(
      math.pow(local.x - partner.x, 2) + math.pow(local.y - partner.y, 2),
    );
    if (!_armed) {
      if (apart > rearmDistance) _armed = true;
      return false;
    }
    if (apart > distance) {
      _closeSince = null;
      return false;
    }
    final since = _closeSince ??= now;
    if (now - since < hold) return false;
    _closeSince = null;
    _armed = false;
    return true;
  }
}
