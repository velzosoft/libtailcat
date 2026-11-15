// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'process.dart';

/// The pin file, relative to the package root.
const upstreamPinPath = 'native/UPSTREAM';

/// The vendored Go build tags, relative to the package root.
const buildTagsPath = 'native/build-tags.txt';

/// The upstream commit the native library is built from (`native/UPSTREAM`).
final class UpstreamPin {
  /// Creates a pin.
  const UpstreamPin({
    required this.repository,
    required this.commit,
    required this.goVersion,
    required this.abiVersion,
  });

  /// Parses `key: value` lines, skipping `#` comments. Throws
  /// [FormatException] when a key is missing or malformed.
  factory UpstreamPin.parse(String text) {
    final values = <String, String>{};
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) throw FormatException('expected "key: value"', raw);
      values[line.substring(0, colon).trim()] = line
          .substring(colon + 1)
          .trim();
    }
    String required(String key, RegExp pattern) {
      final value = values[key];
      if (value == null || !pattern.hasMatch(value)) {
        throw FormatException('missing or malformed "$key"', value);
      }
      return value;
    }

    return UpstreamPin(
      repository: required('repository', RegExp(r'^https://\S+$')),
      commit: required('commit', RegExp(r'^[0-9a-f]{40}$')),
      goVersion: required('go', RegExp(r'^\d+\.\d+(\.\d+)?$')),
      abiVersion: int.parse(required('abi', RegExp(r'^\d+$'))),
    );
  }

  /// Reads the pin file under [packageRoot].
  factory UpstreamPin.read(Uri packageRoot) {
    final file = File.fromUri(packageRoot.resolve(upstreamPinPath));
    try {
      return UpstreamPin.parse(file.readAsStringSync());
    } on FormatException catch (e) {
      throw FormatException('${file.path}: ${e.message}', e.source);
    }
  }

  /// Upstream git URL.
  final String repository;

  /// Full commit hash.
  final String commit;

  /// The `go` directive of upstream's `go.mod` at [commit].
  final String goVersion;

  /// The C ABI version `tailcat.h` declares at [commit].
  final int abiVersion;

  /// The first 12 hex digits of [commit], as in release tags.
  String get shortCommit => commit.substring(0, 12);

  /// `GOTOOLCHAIN` for source builds: exactly upstream's Go, since a newer one
  /// can break the pinned dependencies; `+auto` still honours `go.mod`.
  String get goToolchain => 'go$goVersion+auto';

  @override
  String toString() => '$repository@$shortCommit';
}

/// Obtains the upstream sources at a pinned commit.
final class UpstreamSources {
  /// Creates a fetcher that reports progress through [log].
  const UpstreamSources({required this.log});

  /// Progress sink.
  final void Function(String message) log;

  /// Returns a shallow checkout of [pin] under [cacheDir], fetching it once.
  ///
  /// Safe to call concurrently: each caller fetches into its own directory and
  /// moves it into place when complete. Throws [ToolException] if git fails.
  Future<Uri> ensure(UpstreamPin pin, Uri cacheDir) async {
    final name = 'tailcat-src-${pin.commit}';
    final dir = Directory.fromUri(cacheDir.resolve(name));
    if (_isComplete(dir)) return dir.uri;
    final temp = Directory.fromUri(
      cacheDir.resolve('$name.${uniqueSuffix()}.part'),
    );
    try {
      await temp.create(recursive: true);
      log('libtailcat: fetching ${pin.repository} @ ${pin.commit}');
      Future<void> git(List<String> arguments) =>
          runTool('git', arguments, workingDirectory: temp.path);
      await git(['init', '-q']);
      await git(['remote', 'add', 'origin', pin.repository]);
      await git(['fetch', '-q', '--depth', '1', 'origin', pin.commit]);
      await git(['checkout', '-q', 'FETCH_HEAD']);
      await File.fromUri(temp.uri.resolve(_marker)).writeAsString('ok\n');
      await _moveIntoPlace(temp, dir);
    } finally {
      if (temp.existsSync()) await temp.delete(recursive: true);
    }
    return dir.uri;
  }

  /// Written last into a checkout, so a directory without it is partial.
  static const _marker = '.libtailcat-checkout-ok';

  static bool _isComplete(Directory dir) =>
      File.fromUri(dir.uri.resolve(_marker)).existsSync();

  /// Renaming onto a non-empty directory fails everywhere, so a complete [to]
  /// is never replaced.
  static Future<void> _moveIntoPlace(Directory from, Directory to) async {
    if (_isComplete(to)) return;
    try {
      await from.rename(to.path);
      return;
    } on FileSystemException {
      if (_isComplete(to)) return;
    }
    // A partial checkout from an older version that fetched in place;
    // another caller may be removing it too.
    try {
      await to.delete(recursive: true);
    } on FileSystemException {
      // Already gone.
    }
    try {
      await from.rename(to.path);
    } on FileSystemException {
      if (!_isComplete(to)) rethrow;
    }
  }

  /// Whether [dir] looks like a Tailcat checkout that has the C ABI.
  static bool looksLikeCheckout(Uri dir) =>
      File.fromUri(dir.resolve('cmd/libtailcat/main.go')).existsSync();
}
