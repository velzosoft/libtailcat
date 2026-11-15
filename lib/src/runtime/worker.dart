// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import '../bindings/native_api.dart' as native;
import 'token.dart';

/// The loop a worker runs on its helper isolate.
typedef WorkerMain<P> =
    Future<void> Function(WorkerContext context, P parameters);

/// The last event of a worker whose loop ended on a native status.
final class WorkerEnded {
  /// Creates the event.
  const WorkerEnded(this.status, [this.message]);

  /// The `TC_*` status that ended the loop.
  final int status;

  /// The native error message, if any.
  final String? message;
}

/// Owner side of a helper isolate running one blocking native loop.
///
/// Events flow to `onEvent`, commands go out with [send], and a [CancelSlot]
/// reaches the worker even inside a native call.
final class Worker {
  /// Spawns [main] with sendable [parameters]. [onExit] runs once when the
  /// isolate is gone, with the error that killed it, if any.
  static Worker spawn<P>(
    WorkerMain<P> main,
    P parameters, {
    required String debugName,
    required void Function(Object event) onEvent,
    required void Function(Object? error) onExit,
  }) {
    final worker = Worker._(onEvent, onExit);
    Isolate.spawn(
      _run<P>,
      _Boot<P>(main, parameters, worker._events.sendPort, worker._slot.address),
      onExit: worker._events.sendPort,
      onError: worker._events.sendPort,
      debugName: debugName,
    ).then<void>((_) {}, onError: worker._exited);
    return worker;
  }

  Worker._(this._onEvent, this._onExit) {
    _events.handler = _handle;
  }

  final void Function(Object event) _onEvent;
  final void Function(Object? error) _onExit;
  final RawReceivePort _events = RawReceivePort();
  final CancelSlot _slot = CancelSlot.allocate();
  final Completer<void> _whenExited = Completer<void>();
  final List<Object?> _unsent = [];
  SendPort? _commands;
  Object? _error;
  bool _stopping = false;

  /// Completes when the helper isolate is gone.
  Future<void> get exited => _whenExited.future;

  /// Sends [command]; the worker sees it between native calls.
  void send(Object command) => _post(command);

  /// Ends the loop, interrupting its native call. Idempotent; events in
  /// flight are still delivered.
  void stop() {
    if (_stopping) return;
    _stopping = true;
    if (_whenExited.isCompleted) return;
    _slot.cancel();
    _post(null);
  }

  void _post(Object? command) {
    final commands = _commands;
    if (commands == null) {
      _unsent.add(command);
    } else {
      commands.send(command);
    }
  }

  void _handle(Object? message) {
    switch (message) {
      case null:
        _exited(_error);
      case final SendPort commands:
        _commands = commands;
        _unsent
          ..forEach(commands.send)
          ..clear();
      // Uncaught worker error as `[error, stackTrace]`; the exit follows.
      case [final String error, _]:
        _error = StateError('libtailcat worker failed: $error');
      default:
        _onEvent(message);
    }
  }

  void _exited(Object? error) {
    if (_whenExited.isCompleted) return;
    _events.close();
    _slot.free();
    _whenExited.complete();
    _onExit(error);
  }
}

/// Worker side of a [Worker].
final class WorkerContext {
  WorkerContext._(this._events, this.slot) : token = SlicedToken(slot) {
    _commands.handler = _receive;
    _events.send(_commands.sendPort);
  }

  final SendPort _events;
  final RawReceivePort _commands = RawReceivePort();
  final Queue<Object> _inbox = Queue<Object>();
  Completer<void>? _wakeup;
  bool _stopReceived = false;

  /// The slot shared with the owner.
  final CancelSlot slot;

  /// Bounded tokens for the loop's native calls.
  final SlicedToken token;

  /// Out-parameter storage for the loop's native calls.
  final native.OutParams out = native.OutParams();

  /// Whether the owner asked the loop to end.
  bool get isStopped => _stopReceived || slot.isCancelled;

  /// Reports [event] to the owner.
  void emit(Object event) => _events.send(event);

  /// Removes and returns the commands received so far. They only arrive
  /// while idle, so call [yieldToOwner] or [nextCommand] first.
  List<Object> takeCommands() {
    final commands = _inbox.toList();
    _inbox.clear();
    return commands;
  }

  /// Lets the commands the owner has sent so far arrive.
  Future<void> yieldToOwner() => Future<void>.delayed(Duration.zero);

  /// The next command, or `null` once stopped. Waits idle, not in a native
  /// call, so it needs no token.
  Future<Object?> nextCommand() async {
    while (_inbox.isEmpty && !isStopped) {
      await (_wakeup = Completer<void>()).future;
    }
    return isStopped ? null : _inbox.removeFirst();
  }

  void _receive(Object? command) {
    if (command == null) {
      _stopReceived = true;
    } else {
      _inbox.add(command);
    }
    _wakeup?.complete();
    _wakeup = null;
  }

  void _dispose() {
    token.dispose();
    out.free();
    _commands.close();
  }
}

/// Worker side of credit-based flow control: each emitted item spends a
/// credit and the owner returns one (an `int` command) per item consumed, so
/// a paused consumer stops the loop after one window.
final class Credits {
  /// Starts with [window] credits.
  Credits(this._context, int window) : _available = window;

  final WorkerContext _context;
  int _available;

  /// Waits for a credit; `false` when the loop should end instead.
  Future<bool> acquire() async {
    await _context.yieldToOwner();
    _absorb();
    while (_available == 0) {
      final grant = await _context.nextCommand();
      if (grant == null) return false;
      _available += grant as int;
      _absorb();
    }
    return !_context.isStopped;
  }

  /// Records that an item was emitted.
  void spend() => _available--;

  void _absorb() {
    for (final grant in _context.takeCommands()) {
      _available += grant as int;
    }
  }
}

final class _Boot<P> {
  const _Boot(this.main, this.parameters, this.events, this.slotAddress);

  final WorkerMain<P> main;
  final P parameters;
  final SendPort events;
  final int slotAddress;
}

Future<void> _run<P>(_Boot<P> boot) async {
  final context = WorkerContext._(
    boot.events,
    CancelSlot.fromAddress(boot.slotAddress),
  );
  try {
    await boot.main(context, boot.parameters);
  } finally {
    context._dispose();
  }
}
