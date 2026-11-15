// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:io';

import '../bindings/tailcat_bindings.g.dart';

/// Base class of every Tailcat error; sealed, one subclass per C status code.
///
/// Branch on the type, never on [message], which is not stable.
sealed class TailcatException implements IOException {
  const TailcatException(this.message);

  /// Human-readable description. Never contains a secret.
  final String message;

  String get _name;

  @override
  String toString() => '$_name: $message';
}

/// An argument was rejected, e.g. a malformed key or an oversized datagram.
final class TailcatArgumentException extends TailcatException {
  /// Creates the exception.
  const TailcatArgumentException(super.message);

  @override
  String get _name => 'TailcatArgumentException';
}

/// The resource, or the client or server that owns it, has been closed.
final class TailcatClosedException extends TailcatException {
  /// Creates the exception with an optional custom [message].
  const TailcatClosedException([super.message = 'the resource is closed']);

  @override
  String get _name => 'TailcatClosedException';
}

/// The operation timed out. Also a [TimeoutException].
final class TailcatTimeoutException extends TailcatException
    implements TimeoutException {
  /// Creates the exception; [duration] is the timeout that elapsed, if known.
  const TailcatTimeoutException(super.message, [this.duration]);

  @override
  final Duration? duration;

  @override
  String get _name => 'TailcatTimeoutException';
}

/// The operation was cancelled before it finished.
final class TailcatCancelledException extends TailcatException {
  /// Creates the exception with an optional custom [message].
  const TailcatCancelledException([
    super.message = 'the operation was cancelled',
  ]);

  @override
  String get _name => 'TailcatCancelledException';
}

/// Any other failure: network, relay, peer or the native library.
final class TailcatFailureException extends TailcatException {
  /// Creates the exception.
  const TailcatFailureException(super.message);

  @override
  String get _name => 'TailcatFailureException';
}

/// The exception for a failed `TC_*` [status] from [operation].
TailcatException exceptionForStatus(
  int status, {
  required String operation,
  String? message,
}) {
  final text = message == null || message.isEmpty
      ? '$operation failed'
      : '$operation: $message';
  return switch (status) {
    TC_INVALID_ARGUMENT => TailcatArgumentException(text),
    TC_CLOSED => TailcatClosedException(text),
    TC_TIMEOUT => TailcatTimeoutException(text),
    TC_CANCELLED => TailcatCancelledException(text),
    _ => TailcatFailureException(text),
  };
}
