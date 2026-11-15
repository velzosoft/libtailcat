// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:io';

import 'bindings/native_api.dart' as native;
import 'config.dart';
import 'info.dart';
import 'io/connection.dart';
import 'io/datagram.dart';
import 'io/socket.dart';
import 'runtime/blocking.dart' as blocking;
import 'runtime/library.dart';
import 'runtime/peer.dart';
import 'validation.dart';

/// The signature of `HttpClient.connectionFactory`.
typedef TailcatConnectionFactory =
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    );

/// The dialing side of a Tailcat tunnel, connected to the one server its
/// [TailcatAddress] names:
///
/// ```dart
/// final client = TailcatClient(TailcatClientConfig(address: address));
/// final socket = await client.connect(port: 80);
/// ```
///
/// The tunnel comes up lazily on the first call that uses it. [close] the
/// client when done; that also closes its sockets.
final class TailcatClient {
  /// Creates a client for `config.address`, without network I/O.
  ///
  /// Throws [TailcatArgumentException] for a malformed address or key.
  factory TailcatClient(TailcatClientConfig config) {
    ensureNativeLibrary();
    final handle = native.newClient(encodeClientConfig(config));
    final token = native.newToken(blocking.defaultTimeout);
    try {
      final publicKey = clientPublicKey(native.info(handle, token));
      return TailcatClient._(Peer(handle), publicKey);
    } catch (_) {
      native.closeHandle(handle);
      rethrow;
    } finally {
      native.closeToken(token);
    }
  }

  TailcatClient._(this._peer, this.publicKey);

  final Peer _peer;

  /// The client's public node key, as held by an allowlist. Not secret.
  final String publicKey;

  /// Whether [close] has been called.
  bool get isClosed => _peer.isClosed;

  /// Opens a TCP connection to [port] on the server. A `null` [timeout]
  /// means a finite default.
  ///
  /// Throws [TailcatTimeoutException] or, if the client closes meanwhile,
  /// [TailcatClosedException].
  Future<TailcatSocket> connect({required int port, Duration? timeout}) async =>
      _startConnect(port, timeout).socket;

  /// Opens a UDP flow to [port]; the server sees it on the first datagram.
  /// A `null` [timeout] means a finite default.
  Future<TailcatDatagramSocket> connectUdp({
    required int port,
    Duration? timeout,
  }) async {
    final opened = await blocking
        .dial(_peer.handle.checked, checkPort(port), native.TC_UDP, timeout)
        .result;
    _peer.checkAdoptable(opened.handle);
    return TailcatDatagramSocket.fromConnection(
      Connection(opened, _peer, datagram: true),
    );
  }

  /// The round-trip time to the server over the relay, in whole
  /// milliseconds. A `null` [timeout] means a finite default.
  Future<Duration> ping({Duration? timeout}) async => Duration(
    milliseconds: await blocking.ping(_peer.handle.checked, timeout),
  );

  /// Probes whether the path is direct or relayed, and its latency; this
  /// also nudges NAT traversal. A `null` [timeout] means a finite default.
  Future<TailcatPath> discoPing({Duration? timeout}) async =>
      TailcatPath.fromJson(
        await blocking.discoPing(_peer.handle.checked, timeout),
      );

  /// Waits until closed connections' shutdown traffic is delivered, for use
  /// before exiting without [close]. A `null` [timeout] means a few seconds.
  Future<void> drain({Duration? timeout}) async => _peer.drain(timeout);

  /// Closes the client and every socket it opened.
  ///
  /// With [drain], sockets get up to [drainTimeout] (default a few seconds)
  /// to deliver their last bytes so peers don't see a reset.
  Future<void> close({bool drain = true, Duration? drainTimeout}) =>
      _peer.close(drain: drain, drainTimeout: drainTimeout);

  /// An `HttpClient.connectionFactory` that sends requests through the
  /// tunnel:
  ///
  /// ```dart
  /// final http = HttpClient()..connectionFactory = client.connectionFactory;
  /// final request = await http.getUrl(Uri.parse('http://tailcat:8080/'));
  /// ```
  ///
  /// Requests go to this client's server on the URL's port; the host only
  /// sets the `Host` header. `https` throws [UnsupportedError] (the tunnel is
  /// already encrypted).
  TailcatConnectionFactory get connectionFactory =>
      (url, proxyHost, proxyPort) async {
        if (!url.isScheme('http')) {
          throw UnsupportedError(
            'Only http URLs can be requested through a Tailcat tunnel, got '
            '"${url.scheme}". The tunnel is already encrypted end to end.',
          );
        }
        final connecting = _startConnect(url.port, null);
        return ConnectionTask.fromSocket<Socket>(
          connecting.socket,
          connecting.cancel,
        );
      };

  ({Future<TailcatSocket> socket, void Function() cancel}) _startConnect(
    int port,
    Duration? timeout,
  ) {
    final dialing = blocking.dial(
      _peer.handle.checked,
      checkPort(port),
      native.TC_TCP,
      timeout,
    );
    return (
      socket: dialing.result.then((opened) {
        _peer.checkAdoptable(opened.handle);
        return TailcatSocket.fromConnection(
          Connection(opened, _peer, datagram: false),
        );
      }),
      cancel: dialing.cancel,
    );
  }

  @override
  String toString() => 'TailcatClient(publicKey: $publicKey)';
}
