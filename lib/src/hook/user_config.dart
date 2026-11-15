// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import 'package:hooks/hooks.dart';

/// Git-ignored developer override of the pubspec user-defines, read only when
/// the root package names it with `local_config`.
///
/// Relative paths resolve against the file's directory. Hooks get a filtered
/// environment, so env vars can't configure the build.
const localConfigFileName = 'hook/local_config.json';

/// Where the build hook gets the native library from.
enum NativeMode {
  /// Download the pinned prebuilt library and verify its SHA-256 (default).
  download,

  /// Use the library the application supplies through `path`.
  local,

  /// Build with Go from the pinned upstream commit.
  source;

  /// Parses the `native` user-define; `null` is [download]. Throws
  /// [BuildError] for an unknown value.
  static NativeMode parse(Object? value) {
    if (value == null) return download;
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    throw BuildError(
      message:
          'libtailcat: unknown "native" mode "$value"; expected one of '
          '${values.map((mode) => mode.name).join(', ')}',
    );
  }
}

/// The build hook's settings, from the root pubspec's user-defines (see the
/// README).
final class HookUserConfig {
  /// Creates a configuration.
  const HookUserConfig({
    this.mode = NativeMode.download,
    this.localPath,
    this.cacheDir,
    this.sourceDir,
    this.goExecutable,
    this.goToolchain,
    this.allowMissingNative = false,
    this.skipUnsupportedTargets = false,
  });

  /// Reads the user-defines in [input], overridden by the local config file.
  factory HookUserConfig.from(BuildInput input) {
    final defines = input.userDefines;
    final file = localConfigFile(input);
    final local = file == null ? null : LocalHookConfig.read(file);
    return HookUserConfig.resolve(
      value: (key) =>
          local != null && local.has(key) ? local.value(key) : defines[key],
      path: (key) =>
          local != null && local.has(key) ? local.path(key) : defines.path(key),
    );
  }

  /// Builds a configuration from raw [value] and absolute [path] lookups.
  factory HookUserConfig.resolve({
    required Object? Function(String key) value,
    required Uri? Function(String key) path,
  }) {
    String? text(String key) {
      final raw = value(key);
      return raw is String && raw.isNotEmpty ? raw : null;
    }

    Uri? directory(String key) {
      final uri = path(key);
      return uri == null ? null : _withTrailingSlash(uri);
    }

    final mode = NativeMode.parse(value('native'));
    final localPath = path('path');
    if (mode == NativeMode.local && localPath == null) {
      throw BuildError(
        message:
            'libtailcat: "native: local" needs "path", a prebuilt library or '
            'a directory that contains one',
      );
    }
    return HookUserConfig(
      mode: mode,
      localPath: localPath,
      cacheDir: directory('cache_dir'),
      sourceDir: directory('source_dir'),
      goExecutable: text('go'),
      goToolchain: text('go_toolchain'),
      allowMissingNative: _truthy(value('allow_missing_native')),
      skipUnsupportedTargets: _truthy(value('skip_unsupported_targets')),
    );
  }

  /// The file named by `local_config`, which need not exist; `null` if unset.
  static File? localConfigFile(BuildInput input) {
    final uri = input.userDefines.path('local_config');
    return uri == null ? null : File.fromUri(uri);
  }

  /// Where the library comes from.
  final NativeMode mode;

  /// A prebuilt library, or a directory holding one.
  final Uri? localPath;

  /// Download cache; defaults to the hook's shared output directory.
  final Uri? cacheDir;

  /// Upstream checkout; defaults to a fetch of the pinned commit.
  final Uri? sourceDir;

  /// The `go` executable; defaults to `go` on `PATH`.
  final String? goExecutable;

  /// `GOTOOLCHAIN` for source builds; `null` means the pinned default.
  final String? goToolchain;

  /// Emit no asset when the library is unavailable (this package's tests).
  final bool allowMissingNative;

  /// Build without the library on targets it doesn't exist for; calls into
  /// libtailcat then fail there. Supported targets still fail the build.
  final bool skipUnsupportedTargets;

  static bool _truthy(Object? value) => switch (value) {
    final bool b => b,
    final String s => const {
      '1',
      'true',
      'yes',
      'on',
    }.contains(s.toLowerCase()),
    final int i => i != 0,
    _ => false,
  };

  static Uri _withTrailingSlash(Uri uri) =>
      uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');

  @override
  String toString() =>
      'HookUserConfig(mode: ${mode.name}, path: $localPath, '
      'cacheDir: $cacheDir, sourceDir: $sourceDir, go: $goExecutable, '
      'goToolchain: $goToolchain, allowMissingNative: $allowMissingNative, '
      'skipUnsupportedTargets: $skipUnsupportedTargets)';
}

/// The parsed [localConfigFileName] file.
final class LocalHookConfig {
  /// Relative paths resolve against [baseUri], the file's directory.
  const LocalHookConfig(this.values, this.baseUri);

  /// `null` when [file] doesn't exist; throws [BuildError] unless it holds a
  /// JSON object.
  static LocalHookConfig? read(File file) {
    if (!file.existsSync()) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw BuildError(message: '${file.path} is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw BuildError(message: '${file.path} must contain a JSON object');
    }
    return LocalHookConfig(decoded, file.parent.uri);
  }

  /// Decoded key/value pairs.
  final Map<String, Object?> values;

  /// Base for relative paths.
  final Uri baseUri;

  /// Whether [key] is set to a non-null value.
  bool has(String key) => values[key] != null;

  /// Raw value of [key].
  Object? value(String key) => values[key];

  /// [key] interpreted as a path, resolved against [baseUri].
  Uri? path(String key) {
    final raw = values[key];
    if (raw is! String || raw.isEmpty) return null;
    return baseUri.resolveUri(Uri.file(raw));
  }
}
