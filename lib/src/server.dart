// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:io';

import 'address.dart';
import 'bindings/native_api.dart' as native;
import 'config.dart';
import 'info.dart';
import 'io/datagram.dart';
import 'io/listener.dart';
import 'io/server_socket.dart';
import 'io/socket.dart';
import 'runtime/blocking.dart' as blocking;
import 'runtime/library.dart';
import 'runtime/peer.dart';
import 'validation.dart';

/// The listening side of a Tailcat tunnel. Whoever holds its [address] can
/// reach the ports it listens on:
///
/// ```dart
/// final server = await TailcatServer.start(const TailcatServerConfig());
/// final listener = await server.listen(port: 80);
/// print(server.address.reveal()); // hand this to the client, out of band
/// await for (final socket in listener) {
///   socket.write('hello\n');
///   await socket.close();
/// }
/// ```
///
/// [close] it when done; that also closes its listeners and sockets.
final class TailcatServer {
  TailcatServer._(this._peer, ServerInfo info)
    : address = TailcatAddress(info.address),
      publicKey = info.publicKey,
      localAddress = info.localAddress;

  /// Starts a server and registers it with its relay. A `null` [timeout]
  /// means a finite default.
  ///
  /// Throws [TailcatArgumentException] for a rejected config and
  /// [TailcatTimeoutException] when the relay can't be reached in time.
  static Future<TailcatServer> start(
    TailcatServerConfig config, {
    Duration? timeout,
  }) async {
    ensureNativeLibrary();
    final handle = native.newServer(encodeServerConfig(config));
    try {
      final info = ServerInfo.fromJson(
        await blocking.startServer(handle, timeout),
      );
      return TailcatServer._(Peer(handle), info);
    } catch (_) {
      blocking.close(handle).ignore();
      rethrow;
    }
  }

  final Peer _peer;

  /// The address clients connect to. Secret unless an allowlist is set.
  final TailcatAddress address;

  /// The server's public node key. Not secret.
  final String publicKey;

  /// The server's IP address inside the tunnel.
  final InternetAddress localAddress;

  /// Whether [close] has been called.
  bool get isClosed => _peer.isClosed;

  /// Listens for TCP on [port] (0 picks a free one). A `null` [timeout]
  /// means a finite default.
  Future<TailcatServerSocket> listen({int port = 0, Duration? timeout}) async {
    final opened = await blocking.listen(
      _peer.handle.checked,
      checkPort(port, allowAny: true),
      native.TC_TCP,
      timeout,
    );
    _peer.checkAdoptable(opened.handle);
    return TailcatServerSocket.fromListener(
      Listener<Socket>(
        opened,
        _peer,
        datagram: false,
        wrap: TailcatSocket.fromConnection,
      ),
    );
  }

  /// Listens for UDP flows on [port] (0 picks a free one). A `null` [timeout]
  /// means a finite default.
  Future<TailcatDatagramListener> listenUdp({
    int port = 0,
    Duration? timeout,
  }) async {
    final opened = await blocking.listen(
      _peer.handle.checked,
      checkPort(port, allowAny: true),
      native.TC_UDP,
      timeout,
    );
    _peer.checkAdoptable(opened.handle);
    return TailcatDatagramListener.fromListener(
      Listener<TailcatDatagramSocket>(
        opened,
        _peer,
        datagram: true,
        wrap: TailcatDatagramSocket.fromConnection,
      ),
    );
  }

  /// Adds [publicKey] to the allowlist; the first key restricts new clients
  /// to listed ones. Keys can't be removed; connected clients stay.
  ///
  /// Throws [TailcatArgumentException] when the key is malformed.
  Future<void> allowClient(String publicKey, {Duration? timeout}) async =>
      blocking.allowClient(_peer.handle.checked, publicKey, timeout);

  /// Waits until closed connections' shutdown traffic is delivered, for use
  /// before exiting without [close]. A `null` [timeout] means a few seconds.
  Future<void> drain({Duration? timeout}) async => _peer.drain(timeout);

  /// Closes the server, its listeners and every socket it accepted.
  ///
  /// With [drain], sockets get up to [drainTimeout] (default a few seconds)
  /// to deliver their last bytes so peers don't see a reset.
  Future<void> close({bool drain = true, Duration? drainTimeout}) =>
      _peer.close(drain: drain, drainTimeout: drainTimeout);

  @override
  String toString() => 'TailcatServer(publicKey: $publicKey)';
}
