// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../bindings/native_api.dart' show maxDatagramSize;
import '../runtime/errors.dart';
import 'connection.dart';
import 'listener.dart';

/// A connected UDP flow through a Tailcat tunnel: one datagram per event.
/// Reading starts on listen; delivery is not guaranteed, as with any UDP.
final class TailcatDatagramSocket extends Stream<Uint8List> {
  /// Use `TailcatClient.connectUdp` or a [TailcatDatagramListener] instead.
  @internal
  TailcatDatagramSocket.fromConnection(Connection connection)
    : _connection = connection;

  /// The largest payload [send] accepts, in bytes (the tunnel's 1280-byte
  /// MTU less headers).
  static const int maxPayloadSize = maxDatagramSize;

  final Connection _connection;

  /// This end's IP address inside the tunnel.
  InternetAddress get address => _connection.local.address;

  /// This end's port.
  int get port => _connection.local.port;

  /// The peer's IP address inside the tunnel.
  InternetAddress get remoteAddress => _connection.remote.address;

  /// The peer's port.
  int get remotePort => _connection.remote.port;

  /// Whether the flow has been closed.
  bool get isClosed => _connection.isClosed;

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

  /// Sends [payload] as one datagram; completes when the tunnel takes it.
  ///
  /// Throws [TailcatArgumentException] above [maxPayloadSize] and
  /// [TailcatClosedException] once closed.
  Future<void> send(List<int> payload) {
    if (payload.length > maxPayloadSize) {
      return Future.error(
        TailcatArgumentException(
          'a datagram carries at most $maxPayloadSize bytes, '
          'got ${payload.length}',
        ),
        StackTrace.current,
      );
    }
    return _connection.writer.write(
      payload is Uint8List ? payload : Uint8List.fromList(payload),
    );
  }

  /// Closes the flow. Idempotent.
  Future<void> close() => _connection.close();

  @override
  String toString() =>
      'TailcatDatagramSocket(${_connection.local} -> ${_connection.remote})';
}

/// A UDP listener on a Tailcat server. Each event is a new flow from one
/// client port, appearing on its first datagram and dropped after the idle
/// timeout.
///
/// Accepting starts on listen. [close] and cancelling leave accepted flows
/// open.
final class TailcatDatagramListener extends Stream<TailcatDatagramSocket> {
  /// Use `TailcatServer.listenUdp` instead.
  @internal
  TailcatDatagramListener.fromListener(Listener<TailcatDatagramSocket> listener)
    : _listener = listener;

  final Listener<TailcatDatagramSocket> _listener;

  /// The server's IP address inside the tunnel.
  InternetAddress get address => _listener.local.address;

  /// The port listened on, including one picked for port 0.
  int get port => _listener.local.port;

  @override
  StreamSubscription<TailcatDatagramSocket> listen(
    void Function(TailcatDatagramSocket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _listener.connections.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  /// Stops listening; accepted flows stay open.
  Future<void> close() => _listener.close();

  @override
  String toString() => 'TailcatDatagramListener(${_listener.local})';
}
