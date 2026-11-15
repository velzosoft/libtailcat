// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Builds a native library with the hook's source-mode plan, for releases.
///
/// Prints a `sha256sum` line for `SHA256SUMS` and writes build info as
/// `<artifact>.json`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:libtailcat/src/hook/artifact_download.dart';
import 'package:libtailcat/src/hook/go_build.dart';
import 'package:libtailcat/src/hook/native_target.dart';
import 'package:libtailcat/src/hook/process.dart';
import 'package:libtailcat/src/hook/upstream.dart';

Future<void> main(List<String> args) async {
  final options = _parse(args);
  final packageRoot = Directory.current.uri;
  final pin = UpstreamPin.read(packageRoot);
  final target = NativeTarget(
    os: options.os,
    architecture: options.arch,
    iosSdk: options.iosSdk,
    androidNdkApi: options.androidApi,
  );
  final builder = GoBuilder(log: stderr.writeln);
  final outDir = _directory(options.out);
  final goToolchain = options.goToolchain ?? pin.goToolchain;
  try {
    final goVersion = await builder.goVersion(
      options.go,
      goToolchain: goToolchain,
    );
    final sourceDir = options.source != null
        ? _directory(options.source!)
        : await UpstreamSources(
            log: stderr.writeln,
          ).ensure(pin, outDir.resolve('cache/'));
    final (iosSdkPath, macosSdkPath) = await builder.sdkPathsFor(target);
    final cc = options.cc == null ? null : File(options.cc!).absolute.uri;
    final plan = GoBuildPlan.forTarget(
      target,
      sourceDir: sourceDir,
      // Per target: intermediate files have fixed names.
      outputDir: outDir.resolve('${target.artifactKey}/'),
      buildTags: await File.fromUri(
        packageRoot.resolve(buildTagsPath),
      ).readAsString(),
      goExecutable: options.go,
      goToolchain: goToolchain,
      cCompiler: cc == null
          ? null
          : CCompilerConfig(compiler: cc, linker: cc, archiver: cc),
      iosSdkPath: iosSdkPath,
      macosSdkPath: macosSdkPath,
      androidPatch: packageRoot.resolve(androidPatchPath),
    );
    final built = await builder.build(plan);
    final artifact = File.fromUri(outDir.resolve(target.artifactFileName));
    await File.fromUri(built).copy(artifact.path);
    final digest = await sha256OfFile(artifact);
    await File('${artifact.path}.json').writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({
        'artifact': target.artifactFileName,
        'sha256': digest,
        'upstream': {'repository': pin.repository, 'commit': pin.commit},
        'go': goVersion,
        'patches': plan.patches,
      })}\n',
    );
    stdout.writeln('$digest  ${target.artifactFileName}');
  } on ToolException catch (e) {
    stderr.writeln('error: $e');
    exit(1);
  }
}

Uri _directory(String path) {
  final uri = Directory(path).absolute.uri.normalizePath();
  return uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
}

final class _Options {
  _Options({
    required this.os,
    required this.arch,
    required this.out,
    this.iosSdk,
    this.androidApi,
    this.source,
    this.cc,
    this.go = 'go',
    this.goToolchain,
  });

  final OS os;
  final Architecture arch;
  final String out;
  final IOSSdk? iosSdk;
  final int? androidApi;
  final String? source;
  final String? cc;
  final String go;
  final String? goToolchain;
}

_Options _parse(List<String> args) {
  String? os, arch, out, iosSdk, androidApi, source, cc, goToolchain;
  var go = 'go';
  for (var i = 0; i < args.length; i++) {
    String next() {
      if (i + 1 >= args.length) _usage('missing value for ${args[i]}');
      return args[++i];
    }

    switch (args[i]) {
      case '--os':
        os = next();
      case '--arch':
        arch = next();
      case '--out':
        out = next();
      case '--ios-sdk':
        iosSdk = next();
      case '--android-api':
        androidApi = next();
      case '--source':
        source = next();
      case '--cc':
        cc = next();
      case '--go':
        go = next();
      case '--go-toolchain':
        goToolchain = next();
      case '--help' || '-h':
        _usage(null);
      default:
        _usage('unknown argument ${args[i]}');
    }
  }
  if (os == null || arch == null || out == null) {
    _usage('--os, --arch and --out are required');
  }
  return _Options(
    os: OS.fromString(os),
    arch: Architecture.fromString(arch),
    out: out,
    iosSdk: iosSdk == null
        ? (os == 'ios' ? IOSSdk.iPhoneOS : null)
        : IOSSdk.fromString(iosSdk),
    androidApi: androidApi == null ? null : int.parse(androidApi),
    source: source,
    cc: cc,
    // The build runs in the checkout, so relative paths would break.
    go: File(go).existsSync() ? File(go).absolute.path : go,
    goToolchain: goToolchain,
  );
}

Never _usage(String? error) {
  if (error != null) stderr.writeln('error: $error\n');
  stderr.writeln(
    'usage: dart run tool/build_native.dart '
    '--os <macos|linux|windows|ios|android> --arch <arm64|x64|arm> '
    '--out <dir> [--ios-sdk iphoneos|iphonesimulator] [--android-api 24] '
    '[--source <tailcat checkout>] [--cc <clang>] [--go <go>] '
    '[--go-toolchain <GOTOOLCHAIN>|local]',
  );
  exit(error == null ? 0 : 64);
}
