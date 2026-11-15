// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// How numbers read on screen.
library;

import '../line/line_end.dart';
import '../line/path.dart';
import '../line/telemetry.dart';

/// `23 ms`, `1.4 ms` or `–`.
String ms(Duration? duration) {
  if (duration == null) return '–';
  final value = duration.inMicroseconds / 1000;
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)} s';
  return value < 10 ? '${value.toStringAsFixed(1)} ms' : '${value.round()} ms';
}

String kbits(double bitsPerSecond) =>
    '${(bitsPerSecond / 1000).toStringAsFixed(1)} kbit/s';

String rate(double perSecond) => '${perSecond.toStringAsFixed(1)}/s';

String bytes(int count) => switch (count) {
  < 1024 => '$count B',
  < 1024 * 1024 => '${(count / 1024).toStringAsFixed(1)} KB',
  _ => '${(count / 1024 / 1024).toStringAsFixed(2)} MB',
};

String percent(double ratio) => '${(ratio * 100).toStringAsFixed(1)} %';

/// `nodekey:1a2b3c…9f0e`.
String shortKey(String? key) {
  if (key == null) return '–';
  final colon = key.indexOf(':');
  final prefix = colon < 0 ? '' : key.substring(0, colon + 1);
  final body = colon < 0 ? key : key.substring(colon + 1);
  if (body.length <= 12) return key;
  return '$prefix${body.substring(0, 6)}…${body.substring(body.length - 4)}';
}

String statusLine(LineStatus status, PathReport? path, String partner) {
  final name = partner.isEmpty ? 'them' : partner;
  return switch (status.phase) {
    LinePhase.connected when path == null => 'connected · probing the path',
    LinePhase.connected when path!.direct => 'direct · ${ms(path.latency)}',
    LinePhase.connected =>
      'via ${path!.relay?.label ?? 'a'} relay · ${ms(path.latency)}',
    _ when status.problem == LineProblem.mismatch =>
      '$name need${partner.isEmpty ? '' : 's'} a newer Tin Can',
    _ when status.problem == LineProblem.network => 'network trouble, retrying',
    LinePhase.connecting => 'calling $name…',
    LinePhase.waiting => 'waiting for $name to open Tin Can',
    LinePhase.offline => 'hung up',
  };
}

String? nextAttempt(LineTelemetry telemetry, DateTime now) {
  final at = telemetry.nextDialAt;
  if (at == null) return null;
  final left = at.difference(now);
  if (left.isNegative) return null;
  return 'next attempt in ${(left.inMilliseconds / 1000).toStringAsFixed(1)} s';
}
