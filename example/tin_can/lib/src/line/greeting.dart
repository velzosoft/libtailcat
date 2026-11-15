// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'messages.dart';
import 'telemetry.dart';
import 'transport.dart';

final class Greeting {
  const Greeting(this.message, this.channel);

  /// `null` when the channel ended first, or the message was malformed or of
  /// an unknown type.
  final ControlMessage? message;

  /// Delivers the messages after the first.
  final MessageChannel channel;
}

void sendControl(
  MessageChannel channel,
  ControlMessage message,
  LineTelemetry telemetry,
) {
  final text = message.encode();
  channel.send(text);
  telemetry.controlSent(message, text);
}

/// `channel.messages.first` would close the WebSocket by cancelling its only
/// subscription, so this keeps it and passes on the rest.
///
/// On [TimeoutException] the channel is closed.
Future<Greeting> readGreeting(
  MessageChannel channel, {
  required LineTelemetry telemetry,
  Duration? timeout,
}) async {
  final rest = StreamController<String>();
  final first = Completer<String?>();
  final subscription = channel.messages.listen(
    (text) => first.isCompleted ? rest.add(text) : first.complete(text),
    onError: rest.addError,
    onDone: () {
      if (!first.isCompleted) first.complete(null);
      rest.close();
    },
  );
  rest
    ..onPause = subscription.pause
    ..onResume = subscription.resume
    ..onCancel = subscription.cancel;
  final String? text;
  try {
    text = timeout == null
        ? await first.future
        : await first.future.timeout(timeout);
  } on TimeoutException {
    await subscription.cancel();
    await channel.close();
    rethrow;
  }
  ControlMessage? message;
  if (text != null) {
    try {
      message = ControlMessage.decode(text);
      telemetry.controlReceived(text, message);
    } on FormatException catch (e) {
      telemetry.log.info('ws', 'malformed first message: ${e.message}');
    }
  }
  return Greeting(message, _RestOfChannel(channel, rest.stream));
}

final class _RestOfChannel implements MessageChannel {
  _RestOfChannel(this._channel, this.messages);

  final MessageChannel _channel;

  @override
  final Stream<String> messages;

  @override
  void send(String message) => _channel.send(message);

  @override
  Future<void> close([int? code, String? reason]) =>
      _channel.close(code, reason);

  @override
  int? get closeCode => _channel.closeCode;
}
