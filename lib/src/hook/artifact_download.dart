// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:crypto/crypto.dart';

/// SHA-256 of [file] as lowercase hex.
Future<String> sha256OfFile(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// A download whose content does not have the pinned SHA-256.
final class ChecksumMismatch implements Exception {
  /// Creates the exception.
  const ChecksumMismatch(this.url, this.expected, this.actual);

  /// Where the content came from.
  final Uri url;

  /// The pinned digest.
  final String expected;

  /// The digest of what was received.
  final String actual;

  @override
  String toString() =>
      'checksum mismatch for $url: expected $expected, got $actual';
}

/// Downloads and verifies prebuilt native libraries.
final class ArtifactDownloader {
  /// Creates a downloader that caches into [cacheDir] and logs via [log].
  ArtifactDownloader({
    required this.cacheDir,
    required this.log,
    HttpClient Function()? createHttpClient,
  }) : _createHttpClient = createHttpClient ?? HttpClient.new;

  /// Directory for verified downloads.
  final Uri cacheDir;

  /// Progress sink.
  final void Function(String message) log;

  final HttpClient Function() _createHttpClient;

  /// Returns a cached or downloaded copy of [url] verified against
  /// [expectedSha256]. Throws [ChecksumMismatch] or an [IOException]; nothing
  /// unverified stays in the cache.
  Future<File> fetch({
    required Uri url,
    required String expectedSha256,
    required String fileName,
  }) async {
    await Directory.fromUri(cacheDir).create(recursive: true);
    final target = File.fromUri(
      cacheDir.resolve('${expectedSha256.substring(0, 16)}-$fileName'),
    );
    if (target.existsSync() && await sha256OfFile(target) == expectedSha256) {
      log('libtailcat: using cached ${target.path}');
      return target;
    }
    // Per process, so concurrent hook runs never share a partial file.
    final temp = File('${target.path}.$pid.part');
    log('libtailcat: downloading $url');
    final client = _createHttpClient();
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'GET $url returned HTTP ${response.statusCode}',
          uri: url,
        );
      }
      await response.pipe(temp.openWrite());
      final actual = await sha256OfFile(temp);
      if (actual != expectedSha256) {
        throw ChecksumMismatch(url, expectedSha256, actual);
      }
      await temp.rename(target.path);
      return target;
    } finally {
      client.close(force: true);
      if (temp.existsSync()) await temp.delete();
    }
  }
}
