// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// The control protocol: one JSON object per WebSocket text message.
///
/// The version lives in the URL path. Unknown types and fields are ignored,
/// so both can be added later.
library;

import 'dart:convert';

/// In bytes.
const maxControlMessageBytes = 64 * 1024;

const maxNameLength = 40;

sealed class ControlMessage {
  const ControlMessage();

  String get type;

  /// The fields besides `type`.
  Map<String, Object?> get fields => const {};

  String encode() => jsonEncode({'type': type, ...fields});

  /// `null` for an unknown type, which is ignored. Throws [FormatException]
  /// for any other invalid message.
  static ControlMessage? decode(String text) {
    if (text.length > maxControlMessageBytes ||
        utf8.encode(text).length > maxControlMessageBytes) {
      throw const FormatException('control message too large');
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const FormatException('control message is not JSON');
    }
    if (json is! Map<String, Object?>) {
      throw const FormatException('control message is not a JSON object');
    }
    final fields = _Fields(json);
    return switch (fields.string('type')) {
      'pair' => PairMessage(name: fields.name(), key: fields.string('key')),
      'paired' => PairedMessage(name: fields.name()),
      'hello' => HelloMessage(name: fields.name()),
      'welcome' => WelcomeMessage(name: fields.name()),
      'path' => PathMessage(
        direct: fields.boolean('direct'),
        ms: fields.number('ms'),
        relay: fields.optionalString('relay'),
        relayMs: fields.optionalNumber('relayMs'),
      ),
      'pluck' => const PluckMessage(),
      'meet' => const MeetMessage(),
      'talk' => TalkMessage(on: fields.boolean('on')),
      'cut' => const CutMessage(),
      'bye' => const ByeMessage(),
      'ping' => PingMessage(t: fields.integer('t')),
      'pong' => PongMessage(t: fields.integer('t')),
      _ => null,
    };
  }

  @override
  String toString() => encode();
}

/// Guest to host on `/v1/pair`.
final class PairMessage extends ControlMessage {
  const PairMessage({required this.name, required this.key});

  final String name;

  /// The guest's public node key, for the host's allowlist.
  final String key;

  @override
  String get type => 'pair';

  @override
  Map<String, Object?> get fields => {'name': name, 'key': key};
}

/// Host to guest on `/v1/pair`: the host confirmed the safety code.
final class PairedMessage extends ControlMessage {
  const PairedMessage({required this.name});

  final String name;

  @override
  String get type => 'paired';

  @override
  Map<String, Object?> get fields => {'name': name};
}

/// Guest to host, first on `/v1/line`.
final class HelloMessage extends ControlMessage {
  const HelloMessage({required this.name});

  final String name;

  @override
  String get type => 'hello';

  @override
  Map<String, Object?> get fields => {'name': name};
}

/// Host to guest: the session is accepted.
final class WelcomeMessage extends ControlMessage {
  const WelcomeMessage({required this.name});

  final String name;

  @override
  String get type => 'welcome';

  @override
  Map<String, Object?> get fields => {'name': name};
}

/// Guest to host: the latest `discoPing`. Only a client can probe the path.
final class PathMessage extends ControlMessage {
  const PathMessage({
    required this.direct,
    required this.ms,
    this.relay,
    this.relayMs,
  });

  final bool direct;

  final double ms;

  /// Set when not direct.
  final String? relay;

  /// From `TailcatClient.ping`.
  final double? relayMs;

  @override
  String get type => 'path';

  @override
  Map<String, Object?> get fields => {
    'direct': direct,
    'ms': ms,
    'relay': ?relay,
    'relayMs': ?relayMs,
  };
}

final class PluckMessage extends ControlMessage {
  const PluckMessage();

  @override
  String get type => 'pluck';
}

/// Host to guest. Only the host decides, so both sides feel it exactly once.
final class MeetMessage extends ControlMessage {
  const MeetMessage();

  @override
  String get type => 'meet';
}

final class TalkMessage extends ControlMessage {
  const TalkMessage({required this.on});

  final bool on;

  @override
  String get type => 'talk';

  @override
  Map<String, Object?> get fields => {'on': on};
}

/// Unpair. The receiver deletes the string too.
final class CutMessage extends ControlMessage {
  const CutMessage();

  @override
  String get type => 'cut';
}

final class ByeMessage extends ControlMessage {
  const ByeMessage();

  @override
  String get type => 'bye';
}

final class PingMessage extends ControlMessage {
  const PingMessage({required this.t});

  /// The sender's clock in milliseconds; only the sender interprets it.
  final int t;

  @override
  String get type => 'ping';

  @override
  Map<String, Object?> get fields => {'t': t};
}

final class PongMessage extends ControlMessage {
  const PongMessage({required this.t});

  /// Echoes the ping's [PingMessage.t].
  final int t;

  @override
  String get type => 'pong';

  @override
  Map<String, Object?> get fields => {'t': t};
}

/// Trimmed, without control characters, at most [maxNameLength] characters.
String cleanName(String name) {
  final printable = name.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '');
  final runes = printable.trim().runes.take(maxNameLength);
  return String.fromCharCodes(runes).trim();
}

extension type const _Fields(Map<String, Object?> json) {
  String string(String key) => switch (json[key]) {
    final String value => value,
    _ => throw FormatException('"$key" must be a string'),
  };

  String? optionalString(String key) => switch (json[key]) {
    null => null,
    final String value => value,
    _ => throw FormatException('"$key" must be a string'),
  };

  String name() => cleanName(string('name'));

  bool boolean(String key) => switch (json[key]) {
    final bool value => value,
    _ => throw FormatException('"$key" must be true or false'),
  };

  double number(String key) => switch (json[key]) {
    final num value when value.isFinite => value.toDouble(),
    _ => throw FormatException('"$key" must be a number'),
  };

  double? optionalNumber(String key) => json[key] == null ? null : number(key);

  int integer(String key) => switch (json[key]) {
    final int value => value,
    _ => throw FormatException('"$key" must be an integer'),
  };
}
