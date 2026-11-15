// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'artifact_download.dart';
import 'go_build.dart';
import 'native_manifest.dart';
import 'native_target.dart';
import 'process.dart';
import 'upstream.dart';
import 'user_config.dart';

/// A resolved native library.
final class ResolvedLibrary {
  /// Creates the result.
  const ResolvedLibrary(this.file, this.mode, {this.dependencies = const []});

  /// The library file in the hook's output directory.
  final Uri file;

  /// How it was obtained.
  final NativeMode mode;

  /// Files whose change should re-run the hook.
  final List<Uri> dependencies;
}

/// Obtains the native library for a target as [HookUserConfig.mode] asks.
final class NativeLibraryResolver {
  /// Creates a resolver.
  NativeLibraryResolver({
    required this.target,
    required this.config,
    required this.packageRoot,
    required this.outputDirectory,
    required this.sharedDirectory,
    required this.log,
    this.cCompiler,
    this.manifest = NativeManifest.pinned,
    GoBuilder? builder,
    ArtifactDownloader? downloader,
  }) : _builder = builder ?? GoBuilder(log: log),
       _downloader =
           downloader ??
           ArtifactDownloader(
             cacheDir: config.cacheDir ?? sharedDirectory,
             log: log,
           );

  /// The platform being built.
  final NativeTarget target;

  /// User configuration.
  final HookUserConfig config;

  /// Root of this package.
  final Uri packageRoot;

  /// The per-build output directory.
  final Uri outputDirectory;

  /// Cache shared across builds.
  final Uri sharedDirectory;

  /// Progress sink.
  final void Function(String message) log;

  /// Compiler toolchain from the hook input (Android).
  final CCompilerConfig? cCompiler;

  /// The prebuilt artifacts to download from.
  final NativeManifest manifest;

  final GoBuilder _builder;
  final ArtifactDownloader _downloader;

  /// Returns `null` when `allow_missing_native` is set and no library could
  /// be downloaded; throws [BuildError] otherwise. Unsupported targets always
  /// throw (the hook handles `skip_unsupported_targets` before this).
  Future<ResolvedLibrary?> resolve() async {
    if (!target.isSupported) {
      throw BuildError(
        message:
            'libtailcat: ${target.unsupportedReason}.\n'
            'If this app never uses libtailcat on this platform, build '
            'without the native library:\n'
            '${_userDefine('skip_unsupported_targets: true')}',
      );
    }
    return switch (config.mode) {
      NativeMode.local => _fromLocal(config.localPath!),
      NativeMode.source => _fromSource(),
      NativeMode.download => _fromRelease(),
    };
  }

  Future<ResolvedLibrary> _fromLocal(Uri path) async {
    final type = FileSystemEntity.typeSync(path.toFilePath());
    final candidates = switch (type) {
      FileSystemEntityType.file => [path],
      FileSystemEntityType.directory => [
        for (final name in [target.artifactFileName, target.libraryFileName])
          Directory.fromUri(path).uri.resolve(name),
      ],
      _ => const <Uri>[],
    };
    for (final candidate in candidates) {
      final file = File.fromUri(candidate);
      if (!file.existsSync()) continue;
      final installed = await _install(file);
      log('libtailcat: using local ${file.path}');
      return ResolvedLibrary(
        installed,
        NativeMode.local,
        dependencies: [candidate],
      );
    }
    throw BuildError(
      message: type == FileSystemEntityType.directory
          ? 'libtailcat: ${path.toFilePath()} contains neither '
                '${target.artifactFileName} nor ${target.libraryFileName}'
          : 'libtailcat: "path" ${path.toFilePath()} is not a library or a '
                'directory',
    );
  }

  Future<ResolvedLibrary> _fromSource() async {
    try {
      final pin = UpstreamPin.read(packageRoot);
      final go = config.goExecutable ?? 'go';
      final toolchain = config.goToolchain ?? pin.goToolchain;
      log(
        'libtailcat: ${await _builder.goVersion(go, goToolchain: toolchain)}',
      );
      final sourceDir = await _sourceDirectory(pin);
      final (iosSdk, macosSdk) = await _builder.sdkPathsFor(target);
      final buildTags = packageRoot.resolve(buildTagsPath);
      final androidPatch = packageRoot.resolve(androidPatchPath);
      final plan = GoBuildPlan.forTarget(
        target,
        sourceDir: sourceDir,
        outputDir: outputDirectory,
        buildTags: await File.fromUri(buildTags).readAsString(),
        goExecutable: go,
        goToolchain: toolchain,
        cCompiler: cCompiler,
        iosSdkPath: iosSdk,
        macosSdkPath: macosSdk,
        androidPatch: androidPatch,
      );
      final file = await _builder.build(plan);
      return ResolvedLibrary(
        file,
        NativeMode.source,
        dependencies: [
          packageRoot.resolve(upstreamPinPath),
          buildTags,
          if (plan.patches.isNotEmpty) androidPatch,
          // A checkout the developer edits; a fetched one never changes.
          if (config.sourceDir != null) ...[
            sourceDir.resolve('cmd/libtailcat/main.go'),
            sourceDir.resolve('go.mod'),
          ],
        ],
      );
    } on ToolException catch (e) {
      throw BuildError(message: 'libtailcat: source build failed: $e');
    } on StateError catch (e) {
      throw BuildError(
        message: 'libtailcat: source build failed: ${e.message}',
      );
    } on FormatException catch (e) {
      throw BuildError(message: 'libtailcat: ${e.message}');
    } on FileSystemException catch (e) {
      throw BuildError(message: 'libtailcat: source build failed: $e');
    }
  }

  Future<Uri> _sourceDirectory(UpstreamPin pin) async {
    final configured = config.sourceDir;
    if (configured == null) {
      return UpstreamSources(log: log).ensure(pin, sharedDirectory);
    }
    if (!UpstreamSources.looksLikeCheckout(configured)) {
      throw StateError(
        'source_dir ${configured.toFilePath()} has no cmd/libtailcat/main.go',
      );
    }
    return configured;
  }

  Future<ResolvedLibrary?> _fromRelease() async {
    final url = manifest.urlOf(target.artifactFileName);
    if (url == null) {
      const consequence =
          'Calls into libtailcat will fail at runtime because '
          'allow_missing_native is set.';
      if (config.allowMissingNative) {
        log(
          'libtailcat: no prebuilt library for ${target.artifactKey}. '
          '$consequence',
        );
        return null;
      }
      throw BuildError(
        message:
            'libtailcat: no prebuilt library is published for '
            '${target.artifactKey}'
            '${manifest.releaseTag.isEmpty ? '' : ' (release ${manifest.releaseTag})'}'
            '.\nBuild it from source (needs Go and a C toolchain):\n'
            '${_userDefine('native: source')}\n'
            'or supply ${target.libraryFileName} yourself:\n'
            '${_userDefine('native: local\n        path: <library or directory>')}',
      );
    }
    try {
      final cached = await _downloader.fetch(
        url: url,
        expectedSha256: manifest.sha256Of(target.artifactFileName)!,
        fileName: target.artifactFileName,
      );
      return ResolvedLibrary(
        await _install(cached),
        NativeMode.download,
        dependencies: [cached.uri],
      );
    } on ChecksumMismatch catch (e) {
      // Fatal even with allow_missing_native.
      throw BuildError(message: 'libtailcat: $e');
    } on IOException catch (e) {
      final message =
          'libtailcat: download of $url failed: $e\n'
          'Offline or behind a proxy? Use "native: local" with a library '
          'you downloaded yourself, or "native: source".';
      if (!config.allowMissingNative) throw BuildError(message: message);
      log(
        '$message\nlibtailcat: continuing without the native library '
        'because allow_missing_native is set.',
      );
      return null;
    }
  }

  Future<Uri> _install(File source) async {
    await Directory.fromUri(outputDirectory).create(recursive: true);
    final destination = outputDirectory.resolve(target.libraryFileName);
    await source.copy(destination.toFilePath());
    return destination;
  }

  static String _userDefine(String body) =>
      '  hooks:\n    user_defines:\n      libtailcat:\n        $body';
}
