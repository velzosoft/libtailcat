// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import '../bindings/native_api.dart' as native;
import 'errors.dart';
import 'worker.dart';

/// Starts the worker behind a [WorkerStream].
typedef WorkerSpawner =
    Worker Function({
      required void Function(Object event) onEvent,
      required void Function(Object? error) onExit,
    });

/// A stream fed by a worker loop, with credit-based backpressure ([Credits]).
///
/// The worker starts on listen. EOF, close and cancel end the stream quietly;
/// other statuses arrive as a [TailcatException] first.
final class WorkerStream<T> {
  /// [discard] releases events arriving after the end; [onEnded] runs once
  /// with the ending error, if any; [operation] names the loop in errors.
  WorkerStream({
    required WorkerSpawner spawn,
    required T Function(Object event) decode,
    required String operation,
    void Function(Object event)? discard,
    void Function(Object? error)? onEnded,
  }) : _spawn = spawn,
       _decode = decode,
       _operation = operation,
       _discard = discard,
       _onEnded = onEnded;

  final WorkerSpawner _spawn;
  final T Function(Object event) _decode;
  final String _operation;
  final void Function(Object event)? _discard;
  final void Function(Object? error)? _onEnded;

  late final StreamController<T> _controller = StreamController<T>(
    onListen: _start,
    onResume: _grantOwed,
    onCancel: stop,
  );
  Worker? _worker;
  int _owed = 0;
  bool _ended = false;

  /// The items the worker produces.
  Stream<T> get stream => _controller.stream;

  /// Whether the stream has ended, for whatever reason.
  bool get hasEnded => _ended;

  /// Ends the stream without an error and stops the worker. Idempotent.
  void stop() => _finish(null);

  void _start() {
    if (_ended) return;
    _worker = _spawn(onEvent: _onEvent, onExit: _onExit);
  }

  void _onEvent(Object event) {
    if (_ended) {
      if (event is! WorkerEnded) _discard?.call(event);
      return;
    }
    if (event is WorkerEnded) {
      _finish(_errorFor(event));
      return;
    }
    final T item;
    try {
      item = _decode(event);
    } catch (error) {
      // A throw in a port handler would be uncaught; send it to the listener.
      _finish(error);
      return;
    }
    _controller.add(item);
    if (_controller.isPaused) {
      _owed++;
    } else {
      _worker?.send(1);
    }
  }

  void _grantOwed() {
    if (_owed == 0) return;
    _worker?.send(_owed);
    _owed = 0;
  }

  void _onExit(Object? error) => _finish(
    error ?? TailcatClosedException('$_operation: the worker went away'),
  );

  Object? _errorFor(WorkerEnded ended) => switch (ended.status) {
    native.TC_EOF || native.TC_CLOSED || native.TC_CANCELLED => null,
    _ => exceptionForStatus(
      ended.status,
      operation: _operation,
      message: ended.message,
    ),
  };

  void _finish(Object? error) {
    if (_ended) return;
    _ended = true;
    _worker?.stop();
    if (error != null) _controller.addError(error);
    _controller.close();
    _onEnded?.call(error);
  }
}
