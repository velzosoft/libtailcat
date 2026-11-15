// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// An in-memory [Network] that mimics what the line relies on: stable
/// addresses, allowlisted dials (others time out), UDP flows seen on first
/// datagram.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:libtailcat/libtailcat.dart';
import 'package:tin_can/src/line/datagrams.dart';
import 'package:tin_can/src/line/transport.dart';

final class FakeNetwork implements Network {
  static const defaultRegion = <String, Object?>{
    'RegionID': 1,
    'RegionCode': '1',
    'RegionName': '',
    'Nodes': [
      {'Name': 'tc303a.ipn.dev', 'RegionID': 1, 'HostName': 'tc303a.ipn.dev'},
    ],
  };

  final Map<String, FakeHostLink> _hosts = {};
  int _keys = 0;

  /// What `discoPing` reports; tests change it to move the path.
  TailcatPath path = const TailcatPath(
    latency: Duration(milliseconds: 80),
    derpRegionId: 1,
    derpRegionCode: '1',
  );

  int hostsStarted = 0;

  FakeHostLink? hostAt(TailcatAddress address) => _hosts[address.reveal()];

  static String publicKeyOf(TailcatPrivateKey privateKey) =>
      'nodekey:${privateKey.reveal().replaceFirst('private-', '')}';

  @override
  TailcatKeys generateKeys() {
    final n = ++_keys;
    final privateKey = TailcatPrivateKey('private-$n');
    return TailcatKeys(
      privateKey: privateKey,
      publicKey: publicKeyOf(privateKey),
      presharedKey: TailcatPresharedKey('psk-$n'),
    );
  }

  @override
  AddressFacts parseAddress(TailcatAddress address) {
    final parts = address.reveal().split('|');
    if (parts.length != 3 || parts[0] != 'fake') {
      throw const TailcatArgumentException('not an address');
    }
    return AddressFacts(
      publicKey: parts[1],
      discoPublicKey: 'discokey:${parts[1]}',
      hasPresharedKey: true,
      regionId: 0,
      regions: [
        {...defaultRegion, 'Tag': parts[2]},
      ],
    );
  }

  @override
  Future<HostLink> startHost(HostConfig config) async {
    hostsStarted++;
    final publicKey = publicKeyOf(config.privateKey);
    final region = config.region?['Tag'] ?? 'nearest';
    final address = TailcatAddress('fake|$publicKey|$region');
    final link = FakeHostLink._(this, address, publicKey, config);
    _hosts[address.reveal()] = link;
    return link;
  }

  @override
  GuestLink openGuest({
    required TailcatAddress address,
    required TailcatPrivateKey privateKey,
  }) => FakeGuestLink._(this, address, publicKeyOf(privateKey));
}

final class FakeHostLink implements HostLink {
  FakeHostLink._(this._network, this.address, this.publicKey, this.config);

  final FakeNetwork _network;

  final HostConfig config;

  final _channels = StreamController<IncomingChannel>.broadcast();
  final _flows = StreamController<DatagramFlow>.broadcast();
  final _open = <FakeChannel>[];
  final _openFlows = <FakeFlow>[];
  bool _closed = false;

  bool get isClosed => _closed;

  @override
  final TailcatAddress address;

  @override
  final String publicKey;

  @override
  AddressFacts get addressFacts => _network.parseAddress(address);

  @override
  String get tunnelAddress => '100.64.0.1';

  @override
  Stream<IncomingChannel> get channels => _channels.stream;

  @override
  Stream<DatagramFlow> get flows => _flows.stream;

  @override
  List<OpenResource> get resources => [OpenResource('server', publicKey)];

  bool _admits(String clientKey) =>
      config.allowedClients.isEmpty ||
      config.allowedClients.contains(clientKey);

  @override
  Future<void> close({bool drain = true}) async {
    if (_closed) return;
    _closed = true;
    if (identical(_network._hosts[address.reveal()], this)) {
      _network._hosts.remove(address.reveal());
    }
    for (final channel in _open.toList()) {
      await channel.close(1001, 'server closed');
    }
    for (final flow in _openFlows.toList()) {
      await flow.close();
    }
    await _channels.close();
    await _flows.close();
  }
}

final class FakeGuestLink implements GuestLink {
  FakeGuestLink._(this._network, this._address, this.publicKey);

  final FakeNetwork _network;
  final TailcatAddress _address;
  final _open = <FakeChannel>[];
  final _openFlows = <FakeFlow>[];
  bool _closed = false;

  @override
  final String publicKey;

  @override
  List<OpenResource> get resources => [OpenResource('client', publicKey)];

  FakeHostLink? get _host {
    final host = _network.hostAt(_address);
    return host != null && host._admits(publicKey) ? host : null;
  }

  @override
  Future<MessageChannel> connect(
    String path, {
    required Duration timeout,
  }) async {
    _checkOpen();
    final host = _host;
    if (host == null) {
      // No server there, or not on its allowlist.
      await Future<void>.delayed(timeout);
      _checkOpen();
      throw TailcatTimeoutException('dial timed out', timeout);
    }
    if (!host.config.paths.contains(path)) {
      throw ProtocolMismatchException(path);
    }
    final (mine, theirs) = FakeChannel.pair();
    _open.add(mine);
    host._open.add(theirs);
    host._channels.add(
      IncomingChannel(
        path: path,
        channel: theirs,
        remoteEndpoint: '100.64.0.2:${40000 + _open.length}',
      ),
    );
    return mine;
  }

  @override
  Future<DatagramFlow> openFlow() async {
    _checkOpen();
    final host = _host;
    final (mine, theirs) = FakeFlow.pair(
      '100.64.0.2:${50000 + _openFlows.length}',
      '100.64.0.1:$datagramPort',
    );
    _openFlows.add(mine);
    if (host != null) {
      host._openFlows.add(theirs);
      mine.onFirstSend = () {
        if (!host._flows.isClosed) host._flows.add(theirs);
      };
    }
    return mine;
  }

  @override
  Future<TailcatPath> discoPing() async {
    _checkOpen();
    if (_host == null) throw const TailcatTimeoutException('no pong');
    return _network.path;
  }

  @override
  Future<Duration> ping() async {
    _checkOpen();
    return const Duration(milliseconds: 40);
  }

  void _checkOpen() {
    if (_closed) throw const TailcatClosedException();
  }

  @override
  Future<void> close({bool drain = true}) async {
    _closed = true;
    for (final channel in _open.toList()) {
      await channel.close(1001, 'client closed');
    }
    for (final flow in _openFlows.toList()) {
      await flow.close();
    }
  }
}

final class FakeChannel implements MessageChannel {
  FakeChannel._();

  static (FakeChannel, FakeChannel) pair() {
    final a = FakeChannel._();
    final b = FakeChannel._();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  late final FakeChannel _peer;
  final _incoming = StreamController<String>();
  bool _closed = false;

  final List<String> sent = [];

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  int? closeCode;

  @override
  void send(String message) {
    if (_closed) return;
    sent.add(message);
    // Asynchronous, like a network.
    scheduleMicrotask(() {
      if (!_peer._closed) _peer._incoming.add(message);
    });
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    // Messages sent just before arrive first, as before a close frame.
    await Future<void>.delayed(Duration.zero);
    _closed = true;
    closeCode = code;
    // Not awaited: an unlistened stream's close completes only on listen.
    unawaited(_incoming.close());
    if (!_peer._closed) {
      _peer._closed = true;
      _peer.closeCode = code;
      unawaited(_peer._incoming.close());
    }
  }
}

final class FakeFlow implements DatagramFlow {
  FakeFlow._(this.localEndpoint, this.remoteEndpoint);

  static (FakeFlow, FakeFlow) pair(String guest, String host) {
    final a = FakeFlow._(guest, host);
    final b = FakeFlow._(host, guest);
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  late final FakeFlow _peer;
  final _incoming = StreamController<Uint8List>();
  bool _closed = false;

  /// Called once, before the first datagram is delivered.
  void Function()? onFirstSend;

  /// For loss tests.
  bool Function(Uint8List datagram)? drop;

  @override
  Stream<Uint8List> get datagrams => _incoming.stream;

  @override
  final String localEndpoint;

  @override
  final String remoteEndpoint;

  @override
  int get maxPayloadSize => 1232;

  @override
  Future<void> send(Uint8List datagram) async {
    if (_closed) throw const TailcatClosedException();
    final first = onFirstSend;
    onFirstSend = null;
    first?.call();
    if (drop?.call(datagram) ?? false) return;
    scheduleMicrotask(() {
      if (!_peer._closed) _peer._incoming.add(datagram);
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    unawaited(_incoming.close());
  }
}
