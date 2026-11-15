// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:typed_data';

import '../info.dart';
import '../runtime/blocking.dart' as blocking;
import '../runtime/handle.dart';
import '../runtime/peer.dart';
import '../runtime/reader.dart';
import '../runtime/worker_stream.dart';
import '../runtime/writer.dart';

/// A native TCP stream or UDP flow and the isolates that read and write it.
/// The public socket classes wrap it; it owns the resources.
final class Connection implements HandleOwner {
  /// Adopts a dialed or accepted connection as a child of [peer].
  factory Connection(
    blocking.Opened opened,
    Peer peer, {
    required bool datagram,
  }) {
    try {
      final ends = connectionEndpoints(opened.info);
      return Connection._(
        opened.handle,
        peer,
        ends.local,
        ends.remote,
        datagram,
      );
    } catch (_) {
      blocking.close(opened.handle).ignore();
      rethrow;
    }
  }

  Connection._(int id, this.peer, this.local, this.remote, bool datagram)
    : writer = ConnectionWriter(id, datagram: datagram) {
    handle = NativeHandle(id, this, parent: peer.handle);
    _reader = readConnection(
      id,
      datagram: datagram,
      onEnded: (error) => onReadEnded?.call(error),
    );
  }

  /// The owning client or server; holding it prevents its finalization.
  final Peer peer;

  /// This end of the connection.
  final Endpoint local;

  /// The peer's end of the connection.
  final Endpoint remote;

  /// The write side.
  final ConnectionWriter writer;

  /// The native handle.
  late final NativeHandle handle;

  late final WorkerStream<Uint8List> _reader;

  /// Runs once when [incoming] ends, with the error if one broke it.
  void Function(Object? error)? onReadEnded;

  /// Runs once when the connection or its owner is closed.
  void Function()? onClosed;

  /// Whether the connection has been closed.
  bool get isClosed => handle.isClosed;

  /// Bytes (TCP) or datagrams (UDP) from the peer. Reads start on listen.
  Stream<Uint8List> get incoming => _reader.stream;

  /// Closes both directions and releases the native handle. Idempotent.
  Future<void> close() => handle.close();

  @override
  void handleRetired() {
    _reader.stop();
    writer.stop();
    onClosed?.call();
  }
}
