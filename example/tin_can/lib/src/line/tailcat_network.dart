// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// The line's transport: plain `dart:io` HTTP and WebSockets over libtailcat.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libtailcat/libtailcat.dart';

import 'datagrams.dart';
import 'transport.dart';

/// Notices a partner who lost the network.
const webSocketPingInterval = Duration(seconds: 5);

/// Only a label: every request goes to the client's server regardless.
const tunnelHostName = 'tin-can';

final class TailcatNetwork implements Network {
  const TailcatNetwork({this.derpMapUrl});

  /// `none` for tests on a local relay.
  final String? derpMapUrl;

  @override
  TailcatKeys generateKeys() => TailcatKeys.generate();

  @override
  AddressFacts parseAddress(TailcatAddress address) =>
      AddressFacts.from(address.parse());

  @override
  Future<HostLink> startHost(HostConfig config) =>
      TailcatHostLink.start(config);

  @override
  GuestLink openGuest({
    required TailcatAddress address,
    required TailcatPrivateKey privateKey,
  }) => TailcatGuestLink(
    TailcatClient(
      TailcatClientConfig(
        address: address,
        privateKey: privateKey,
        derpMapUrl: derpMapUrl,
      ),
    ),
  );
}

final class TailcatHostLink implements HostLink {
  TailcatHostLink._(this.server, this._tcp, this._udp, this._http, this._paths)
    : addressFacts = AddressFacts.from(server.address.parse()) {
    _http.listen(_serve, onError: _channels.addError);
    _udp.listen(
      (flow) => _flows.add(TailcatFlow(flow)),
      onError: _flows.addError,
    );
  }

  static Future<TailcatHostLink> start(HostConfig config) async {
    final server = await TailcatServer.start(
      TailcatServerConfig(
        privateKey: config.privateKey,
        presharedKey: config.presharedKey,
        region: config.region,
        regionId: config.regionId,
        allowedClients: config.allowedClients,
        udpIdleTimeout: config.udpIdleTimeout,
      ),
    );
    try {
      // A TailcatServerSocket is a ServerSocket, so HttpServer runs on it.
      final tcp = await server.listen(port: controlPort);
      final udp = await server.listenUdp(port: datagramPort);
      return TailcatHostLink._(
        server,
        tcp,
        udp,
        HttpServer.listenOn(tcp),
        config.paths,
      );
    } catch (_) {
      await server.close(drain: false);
      rethrow;
    }
  }

  final TailcatServer server;
  final TailcatServerSocket _tcp;
  final TailcatDatagramListener _udp;
  final HttpServer _http;
  final Set<String> _paths;
  final _channels = StreamController<IncomingChannel>.broadcast();
  final _flows = StreamController<DatagramFlow>.broadcast();
  final _accepted = <String>[];

  @override
  final AddressFacts addressFacts;

  @override
  TailcatAddress get address => server.address;

  @override
  String get publicKey => server.publicKey;

  @override
  String get tunnelAddress => server.localAddress.address;

  @override
  Stream<IncomingChannel> get channels => _channels.stream;

  @override
  Stream<DatagramFlow> get flows => _flows.stream;

  @override
  List<OpenResource> get resources => [
    OpenResource('server', '$publicKey at $tunnelAddress'),
    OpenResource('listener', 'TCP ${_endpoint(_tcp.address, _tcp.port)}'),
    OpenResource('listener', 'UDP ${_endpoint(_udp.address, _udp.port)}'),
    for (final socket in _accepted) OpenResource('socket', socket),
  ];

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    if (!_paths.contains(path) ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final info = request.connectionInfo;
    final remote = info == null
        ? 'unknown'
        : _endpoint(info.remoteAddress, info.remotePort);
    final local = info == null
        ? 'unknown'
        : _endpoint(server.localAddress, info.localPort);
    try {
      // Closed through its WebSocketChannel.
      // ignore: close_sinks
      final socket = await WebSocketTransformer.upgrade(request);
      socket.pingInterval = webSocketPingInterval;
      final description = 'TCP $local ← $remote (WebSocket $path)';
      _accepted.add(description);
      unawaited(socket.done.whenComplete(() => _accepted.remove(description)));
      _channels.add(
        IncomingChannel(
          path: path,
          channel: WebSocketChannel(socket),
          remoteEndpoint: remote,
        ),
      );
    } on WebSocketException {
      // dart:io has already answered the broken upgrade.
    }
  }

  @override
  Future<void> close({bool drain = true}) async {
    await _http.close(force: true);
    await server.close(drain: drain);
    await _channels.close();
    await _flows.close();
  }
}

final class TailcatGuestLink implements GuestLink {
  TailcatGuestLink(this.client);

  final TailcatClient client;
  final _open = <String>[];

  @override
  String get publicKey => client.publicKey;

  @override
  List<OpenResource> get resources => [
    OpenResource('client', publicKey),
    for (final description in _open) OpenResource('socket', description),
  ];

  @override
  Future<MessageChannel> connect(
    String path, {
    required Duration timeout,
  }) async {
    // Wrapped to see the socket for the Inspector; the WebSocket owns it.
    // ignore: close_sinks
    TailcatSocket? opened;
    final http = HttpClient()
      ..connectionFactory = (url, proxyHost, proxyPort) async {
        final task = await client.connectionFactory(url, proxyHost, proxyPort);
        task.socket.then((socket) => opened = socket as TailcatSocket).ignore();
        return task;
      };
    final url = 'ws://$tunnelHostName:$controlPort$path';
    try {
      // Closed through its WebSocketChannel.
      // ignore: close_sinks
      final socket = await WebSocket.connect(
        url,
        customClient: http,
      ).timeout(timeout);
      socket.pingInterval = webSocketPingInterval;
      // ignore: close_sinks
      final tcp = opened;
      if (tcp != null) {
        final description =
            'TCP ${_endpoint(tcp.address, tcp.port)} → '
            '${_endpoint(tcp.remoteAddress, tcp.remotePort)} (WebSocket $path)';
        _open.add(description);
        unawaited(socket.done.whenComplete(() => _open.remove(description)));
      }
      return WebSocketChannel(socket);
    } on TimeoutException {
      // Cancels a dial still in flight.
      http.close(force: true);
      rethrow;
    } on WebSocketException catch (e) {
      if (e.message.contains('status code: 404')) {
        throw ProtocolMismatchException(path);
      }
      rethrow;
    } finally {
      // The upgraded socket no longer belongs to the HttpClient.
      http.close();
    }
  }

  @override
  Future<DatagramFlow> openFlow() async {
    final flow = TailcatFlow(await client.connectUdp(port: datagramPort));
    final description =
        'UDP ${flow.localEndpoint} → ${flow.remoteEndpoint} (realtime)';
    _open.add(description);
    unawaited(flow.done.whenComplete(() => _open.remove(description)));
    return flow;
  }

  @override
  Future<TailcatPath> discoPing() =>
      client.discoPing(timeout: const Duration(seconds: 5));

  @override
  Future<Duration> ping() => client.ping(timeout: const Duration(seconds: 5));

  @override
  Future<void> close({bool drain = true}) => client.close(drain: drain);
}

final class WebSocketChannel implements MessageChannel {
  WebSocketChannel(this.socket)
    : messages = socket
          .where((message) => message is String)
          .cast<String>()
          // A broken WebSocket ends with an error; for the line it's just
          // the end.
          .handleError((Object _) {});

  final WebSocket socket;

  @override
  final Stream<String> messages;

  @override
  void send(String message) {
    if (socket.readyState == WebSocket.open) socket.add(message);
  }

  @override
  Future<void> close([int? code, String? reason]) => socket
      .close(code, reason)
      .timeout(const Duration(seconds: 2), onTimeout: () => null)
      .catchError((Object _) => null);

  @override
  int? get closeCode => socket.closeCode;
}

final class TailcatFlow implements DatagramFlow {
  TailcatFlow(this.socket)
    : localEndpoint = _endpoint(socket.address, socket.port),
      remoteEndpoint = _endpoint(socket.remoteAddress, socket.remotePort) {
    datagrams = socket
        .handleError((Object _) {})
        .transform(
          StreamTransformer.fromHandlers(
            handleDone: (sink) {
              if (!_done.isCompleted) _done.complete();
              sink.close();
            },
          ),
        );
  }

  final TailcatDatagramSocket socket;
  final _done = Completer<void>();

  @override
  late final Stream<Uint8List> datagrams;

  @override
  final String localEndpoint;

  @override
  final String remoteEndpoint;

  @override
  int get maxPayloadSize => TailcatDatagramSocket.maxPayloadSize;

  Future<void> get done => _done.future;

  @override
  Future<void> send(Uint8List datagram) => socket.send(datagram);

  @override
  Future<void> close() async {
    await socket.close();
    if (!_done.isCompleted) _done.complete();
  }
}

String _endpoint(InternetAddress address, int port) =>
    address.type == InternetAddressType.IPv6
    ? '[${address.address}]:$port'
    : '${address.address}:$port';
