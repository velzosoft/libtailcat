// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

final class RelayInfo {
  const RelayInfo({this.regionId, this.code, this.city, this.hostName});

  /// Such as 303.
  final int? regionId;

  /// Such as `fra`.
  final String? code;

  final String? city;

  /// Such as `tc303a.ipn.dev`.
  final String? hostName;

  String get label => city ?? code ?? hostName ?? 'relay';

  @override
  String toString() => 'RelayInfo($label)';
}

/// Maps relays to cities.
///
/// An address embeds its region renumbered as region 1, code "1", no name,
/// and `discoPing` reports that code too. Only the node's host name keeps the
/// real id (`tc303a.ipn.dev` is 303), so the city comes from there.
abstract final class Relays {
  /// From https://tailcat.dev/derpmap.json, checked 2026-11-15.
  static const Map<int, ({String code, String city})> publicRegions = {
    301: (code: 'nyc', city: 'New York City'),
    302: (code: 'sfo', city: 'San Francisco'),
    303: (code: 'fra', city: 'Frankfurt'),
    304: (code: 'tok', city: 'Tokyo'),
  };

  static final _publicHost = RegExp(r'^tc(\d+)[a-z]*\.');

  /// [region] is a `DERPRegion` in JSON, from `TailcatAddressInfo.regions`.
  static RelayInfo fromRegion(Map<String, Object?> region) {
    final hostName = switch (region['Nodes']) {
      [final Map<String, Object?> node, ...] => switch (node['HostName']) {
        final String host when host.isNotEmpty => host,
        _ => null,
      },
      _ => null,
    };
    final publicId = switch (_publicHost.firstMatch(hostName ?? '')) {
      final match? => int.parse(match.group(1)!),
      null => null,
    };
    final known = publicRegions[publicId];
    if (known != null) {
      return RelayInfo(
        regionId: publicId,
        code: known.code,
        city: known.city,
        hostName: hostName,
      );
    }
    String? text(String key) => switch (region[key]) {
      final String value when value.isNotEmpty => value,
      _ => null,
    };
    return RelayInfo(
      regionId: switch (region['RegionID']) {
        final int id => id,
        _ => null,
      },
      code: text('RegionCode'),
      city: text('RegionName'),
      hostName: hostName,
    );
  }

  /// Falls back to [embedded] when the code says nothing (see above).
  static RelayInfo fromCode(String? code, {RelayInfo? embedded}) {
    for (final MapEntry(key: id, value: region) in publicRegions.entries) {
      if (region.code == code) {
        return RelayInfo(regionId: id, code: region.code, city: region.city);
      }
    }
    return embedded ?? RelayInfo(code: code);
  }
}
