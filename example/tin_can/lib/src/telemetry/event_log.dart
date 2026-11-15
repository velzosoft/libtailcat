// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:collection';

import 'clock.dart';
import 'masking.dart';

/// One log line, built from [String] and [Sensitive] parts so a secret stays
/// masked wherever the line is shown or copied.
final class LogEvent {
  LogEvent(this.at, this.category, this.parts);

  final DateTime at;

  /// A short tag such as `server`, `path` or `ws`.
  final String category;

  final List<Object> parts;

  String text(Masking masking) => parts
      .map((part) => part is Sensitive ? masking.render(part) : part as String)
      .join();

  /// `HH:mm:ss.SSS category  text`.
  String render(Masking masking) =>
      '${formatTime(at)} $category  ${text(masking)}';

  static String formatTime(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.'
        '${time.millisecond.toString().padLeft(3, '0')}';
  }
}

/// The last [capacity] events, newest last.
final class EventLog {
  EventLog({this.capacity = 500, this._clock = systemClock});

  final int capacity;

  final Clock _clock;
  final Queue<LogEvent> _events = Queue();
  final StreamController<LogEvent> _onEvent = StreamController.broadcast();

  /// Throws [ArgumentError] for parts other than [String] and [Sensitive], so
  /// a value meant to be masked can't slip in as plain text.
  void add(String category, List<Object> parts) {
    for (final part in parts) {
      if (part is! String && part is! Sensitive) {
        throw ArgumentError.value(
          part.runtimeType,
          'parts',
          'must be a String or a Sensitive',
        );
      }
    }
    final event = LogEvent(_clock(), category, List.unmodifiable(parts));
    _events.add(event);
    while (_events.length > capacity) {
      _events.removeFirst();
    }
    _onEvent.add(event);
  }

  void info(String category, String text) => add(category, [text]);

  List<LogEvent> get events => List.unmodifiable(_events);

  Stream<LogEvent> get onEvent => _onEvent.stream;

  String copyText(Masking masking) =>
      _events.map((event) => event.render(masking)).join('\n');

  void clear() => _events.clear();

  Future<void> close() => _onEvent.close();
}
