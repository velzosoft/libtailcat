// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import 'listener.dart';
import 'socket.dart';

/// A TCP listener on a Tailcat server, usable as a `dart:io` [ServerSocket]
/// (e.g. with `HttpServer.listenOn`). It delivers [TailcatSocket]s.
///
/// Accepting starts on listen and pauses with the subscription. Cancelling
/// closes the listener, so `await listener.first` accepts exactly one.
/// [close] leaves accepted sockets open.
final class TailcatServerSocket extends Stream<Socket> implements ServerSocket {
  /// Use `TailcatServer.listen` instead.
  @internal
  TailcatServerSocket.fromListener(Listener<Socket> listener)
    : _listener = listener;

  final Listener<Socket> _listener;

  /// The server's IP address inside the tunnel.
  @override
  InternetAddress get address => _listener.local.address;

  /// The port listened on, including one picked for port 0.
  @override
  int get port => _listener.local.port;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _listener.connections.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  /// Stops listening; accepted sockets stay open.
  @override
  Future<ServerSocket> close() async {
    await _listener.close();
    return this;
  }

  @override
  String toString() => 'TailcatServerSocket(${_listener.local})';
}
