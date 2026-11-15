// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Builds the Go programs the tests need from the pinned upstream checkout.
library;

import 'dart:convert';
import 'dart:io';

import 'package:libtailcat/src/hook/process.dart';
import 'package:libtailcat/src/hook/upstream.dart';
import 'package:libtailcat/src/hook/user_config.dart';

/// Go programs built from the pinned upstream checkout.
final class GoTools {
  GoTools({Uri? packageRoot, void Function(String message)? log})
    : packageRoot = packageRoot ?? Directory.current.uri,
      _log = log ?? stderr.writeln;

  final Uri packageRoot;

  final void Function(String message) _log;

  Uri get cacheDir => packageRoot.resolve('.dart_tool/libtailcat/');

  late final UpstreamPin pin = UpstreamPin.read(packageRoot);

  Uri? _checkout;

  static bool get isGoInstalled {
    try {
      return Process.runSync('go', ['version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// The `source_dir` from `hook/local_config.json`, else a fetch of the
  /// pinned commit.
  Future<Uri> checkout() async => _checkout ??=
      _configuredCheckout() ??
      await UpstreamSources(log: _log).ensure(pin, cacheDir);

  /// The local DERP relay and STUN server in `tool/testrelay`.
  Future<File> testRelay() => _build(
    name: 'testrelay',
    package: './cmd/libtailcat-testrelay',
    overlay: {'cmd/libtailcat-testrelay/main.go': 'tool/testrelay/main.go'},
  );

  /// Upstream's `tailcat` CLI.
  Future<File> cli() => _build(name: 'tailcat', package: './cmd/tailcat');

  Uri? _configuredCheckout() {
    final local = LocalHookConfig.read(
      File.fromUri(packageRoot.resolve(localConfigFileName)),
    );
    final configured = local?.path('source_dir');
    if (configured == null) return null;
    return configured.path.endsWith('/')
        ? configured
        : configured.replace(path: '${configured.path}/');
  }

  /// [overlay] maps checkout paths to files of this package, compiled in
  /// without touching the checkout.
  ///
  /// Parallel test files build the same tools, so builds take turns behind a
  /// file lock: Windows can't replace a binary another test is running.
  Future<File> _build({
    required String name,
    required String package,
    Map<String, String> overlay = const {},
  }) async {
    final source = await checkout();
    final bin = Directory.fromUri(cacheDir.resolve('bin/'));
    await bin.create(recursive: true);
    final output = File.fromUri(
      bin.uri.resolve(Platform.isWindows ? '$name.exe' : name),
    );
    // Unique per build so none reads another's half-written copy. The name
    // doesn't affect Go's up-to-date check.
    final overlayFile = File.fromUri(
      bin.uri.resolve('$name-overlay.${uniqueSuffix()}.json'),
    );
    final lock = await File.fromUri(
      bin.uri.resolve('.build.lock'),
    ).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      await overlayFile.writeAsString(
        jsonEncode({
          'Replace': {
            for (final MapEntry(:key, :value) in overlay.entries)
              source.resolve(key).toFilePath(): packageRoot
                  .resolve(value)
                  .toFilePath(),
          },
        }),
      );
      await runTool(
        'go',
        ['build', '-overlay', overlayFile.path, '-o', output.path, package],
        workingDirectory: source.toFilePath(),
        environment: {'GOFLAGS': '-mod=readonly'},
      );
    } finally {
      await lock.close();
      if (overlayFile.existsSync()) await overlayFile.delete();
    }
    return output;
  }
}
