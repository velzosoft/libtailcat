// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Pure helpers behind `tool/update_manifest.dart`.
library;

import 'package:libtailcat/src/hook/native_target.dart';

final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _tagPattern = RegExp(r"const nativeReleaseTag = '([^']*)';");
final _mapPattern = RegExp(
  r'const nativeArtifacts = <String, String>\{(.*?)\};',
  dotAll: true,
);
final _entryPattern = RegExp(r"'([^']+)':\s*'([0-9a-f]{64})'");

/// E.g. `native-e00cdde6ff78-1`: 12 hex digits of the commit and a build
/// number.
final releaseTagPattern = RegExp(r'^native-[0-9a-f]{12}-[1-9][0-9]*$');

/// Parses `sha256sum` output. Throws [FormatException] on malformed lines or
/// duplicates.
Map<String, String> parseSha256Sums(String text) {
  final result = <String, String>{};
  for (final (index, raw) in text.split('\n').indexed) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(\S+)$').firstMatch(line);
    if (match == null) {
      throw FormatException('line ${index + 1} is not "<sha256>  <file>"', raw);
    }
    final name = match.group(2)!;
    if (result.containsKey(name)) {
      throw FormatException('line ${index + 1}: duplicate entry for $name');
    }
    result[name] = match.group(1)!.toLowerCase();
  }
  return result;
}

/// The artifact file names a release must contain, in manifest order.
List<String> get releaseArtifactNames => [
  for (final target in NativeTarget.releaseTargets) target.artifactFileName,
];

({List<String> missing, List<String> unexpected}) checkArtifactSet(
  Map<String, String> artifacts,
) {
  final expected = releaseArtifactNames;
  return (
    missing: [
      for (final name in expected)
        if (!artifacts.containsKey(name)) name,
    ],
    unexpected: [
      for (final name in artifacts.keys)
        if (!expected.contains(name)) name,
    ]..sort(),
  );
}

({String tag, Map<String, String> artifacts}) readManifest(String source) {
  final tag = _tagPattern.firstMatch(source);
  final map = _mapPattern.firstMatch(source);
  if (tag == null || map == null) {
    throw const FormatException(
      'manifest has no nativeReleaseTag / nativeArtifacts constants',
    );
  }
  return (
    tag: tag.group(1)!,
    artifacts: {
      for (final entry in _entryPattern.allMatches(map.group(1)!))
        entry.group(1)!: entry.group(2)!,
    },
  );
}

/// Returns [source] with the tag and artifact constants replaced. The result
/// needs `dart format`.
String updateManifestSource(
  String source, {
  required String tag,
  required Map<String, String> artifacts,
}) {
  for (final entry in artifacts.entries) {
    if (!_hex64.hasMatch(entry.value)) {
      throw FormatException(
        '${entry.key}: not a SHA-256 hex digest',
        entry.value,
      );
    }
    if (entry.key.contains("'") || entry.key.contains(r'$')) {
      throw FormatException('unsafe artifact name', entry.key);
    }
  }
  if (!releaseTagPattern.hasMatch(tag)) {
    throw FormatException('not a native release tag', tag);
  }
  readManifest(source); // validates
  final ordered = [
    for (final name in releaseArtifactNames)
      if (artifacts.containsKey(name)) name,
    ...checkArtifactSet(artifacts).unexpected,
  ];
  final body = ordered.isEmpty
      ? '{}'
      : '{\n${ordered.map((n) => "  '$n':\n      '${artifacts[n]}',").join('\n')}\n}';
  return source
      .replaceFirst(_tagPattern, "const nativeReleaseTag = '$tag';")
      .replaceFirst(
        _mapPattern,
        'const nativeArtifacts = <String, String>$body;',
      );
}
