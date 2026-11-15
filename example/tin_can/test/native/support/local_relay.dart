// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import 'package:libtailcat/libtailcat.dart';

import '../../../../../tool/src/go_tools.dart';

final Uri libtailcatRoot = Directory.current.uri.resolve('../../');

/// A `skip:` reason when the native library or Go is missing, else `null`.
final String? nativeUnavailable = () {
  try {
    Tailcat.abiVersion;
  } on TailcatFailureException {
    return 'no native library; put {"native": "source"} in '
        'hook/local_config.json at the repository root';
  }
  if (!GoTools.isGoInstalled) return 'Go is needed to build the test relay';
  return null;
}();

/// A DERP relay and STUN server on 127.0.0.1.
final class LocalRelay {
  LocalRelay._(this._process, this.region);

  final Process _process;

  /// A `DERPRegion`, for `TailcatServerConfig.region`.
  final Map<String, Object?> region;

  static Future<LocalRelay> start() async {
    final tools = GoTools(packageRoot: libtailcatRoot, log: (_) {});
    final binary = await tools.testRelay();
    final process = await Process.start(binary.path, const []);
    final line = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    final region = (jsonDecode(line) as Map<String, Object?>)['region'];
    return LocalRelay._(process, region! as Map<String, Object?>);
  }

  Future<void> stop() async {
    await _process.stdin.close();
    await _process.exitCode;
  }
}
