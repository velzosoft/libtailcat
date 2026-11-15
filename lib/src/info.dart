// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'bindings/native_api.dart' as native;
import 'json.dart';
import 'runtime/errors.dart';
import 'runtime/library.dart';

/// Static facts about the bundled native library.
abstract final class Tailcat {
  /// The C ABI version of the bundled library.
  ///
  /// Throws [TailcatFailureException] when the library is missing or its ABI
  /// is unsupported.
  static int get abiVersion {
    ensureNativeLibrary();
    return native.abiVersion();
  }

  /// How the bundled library was built.
  static TailcatBuildInfo get buildInfo {
    ensureNativeLibrary();
    return TailcatBuildInfo._(
      JsonObject.decode(native.buildInfo(), what: 'build info'),
    );
  }
}

/// How the bundled native library was built.
final class TailcatBuildInfo {
  TailcatBuildInfo._(JsonObject json)
    : abiVersion = json.integer('abi_version'),
      go = switch (json.fields['go']) {
        final Map<String, Object?> go => Map.unmodifiable(go),
        _ => const {},
      };

  /// The C ABI version.
  final int abiVersion;

  /// Go's `runtime/debug.BuildInfo` (`GoVersion`, `Deps`, `Settings`).
  final Map<String, Object?> go;

  /// The Go release the library was compiled with, e.g. `go1.27.2`.
  String? get goVersion => switch (go['GoVersion']) {
    final String version => version,
    _ => null,
  };

  @override
  String toString() =>
      'TailcatBuildInfo(abiVersion: $abiVersion, goVersion: $goVersion)';
}

/// The path a client's packets take to its server: relayed at first, direct
/// once NAT traversal succeeds.
final class TailcatPath {
  /// Creates a path description.
  const TailcatPath({
    required this.latency,
    this.endpoint,
    this.derpRegionId = 0,
    this.derpRegionCode,
  });

  /// Decodes the JSON `tc_client_disco_ping` returns.
  factory TailcatPath.fromJson(String source) {
    final json = JsonObject.decode(source, what: 'disco ping');
    return TailcatPath(
      latency: Duration(
        microseconds: (json.number('latency') * Duration.microsecondsPerSecond)
            .round(),
      ),
      endpoint: json.optionalString('endpoint'),
      derpRegionId: json.integer('derp_region_id'),
      derpRegionCode: json.optionalString('derp_region_code'),
    );
  }

  /// Round-trip time of the probe.
  final Duration latency;

  /// The peer's `ip:port` when the path is direct, otherwise `null`.
  final String? endpoint;

  /// The id of the relay region when the path is relayed, otherwise 0.
  final int derpRegionId;

  /// The code of the relay region (such as `nyc`) when the path is relayed.
  final String? derpRegionCode;

  /// Whether packets travel peer to peer rather than through a relay.
  bool get isDirect => endpoint != null;

  @override
  String toString() => isDirect
      ? 'TailcatPath(direct via $endpoint, $latency)'
      : 'TailcatPath(relayed via ${derpRegionCode ?? derpRegionId}, $latency)';
}

/// One end of a connection or listener inside the tunnel.
final class Endpoint {
  /// Creates an endpoint.
  const Endpoint(this.address, this.port);

  /// Parses `host:port` (IPv6 in brackets), as `tc_info` reports it.
  factory Endpoint.parse(String hostPort) {
    final colon = hostPort.lastIndexOf(':');
    final port = colon < 0 ? null : int.tryParse(hostPort.substring(colon + 1));
    if (port == null) {
      throw TailcatFailureException('unexpected endpoint "$hostPort"');
    }
    return Endpoint(parseAddress(hostPort.substring(0, colon)), port);
  }

  /// Parses a numeric IP address, with or without brackets.
  static InternetAddress parseAddress(String host) {
    final bare = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    final address = InternetAddress.tryParse(bare);
    if (address == null) {
      throw TailcatFailureException('unexpected address "$host"');
    }
    return address;
  }

  /// The IP address.
  final InternetAddress address;

  /// The port.
  final int port;

  @override
  String toString() => address.type == InternetAddressType.IPv6
      ? '[${address.address}]:$port'
      : '${address.address}:$port';
}

/// What `tc_info` reports for a started server.
final class ServerInfo {
  /// Decodes the JSON.
  factory ServerInfo.fromJson(String source) {
    final json = JsonObject.decode(source, what: 'server info');
    return ServerInfo._(
      json.string('address'),
      json.string('public_key'),
      Endpoint.parseAddress(json.string('local_address')),
    );
  }

  const ServerInfo._(this.address, this.publicKey, this.localAddress);

  /// The shareable address. Secret.
  final String address;

  /// The public node key.
  final String publicKey;

  /// The server's IP address inside the tunnel.
  final InternetAddress localAddress;
}

/// The `public_key` field of the `tc_info` JSON of a client.
String clientPublicKey(String source) =>
    JsonObject.decode(source, what: 'client info').string('public_key');

/// The `local_address` field of the `tc_info` JSON of a listener.
Endpoint listenerEndpoint(String source) => Endpoint.parse(
  JsonObject.decode(source, what: 'listener info').string('local_address'),
);

/// The two ends of a connection, from its `tc_info` JSON.
({Endpoint local, Endpoint remote}) connectionEndpoints(String source) {
  final json = JsonObject.decode(source, what: 'connection info');
  return (
    local: Endpoint.parse(json.string('local_address')),
    remote: Endpoint.parse(json.string('remote_address')),
  );
}
