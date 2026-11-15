// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';

import 'address.dart';
import 'keys.dart';

/// How a [TailcatClient] reaches its server.
final class TailcatClientConfig {
  /// Creates a client configuration.
  const TailcatClientConfig({
    required this.address,
    this.privateKey,
    this.derpMapUrl,
  });

  /// The address of the server to connect to.
  final TailcatAddress address;

  /// The client's identity; generated when omitted.
  final TailcatPrivateKey? privateKey;

  /// The relay map URL, used when [address] doesn't embed its relay.
  /// Defaults to Tailcat's public map; `none` forbids the lookup.
  final String? derpMapUrl;

  @override
  String toString() =>
      'TailcatClientConfig(address: $address, '
      'privateKey: ${privateKey == null ? 'generated' : '<redacted>'}, '
      'derpMapUrl: $derpMapUrl)';
}

/// How a [TailcatServer] identifies itself and which relay it uses.
final class TailcatServerConfig {
  /// Creates a server configuration.
  const TailcatServerConfig({
    this.privateKey,
    this.presharedKey,
    this.regionId,
    this.region,
    this.derpMapUrl,
    this.allowedClients = const [],
    this.udpIdleTimeout,
  });

  /// The server's identity; generated when omitted. Persist it with
  /// [presharedKey] to keep the address stable.
  final TailcatPrivateKey? privateKey;

  /// The pre-shared key clients must know; generated when omitted.
  final TailcatPresharedKey? presharedKey;

  /// The relay region id. Without this or [region], the nearest is picked.
  final int? regionId;

  /// Your own relay region as Tailscale `DERPRegion` JSON (Go field names,
  /// e.g. `RegionID`); no relay map is fetched.
  final Map<String, Object?>? region;

  /// The relay map URL when [region] is unset. Defaults to Tailcat's.
  final String? derpMapUrl;

  /// Public keys of clients allowed to connect; empty admits everyone.
  final List<String> allowedClients;

  /// How long a UDP flow may stay idle before it's dropped; `null` uses the
  /// native default.
  final Duration? udpIdleTimeout;

  @override
  String toString() =>
      'TailcatServerConfig('
      'privateKey: ${privateKey == null ? 'generated' : '<redacted>'}, '
      'presharedKey: ${presharedKey == null ? 'generated' : '<redacted>'}, '
      'regionId: $regionId, region: ${region == null ? null : '<custom>'}, '
      'derpMapUrl: $derpMapUrl, allowedClients: ${allowedClients.length}, '
      'udpIdleTimeout: $udpIdleTimeout)';
}

/// The JSON `tc_client_new` expects. Contains secrets.
String encodeClientConfig(TailcatClientConfig config) => jsonEncode({
  'address': config.address.reveal(),
  'key': ?config.privateKey?.reveal(),
  'derp_map_url': ?config.derpMapUrl,
});

/// The JSON `tc_server_new` expects. Contains secrets.
String encodeServerConfig(TailcatServerConfig config) {
  final udpIdleTimeout = config.udpIdleTimeout;
  return jsonEncode({
    'key': ?config.privateKey?.reveal(),
    'preshared_key': ?config.presharedKey?.reveal(),
    'region_id': ?config.regionId,
    'region': ?config.region,
    'derp_map_url': ?config.derpMapUrl,
    if (config.allowedClients.isNotEmpty)
      'allowed_clients': config.allowedClients,
    if (udpIdleTimeout != null)
      'udp_idle_timeout':
          udpIdleTimeout.inMicroseconds / Duration.microsecondsPerSecond,
  });
}
