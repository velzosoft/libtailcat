// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:libtailcat/src/hook/native_manifest.dart';
import 'package:test/test.dart';

import '../../tool/src/manifest_update.dart';

String _digest(int seed) => seed.toRadixString(16).padLeft(64, '0');

void main() {
  const tag = 'native-e00cdde6ff78-1';
  final complete = {
    for (final (index, name) in releaseArtifactNames.indexed)
      name: _digest(index + 1),
  };
  final committed = File(
    'lib/src/hook/native_manifest.dart',
  ).readAsStringSync();

  group('parseSha256Sums', () {
    test('reads sha256sum output', () {
      expect(
        parseSha256Sums('''
# a comment
${_digest(1)}  libtailcat-linux-x64.so
${_digest(2).toUpperCase()} *libtailcat-windows-x64.dll

'''),
        {
          'libtailcat-linux-x64.so': _digest(1),
          'libtailcat-windows-x64.dll': _digest(2),
        },
      );
    });

    test('rejects malformed and duplicate lines', () {
      expect(() => parseSha256Sums('abc  file'), throwsFormatException);
      expect(() => parseSha256Sums(_digest(1)), throwsFormatException);
      expect(
        () => parseSha256Sums('${_digest(1)}  a\n${_digest(2)}  a'),
        throwsFormatException,
      );
    });
  });

  test('a release is checked against the release targets', () {
    final full = checkArtifactSet(complete);
    expect(full.missing, isEmpty);
    expect(full.unexpected, isEmpty);

    final partial = {...complete}
      ..remove('libtailcat-windows-x64.dll')
      ..['libtailcat-plan9-x64.so'] = _digest(99);
    final (:missing, :unexpected) = checkArtifactSet(partial);
    expect(missing, ['libtailcat-windows-x64.dll']);
    expect(unexpected, ['libtailcat-plan9-x64.so']);
  });

  test('release tags name the upstream commit and a build number', () {
    expect(releaseTagPattern.hasMatch(tag), isTrue);
    for (final bad in [
      'native-v1.0.0',
      'native-e00cdde6ff78',
      'native-E00CDDE6FF78-1',
      'native-e00cdde6ff78-0',
    ]) {
      expect(releaseTagPattern.hasMatch(bad), isFalse, reason: bad);
    }
  });

  group('the committed manifest', () {
    test('can be read back', () {
      final current = readManifest(committed);
      expect(current.tag, nativeReleaseTag);
      expect(current.artifacts, nativeArtifacts);
    });

    test('is rewritten in release-target order and round-trips', () {
      final shuffled = Map.fromEntries(complete.entries.toList().reversed);
      final updated = updateManifestSource(
        committed,
        tag: tag,
        artifacts: shuffled,
      );
      final reread = readManifest(updated);
      expect(reread.tag, tag);
      expect(reread.artifacts, complete);
      expect(reread.artifacts.keys, orderedEquals(releaseArtifactNames));
      // The rest of the file is untouched.
      expect(updated, contains('const nativeReleaseBaseUrl ='));
      expect(updated, contains('final class NativeManifest'));
      // Idempotent.
      expect(
        updateManifestSource(updated, tag: tag, artifacts: complete),
        updated,
      );
    });

    test('refuses input that could corrupt the Dart source', () {
      expect(
        () => updateManifestSource(
          committed,
          tag: "x'; evil();",
          artifacts: complete,
        ),
        throwsFormatException,
      );
      expect(
        () => updateManifestSource(
          committed,
          tag: tag,
          artifacts: {"a'b": _digest(1)},
        ),
        throwsFormatException,
      );
      expect(
        () => updateManifestSource(
          committed,
          tag: tag,
          artifacts: {'a': 'nothex'},
        ),
        throwsFormatException,
      );
      expect(
        () => updateManifestSource(
          'no constants here',
          tag: tag,
          artifacts: complete,
        ),
        throwsFormatException,
      );
    });
  });
}
