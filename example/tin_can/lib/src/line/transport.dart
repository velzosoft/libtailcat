// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// The network interface under the line; unit tests implement it in memory.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:libtailcat/libtailcat.dart';

import 'relays.dart';

/// The HTTP port the host serves WebSocket upgrades on.
const controlPort = 80;

const pairPath = '/v1/pair';

const linePath = '/v1/line';

/// A text-message channel: a WebSocket.
abstract interface class MessageChannel {
  Stream<String> get messages;

  /// Does nothing once the channel is closed.
  void send(String message);

  Future<void> close([int? code, String? reason]);

  /// The close code the other side sent, once the channel is closed.
  int? get closeCode;
}

/// A UDP flow through the tunnel.
abstract interface class DatagramFlow {
  Stream<Uint8List> get datagrams;

  Future<void> send(Uint8List datagram);

  Future<void> close();

  /// `ip:port` inside the tunnel.
  String get localEndpoint;

  /// `ip:port` inside the tunnel.
  String get remoteEndpoint;

  int get maxPayloadSize;
}

/// A WebSocket the host accepted.
final class IncomingChannel {
  const IncomingChannel({
    required this.path,
    required this.channel,
    required this.remoteEndpoint,
  });

  final String path;

  final MessageChannel channel;

  /// The guest's `ip:port` inside the tunnel. An accepted socket doesn't say
  /// which client key it came from.
  final String remoteEndpoint;
}

/// What the address of a server says about it. Not secret.
final class AddressFacts {
  const AddressFacts({
    required this.publicKey,
    required this.discoPublicKey,
    required this.hasPresharedKey,
    required this.regionId,
    required this.regions,
  });

  factory AddressFacts.from(TailcatAddressInfo info) => AddressFacts(
    publicKey: info.publicKey,
    discoPublicKey: info.discoPublicKey,
    hasPresharedKey: info.hasPresharedKey,
    regionId: info.regionId,
    regions: info.regions,
  );

  final String publicKey;

  final String discoPublicKey;

  final bool hasPresharedKey;

  /// 0 when the address embeds the region.
  final int regionId;

  final List<Map<String, Object?>> regions;

  RelayInfo? get relay =>
      regions.isEmpty ? null : Relays.fromRegion(regions.first);
}

final class HostConfig {
  const HostConfig({
    required this.privateKey,
    required this.presharedKey,
    required this.paths,
    this.region,
    this.regionId,
    this.allowedClients = const [],
    this.udpIdleTimeout = const Duration(seconds: 30),
  });

  final TailcatPrivateKey privateKey;

  final TailcatPresharedKey presharedKey;

  /// With neither this nor [regionId], the server picks the nearest region.
  final Map<String, Object?>? region;

  final int? regionId;

  /// Empty admits anyone with the address.
  final List<String> allowedClients;

  final Duration udpIdleTimeout;

  /// Other paths get a 404, which tells an app on another protocol version
  /// to update.
  final Set<String> paths;
}

/// A resource the app holds open, for the Inspector.
final class OpenResource {
  const OpenResource(this.kind, this.description);

  /// server, client, listener, socket or flow.
  final String kind;

  final String description;

  @override
  String toString() => '$kind $description';
}

/// The host's `TailcatServer` with its HTTP and UDP listeners.
abstract interface class HostLink {
  /// Secret.
  TailcatAddress get address;

  AddressFacts get addressFacts;

  String get publicKey;

  String get tunnelAddress;

  Stream<IncomingChannel> get channels;

  /// Each flow arrives with its first datagram.
  Stream<DatagramFlow> get flows;

  List<OpenResource> get resources;

  Future<void> close({bool drain = true});
}

abstract interface class GuestLink {
  String get publicKey;

  /// Throws [TimeoutException] when the host doesn't answer in [timeout], and
  /// [ProtocolMismatchException] when it doesn't serve [path].
  Future<MessageChannel> connect(String path, {required Duration timeout});

  /// The host only sees the flow once the first datagram arrives.
  Future<DatagramFlow> openFlow();

  Future<TailcatPath> discoPing();

  /// Over the relay, in whole milliseconds.
  Future<Duration> ping();

  List<OpenResource> get resources;

  Future<void> close({bool drain = true});
}

/// The host answered a WebSocket upgrade with 404: it speaks another
/// protocol version.
final class ProtocolMismatchException implements Exception {
  const ProtocolMismatchException(this.path);

  final String path;

  @override
  String toString() =>
      'ProtocolMismatchException: the other side does not serve $path';
}

abstract interface class Network {
  TailcatKeys generateKeys();

  /// Throws [TailcatArgumentException] when [address] is not an address.
  AddressFacts parseAddress(TailcatAddress address);

  Future<HostLink> startHost(HostConfig config);

  /// No network I/O until the first call on the client.
  GuestLink openGuest({
    required TailcatAddress address,
    required TailcatPrivateKey privateKey,
  });
}
