// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../runtime/errors.dart';
import 'connection.dart';

/// A TCP connection through a Tailcat tunnel, usable as a `dart:io` [Socket].
///
/// * Reading starts on listen and pauses with the subscription; cancelling
///   closes the read side only.
/// * [close] is a half-close (flush, then FIN); [destroy] closes both
///   directions and drops queued data.
/// * Write failures surface through [done] and [flush].
///
/// It can't be upgraded with `SecureSocket.secure`; the tunnel is encrypted.
final class TailcatSocket extends Stream<Uint8List> implements Socket {
  /// Use `TailcatClient.connect` or a `TailcatServerSocket` instead.
  @internal
  TailcatSocket.fromConnection(Connection connection)
    : _connection = connection {
    _sink = IOSink(_consumer);
    connection
      ..onReadEnded = _readEnded
      ..onClosed = _consumer.stop;
  }

  final Connection _connection;
  late final _WriteConsumer _consumer = _WriteConsumer(this);
  late final IOSink _sink;
  bool _readClosed = false;
  bool _writeClosed = false;

  @override
  InternetAddress get address => _connection.local.address;

  @override
  int get port => _connection.local.port;

  @override
  InternetAddress get remoteAddress => _connection.remote.address;

  @override
  int get remotePort => _connection.remote.port;

  @override
  Encoding get encoding => _sink.encoding;

  @override
  set encoding(Encoding value) => _sink.encoding = value;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _connection.incoming.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void add(List<int> data) => _sink.add(data);

  @override
  void write(Object? object) => _sink.write(object);

  @override
  void writeln([Object? object = '']) => _sink.writeln(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);

  /// Not supported, as on every `dart:io` socket.
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnsupportedError('Cannot send errors on sockets');

  @override
  Future<void> addStream(Stream<List<int>> stream) => _sink.addStream(stream);

  /// Completes when everything added so far is handed to the tunnel.
  @override
  Future<void> flush() => _sink.flush();

  /// Flushes and half-closes; this side can still read. Completes like
  /// [done].
  @override
  Future<void> close() => _sink.close();

  /// Completes when the write side closes, or with the error that broke it.
  @override
  Future<void> get done => _sink.done;

  /// Closes both directions at once, dropping unflushed data.
  @override
  void destroy() => _connection.close().ignore();

  /// Always `false`: nothing to configure on a tunnelled connection.
  @override
  bool setOption(SocketOption option, bool enabled) => false;

  /// Not supported: there is no OS socket behind a tunnelled connection.
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      throw UnsupportedError('A Tailcat socket has no raw socket options');

  /// Not supported: there is no OS socket behind a tunnelled connection.
  @override
  void setRawOption(RawSocketOption option) =>
      throw UnsupportedError('A Tailcat socket has no raw socket options');

  void _readEnded(Object? error) {
    _readClosed = true;
    if (error == null) {
      _releaseIfFinished();
    } else {
      _consumer.fail(error);
      destroy();
    }
  }

  Future<void> _shutdownWrite() async {
    try {
      await _connection.writer.closeWrite();
    } on TailcatClosedException {
      // Destroyed meanwhile; nothing left to shut down.
    } catch (_) {
      destroy();
      rethrow;
    }
    _writeClosed = true;
    _releaseIfFinished();
  }

  /// Like `dart:io`, a socket is released once both directions are closed.
  void _releaseIfFinished() {
    if (_readClosed && _writeClosed) destroy();
  }

  @override
  String toString() =>
      'TailcatSocket(${_connection.local} -> ${_connection.remote})';
}

/// Pipes the socket's [IOSink] into the writer, pausing the source while too
/// much is queued.
final class _WriteConsumer implements StreamConsumer<List<int>> {
  _WriteConsumer(this._socket);

  static const int _highWaterMark = 256 * 1024;

  final TailcatSocket _socket;
  StreamSubscription<List<int>>? _subscription;
  Completer<void>? _streamDone;

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    // Like `dart:io`, a closed socket silently drops writes.
    if (_socket._connection.isClosed) return Future<void>.value();
    final done = _streamDone = Completer<void>();
    final writer = _socket._connection.writer;
    _subscription = stream.listen(
      (data) {
        writer
            .write(data is Uint8List ? data : Uint8List.fromList(data))
            .catchError(_writeFailed);
        if (writer.pendingBytes > _highWaterMark) {
          _subscription?.pause(writer.drained);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        fail(error, stackTrace);
        _socket.destroy();
      },
      // A failed write has completed `done` already; this is then a no-op.
      onDone: () => writer.drained.then((_) => _finish()),
      cancelOnError: true,
    );
    return done.future;
  }

  @override
  Future<void> close() => _socket._shutdownWrite();

  void fail(Object error, [StackTrace? stackTrace]) =>
      _finish(error, stackTrace);

  void stop() => _finish();

  void _writeFailed(Object error, StackTrace stackTrace) {
    // A write the connection's own close cut short is not a failure.
    if (error is! TailcatClosedException || !_socket._connection.isClosed) {
      fail(error, stackTrace);
    }
    _socket.destroy();
  }

  void _finish([Object? error, StackTrace? stackTrace]) {
    _subscription?.cancel().ignore();
    _subscription = null;
    final done = _streamDone;
    _streamDone = null;
    if (done == null) return;
    if (error == null) {
      done.complete();
    } else {
      done.completeError(error, stackTrace);
    }
  }
}
