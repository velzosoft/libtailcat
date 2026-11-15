// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'bindings/native_api.dart' as native;
import 'json.dart';
import 'runtime/blocking.dart' as blocking;
import 'runtime/library.dart';
import 'secret.dart';

/// The address of a Tailcat server: its keys and relay. Secret; share the
/// [reveal]ed text out of band.
final class TailcatAddress extends TailcatSecret {
  /// Wraps an address in its text encoding, without validating it.
  const TailcatAddress(String value) : super(value, 'TailcatAddress');

  /// Decodes the public metadata, without network access.
  ///
  /// Throws [TailcatArgumentException] when the address is malformed.
  TailcatAddressInfo parse() {
    ensureNativeLibrary();
    return TailcatAddressInfo._(
      JsonObject.decode(native.parseAddress(reveal()), what: 'address'),
    );
  }

  /// Returns this address with its relay embedded, looking the region up in
  /// the relay map at [derpMapUrl] (default: Tailcat's public map) if needed.
  ///
  /// A `null` [timeout] means a finite default.
  Future<TailcatAddress> resolve({
    String? derpMapUrl,
    Duration? timeout,
  }) async {
    ensureNativeLibrary();
    return TailcatAddress(
      await blocking.resolveAddress(reveal(), derpMapUrl, timeout),
    );
  }
}

/// The public metadata of a [TailcatAddress]. Contains no secret.
final class TailcatAddressInfo {
  TailcatAddressInfo._(JsonObject json)
    : publicKey = json.string('public_key'),
      discoPublicKey = json.string('disco_public_key'),
      hasPresharedKey = json.boolean('has_preshared_key'),
      regionId = json.integer('region_id'),
      regions = List.unmodifiable(json.objects('regions'));

  /// The server's public node key.
  final String publicKey;

  /// The server's public key for path discovery.
  final String discoPublicKey;

  /// Whether the address carries a pre-shared key (never included here).
  final bool hasPresharedKey;

  /// The relay region id, or 0 when the address embeds [regions] instead.
  final int regionId;

  /// The embedded relay regions as Tailscale `DERPRegion` JSON; empty when
  /// the address uses [regionId].
  final List<Map<String, Object?>> regions;

  /// Whether a client can use the address without fetching the relay map.
  bool get isSelfContained => regions.isNotEmpty;

  @override
  String toString() =>
      'TailcatAddressInfo(publicKey: $publicKey, '
      'hasPresharedKey: $hasPresharedKey, regionId: $regionId, '
      'regions: ${regions.length})';
}
