// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import '../info.dart';
import '../runtime/acceptor.dart';
import '../runtime/blocking.dart' as blocking;
import '../runtime/handle.dart';
import '../runtime/peer.dart';
import '../runtime/worker_stream.dart';
import 'connection.dart';

/// A native TCP or UDP listener and the isolate that accepts on it. [T] is
/// the public type accepted connections are wrapped in.
final class Listener<T> implements HandleOwner {
  /// Adopts a new listener as a child of [peer].
  factory Listener(
    blocking.Opened opened,
    Peer peer, {
    required bool datagram,
    required T Function(Connection connection) wrap,
  }) {
    try {
      return Listener._(
        opened.handle,
        peer,
        listenerEndpoint(opened.info),
        datagram,
        wrap,
      );
    } catch (_) {
      blocking.close(opened.handle).ignore();
      rethrow;
    }
  }

  Listener._(
    int id,
    this.peer,
    this.local,
    bool datagram,
    T Function(Connection connection) wrap,
  ) {
    handle = NativeHandle(id, this, parent: peer.handle);
    _accepted = acceptConnections(
      id,
      // Accepted connections belong to the server and outlive the listener.
      decode: (opened) => wrap(Connection(opened, peer, datagram: datagram)),
      // Like `dart:io`, the listener closes when its stream ends.
      onEnded: (_) => close().ignore(),
    );
  }

  /// The server the listener belongs to.
  final Peer peer;

  /// The address and port the listener is bound to.
  final Endpoint local;

  /// The native handle.
  late final NativeHandle handle;

  late final WorkerStream<T> _accepted;

  /// The accepted connections. Accepting starts on listen.
  Stream<T> get connections => _accepted.stream;

  /// Stops accepting; accepted connections stay open. Idempotent.
  Future<void> close() => handle.close();

  @override
  void handleRetired() => _accepted.stop();
}
