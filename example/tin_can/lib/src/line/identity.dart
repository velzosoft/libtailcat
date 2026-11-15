// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:libtailcat/libtailcat.dart';

enum Role {
  /// Runs a `TailcatServer` for as long as the string exists.
  host,

  /// Only ever runs a `TailcatClient`.
  guest,
}

/// Everything one side needs to reach the other again.
///
/// Keys are fresh per string and deleted on cut, so cutting never needs to
/// take a key off an allowlist, which libtailcat can't do.
sealed class StringIdentity {
  const StringIdentity({required this.partnerName, required this.tiedAt});

  factory StringIdentity.fromJson(Map<String, Object?> json) {
    String text(String key) => switch (json[key]) {
      final String value => value,
      _ => throw FormatException('stored string: "$key" is missing'),
    };
    final tiedAt =
        DateTime.tryParse(text('tiedAt')) ??
        (throw const FormatException('stored string: bad "tiedAt"'));
    return switch (text('role')) {
      'host' => HostIdentity(
        privateKey: TailcatPrivateKey(text('privateKey')),
        presharedKey: TailcatPresharedKey(text('presharedKey')),
        region: switch (json['region']) {
          final Map<String, Object?> region => region,
          _ => null,
        },
        regionId: switch (json['regionId']) {
          final int id => id,
          _ => null,
        },
        partnerKey: text('partnerKey'),
        partnerName: text('partnerName'),
        tiedAt: tiedAt,
      ),
      'guest' => GuestIdentity(
        privateKey: TailcatPrivateKey(text('privateKey')),
        publicKey: switch (json['publicKey']) {
          final String key => key,
          _ => null,
        },
        hostAddress: TailcatAddress(text('hostAddress')),
        partnerName: text('partnerName'),
        tiedAt: tiedAt,
      ),
      final role => throw FormatException('stored string: role "$role"'),
    };
  }

  Role get role;

  final String partnerName;

  final DateTime tiedAt;

  StringIdentity withPartnerName(String name);

  /// Contains secrets.
  Map<String, Object?> toJson();
}

/// Pinning the region keeps the server's address stable across starts.
final class HostIdentity extends StringIdentity {
  const HostIdentity({
    required this.privateKey,
    required this.presharedKey,
    required this.partnerKey,
    this.region,
    this.regionId,
    required super.partnerName,
    required super.tiedAt,
  });

  /// Secret.
  final TailcatPrivateKey privateKey;

  /// Secret.
  final TailcatPresharedKey presharedKey;

  /// The `DERPRegion` JSON the first server's address embedded. Public relays
  /// always embed it; otherwise [regionId] is set.
  final Map<String, Object?>? region;

  final int? regionId;

  /// The only entry on the allowlist.
  final String partnerKey;

  @override
  Role get role => Role.host;

  @override
  HostIdentity withPartnerName(String name) => HostIdentity(
    privateKey: privateKey,
    presharedKey: presharedKey,
    region: region,
    regionId: regionId,
    partnerKey: partnerKey,
    partnerName: name,
    tiedAt: tiedAt,
  );

  @override
  Map<String, Object?> toJson() => {
    'role': 'host',
    'privateKey': privateKey.reveal(),
    'presharedKey': presharedKey.reveal(),
    'region': ?region,
    'regionId': ?regionId,
    'partnerKey': partnerKey,
    'partnerName': partnerName,
    'tiedAt': tiedAt.toUtc().toIso8601String(),
  };

  @override
  String toString() => 'HostIdentity(partner: $partnerName)';
}

final class GuestIdentity extends StringIdentity {
  const GuestIdentity({
    required this.privateKey,
    required this.hostAddress,
    this.publicKey,
    required super.partnerName,
    required super.tiedAt,
  });

  /// Secret.
  final TailcatPrivateKey privateKey;

  final String? publicKey;

  /// Secret.
  final TailcatAddress hostAddress;

  @override
  Role get role => Role.guest;

  @override
  GuestIdentity withPartnerName(String name) => GuestIdentity(
    privateKey: privateKey,
    publicKey: publicKey,
    hostAddress: hostAddress,
    partnerName: name,
    tiedAt: tiedAt,
  );

  @override
  Map<String, Object?> toJson() => {
    'role': 'guest',
    'privateKey': privateKey.reveal(),
    'publicKey': ?publicKey,
    'hostAddress': hostAddress.reveal(),
    'partnerName': partnerName,
    'tiedAt': tiedAt.toUtc().toIso8601String(),
  };

  @override
  String toString() => 'GuestIdentity(partner: $partnerName)';
}
