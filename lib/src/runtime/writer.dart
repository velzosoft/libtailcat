// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../bindings/native_api.dart' as native;
import 'errors.dart';
import 'token.dart';
import 'worker.dart';

/// Size of the native buffer one write call drains.
const int writeChunkSize = 64 * 1024;

/// How long an idle writer keeps its helper isolate before giving it up.
const writerIdleTimeout = Duration(seconds: 2);

/// Writes to a connection in order on a helper isolate, spawned lazily and
/// retired after [writerIdleTimeout] idle.
///
/// The queue is unbounded, like a `dart:io` sink; pace with [pendingBytes]
/// and [drained].
final class ConnectionWriter {
  /// With [datagram], each write is one datagram; otherwise large writes are
  /// split.
  ConnectionWriter(this._connection, {required this.datagram});

  final int _connection;

  /// Whether each write is sent as one datagram.
  final bool datagram;

  final Queue<_Pending> _pending = Queue<_Pending>();
  Worker? _worker;
  Timer? _idleTimer;
  Completer<void>? _whenDrained;
  Object? _failure;
  int _pendingBytes = 0;

  /// Bytes queued but not yet handed to the native library.
  int get pendingBytes => _pendingBytes;

  /// Completes when the queue is empty. Never fails; [write] reports errors.
  Future<void> get drained => _pending.isEmpty
      ? Future<void>.value()
      : (_whenDrained ??= Completer<void>()).future;

  /// Queues [data]; completes when the native library took all of it. After
  /// a failure, every write fails with the same [TailcatException].
  Future<void> write(Uint8List data) =>
      _submit(TransferableTypedData.fromList([data]), data.length);

  /// Sends FIN once the queue is through, then retires the helper.
  Future<void> closeWrite() =>
      _submit(_closeWriteCommand, 0).whenComplete(_retire);

  /// Stops the helper and fails whatever is still queued. Idempotent.
  void stop() => _fail(const TailcatClosedException());

  Future<void> _submit(Object command, int bytes) {
    final failure = _failure;
    if (failure != null) return Future<void>.error(failure);
    _idleTimer?.cancel();
    final pending = _Pending(bytes);
    _pending.add(pending);
    _pendingBytes += bytes;
    (_worker ??= _spawn()).send(command);
    return pending.done.future;
  }

  Worker _spawn() {
    late final Worker worker;
    return worker = Worker.spawn(
      _writeLoop,
      (connection: _connection, datagram: datagram),
      debugName: 'libtailcat writer',
      // A retired worker can still report; only the current one counts.
      onEvent: (event) {
        if (identical(worker, _worker)) _onEvent(event);
      },
      onExit: (error) {
        if (identical(worker, _worker)) {
          _fail(error ?? const TailcatClosedException('the writer went away'));
        }
      },
    );
  }

  void _onEvent(Object event) {
    if (event is WorkerEnded) {
      _fail(
        exceptionForStatus(
          event.status,
          operation: 'write',
          message: event.message,
        ),
      );
      return;
    }
    // An acknowledgement of the oldest queued command.
    final pending = _pending.removeFirst();
    _pendingBytes -= pending.bytes;
    pending.done.complete();
    if (_pending.isEmpty) {
      _whenDrained?.complete();
      _whenDrained = null;
      _idleTimer = Timer(writerIdleTimeout, _retire);
    }
  }

  void _retire() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _worker?.stop();
    _worker = null;
  }

  void _fail(Object failure) {
    if (_failure != null) return;
    _failure = failure;
    _retire();
    _pendingBytes = 0;
    while (_pending.isNotEmpty) {
      // Nobody may await a queued write; don't surface an unhandled error.
      _pending.removeFirst().done
        ..future.ignore()
        ..completeError(failure);
    }
    _whenDrained?.complete();
    _whenDrained = null;
  }
}

final class _Pending {
  _Pending(this.bytes);

  final int bytes;
  final Completer<void> done = Completer<void>();
}

const String _closeWriteCommand = 'close-write';

typedef _WriteParameters = ({int connection, bool datagram});

/// Runs the owner's commands in order and acknowledges each.
Future<void> _writeLoop(
  WorkerContext context,
  _WriteParameters parameters,
) async {
  final buffer = malloc<Uint8>(writeChunkSize);
  try {
    while (true) {
      final command = await context.nextCommand();
      if (command == null) return;
      final ended = command is TransferableTypedData
          ? _write(context, parameters, command, buffer)
          : _closeWrite(context, parameters.connection);
      if (ended != null) {
        context.emit(ended);
        return;
      }
      context.emit(0);
    }
  } finally {
    malloc.free(buffer);
  }
}

/// Returns the loop-ending event when the connection can't take the bytes.
WorkerEnded? _write(
  WorkerContext context,
  _WriteParameters parameters,
  TransferableTypedData data,
  Pointer<Uint8> buffer,
) {
  final bytes = data.materialize().asUint8List();
  if (parameters.datagram) {
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    return _writeAll(context, parameters.connection, buffer, bytes.length);
  }
  for (var offset = 0; offset < bytes.length; offset += writeChunkSize) {
    final length = math.min(writeChunkSize, bytes.length - offset);
    buffer.asTypedList(length).setRange(0, length, bytes, offset);
    final ended = _writeAll(context, parameters.connection, buffer, length);
    if (ended != null) return ended;
  }
  return null;
}

/// Sends [length] bytes of [buffer] across partial writes and slices.
WorkerEnded? _writeAll(
  WorkerContext context,
  int connection,
  Pointer<Uint8> buffer,
  int length,
) {
  var sent = 0;
  while (true) {
    String? error;
    final status = context.token.run((token) {
      final result = native.write(
        connection,
        token,
        buffer + sent,
        length - sent,
        context.out,
      );
      // Bytes sent before a timeout are gone; never replay them.
      sent += context.out.countValue;
      error = result.error;
      return result.status;
    });
    if (status == native.TC_OK && sent >= length) return null;
    if (status != native.TC_OK && status != sliceElapsed) {
      return WorkerEnded(status, error);
    }
  }
}

WorkerEnded? _closeWrite(WorkerContext context, int connection) {
  while (true) {
    String? error;
    final status = context.token.run((token) {
      final result = native.closeWrite(connection, token, context.out);
      error = result.error;
      return result.status;
    });
    if (status == native.TC_OK) return null;
    if (status != sliceElapsed) return WorkerEnded(status, error);
  }
}
