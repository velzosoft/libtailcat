// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';

import 'native_target.dart';
import 'process.dart';

/// Go package of the C ABI inside the upstream checkout.
const libtailcatPackage = './cmd/libtailcat';

/// Go file overlaid into [libtailcatPackage] on Android to give netmon an
/// interface source, which cgo Android builds of upstream lack.
const androidPatchPath = 'native/patches/android_ifaces.go';

/// The patch's file name inside the upstream package.
const androidPatchOverlayName = 'zz_libtailcat_dart_android_ifaces.go';

/// A helper file a plan needs on disk before its steps run.
typedef PlanFile = ({Uri path, String contents, bool executable});

/// One external process invocation of a [GoBuildPlan].
final class ProcessStep {
  /// Creates a step.
  const ProcessStep({
    required this.description,
    required this.executable,
    required this.arguments,
    this.environment = const {},
    this.workingDirectory,
  });

  /// Human-readable purpose.
  final String description;

  /// Program to run.
  final String executable;

  /// Arguments.
  final List<String> arguments;

  /// Merged over the parent environment.
  final Map<String, String> environment;

  /// Working directory, if not the current one.
  final String? workingDirectory;

  @override
  String toString() => '$description: $executable ${arguments.join(' ')}';
}

/// The commands that build the dynamic library for one [NativeTarget]. Pure;
/// [GoBuilder] runs it.
final class GoBuildPlan {
  const GoBuildPlan._({
    required this.target,
    required this.steps,
    required this.outputFile,
    this.extraFiles = const [],
    this.patches = const [],
  });

  /// [cCompiler] is required on Android, [iosSdkPath] on iOS and
  /// [androidPatch] on Android. [macosSdkPath] becomes `-isysroot`, which
  /// Xcode build phases need: their filtered environment has no `SDKROOT`.
  factory GoBuildPlan.forTarget(
    NativeTarget target, {
    required Uri sourceDir,
    required Uri outputDir,
    required String buildTags,
    required String goToolchain,
    String goExecutable = 'go',
    CCompilerConfig? cCompiler,
    String? iosSdkPath,
    String? macosSdkPath,
    Uri? androidPatch,
  }) {
    if (!target.isSupported) {
      throw UnsupportedError(target.unsupportedReason);
    }
    final src = sourceDir.toFilePath();
    final libName = target.libraryFileName;
    final out = outputDir.resolve(libName).toFilePath();
    final env = <String, String>{
      'CGO_ENABLED': '1',
      'GOOS': target.goos,
      'GOARCH': target.goarch,
      // Never rewrite upstream's go.mod.
      'GOFLAGS': '-mod=readonly',
      'GOTOOLCHAIN': goToolchain,
    };

    // `-buildid=` and `-trimpath` keep the output reproducible.
    List<String> goBuild({
      required String mode,
      required String output,
      String ldflags = '-s -w -buildid=',
      List<String> extra = const [],
    }) => [
      'build',
      '-trimpath',
      '-buildvcs=false',
      '-tags',
      buildTags.trim(),
      ...extra,
      '-ldflags',
      ldflags,
      '-buildmode=$mode',
      '-o',
      output,
      libtailcatPackage,
    ];

    switch (target.os) {
      case OS.macOS:
        final min = '-mmacosx-version-min=${target.effectiveMacosVersion}.0';
        final sysroot = macosSdkPath == null ? '' : ' -isysroot $macosSdkPath';
        return GoBuildPlan._(
          target: target,
          outputFile: Uri.file(out),
          steps: [
            ProcessStep(
              description: 'go build (c-shared, macOS ${target.goarch})',
              executable: goExecutable,
              arguments: goBuild(mode: 'c-shared', output: out),
              environment: {
                ...env,
                'MACOSX_DEPLOYMENT_TARGET': '${target.effectiveMacosVersion}.0',
                'SDKROOT': ?macosSdkPath,
                'CGO_CFLAGS': '$min$sysroot',
                // Room for the install name Dart and Flutter rewrite later.
                'CGO_LDFLAGS':
                    '$min$sysroot -Wl,-headerpad_max_install_names '
                    '-Wl,-install_name,@rpath/$libName',
              },
              workingDirectory: src,
            ),
          ],
        );

      case OS.linux:
        return GoBuildPlan._(
          target: target,
          outputFile: Uri.file(out),
          steps: [
            ProcessStep(
              description: 'go build (c-shared, Linux ${target.goarch})',
              executable: goExecutable,
              arguments: goBuild(mode: 'c-shared', output: out),
              environment: {
                ...env,
                'CC': ?cCompiler?.compiler.toFilePath(),
                'CGO_LDFLAGS': '-Wl,-soname,$libName',
              },
              workingDirectory: src,
            ),
          ],
        );

      case OS.windows:
        // cgo needs gcc (MinGW-w64) on PATH; the hook's MSVC is no use.
        return GoBuildPlan._(
          target: target,
          outputFile: Uri.file(out),
          steps: [
            ProcessStep(
              description: 'go build (c-shared, Windows ${target.goarch})',
              executable: goExecutable,
              arguments: goBuild(mode: 'c-shared', output: out),
              environment: env,
              workingDirectory: src,
            ),
          ],
        );

      case OS.android:
        final cc = cCompiler?.compiler.toFilePath();
        if (cc == null) {
          throw StateError(
            'Android builds need the NDK compiler; the hook input did not '
            'provide one (input.config.code.cCompiler)',
          );
        }
        final patch = androidPatch;
        if (patch == null) {
          throw StateError(
            'Android builds need $androidPatchPath from this package',
          );
        }
        // Flutter passes the NDK's generic clang, which targets the host
        // without --target (harmless if [cc] is a per-API wrapper).
        final api = target.effectiveAndroidApi;
        final triple = switch (target.architecture) {
          Architecture.arm64 => 'aarch64-linux-android',
          Architecture.x64 => 'x86_64-linux-android',
          Architecture.arm => 'armv7a-linux-androideabi',
          _ => throw UnsupportedError(target.unsupportedReason),
        };
        final targetFlag = '--target=$triple$api';
        // -overlay compiles the patch in without touching the checkout.
        final overlayFile = outputDir.resolve('overlay-android.json');
        final overlayJson = jsonEncode({
          'Replace': {
            sourceDir
                .resolve('cmd/libtailcat/$androidPatchOverlayName')
                .toFilePath(): patch
                .toFilePath(),
          },
        });
        return GoBuildPlan._(
          target: target,
          outputFile: Uri.file(out),
          patches: [androidPatchPath],
          extraFiles: [
            (path: overlayFile, contents: overlayJson, executable: false),
          ],
          steps: [
            ProcessStep(
              description:
                  'go build (c-shared, Android ${target.goarch}, API $api)',
              executable: goExecutable,
              arguments: goBuild(
                mode: 'c-shared',
                output: out,
                extra: ['-overlay', overlayFile.toFilePath()],
              ),
              environment: {
                ...env,
                'CC': cc,
                if (target.architecture == Architecture.arm) 'GOARM': '7',
                'CGO_CFLAGS': targetFlag,
                // Google Play requires 16 KB pages; Go leaves the soname empty.
                'CGO_LDFLAGS':
                    '$targetFlag -Wl,-z,max-page-size=16384 '
                    '-Wl,-soname,$libName',
              },
              workingDirectory: src,
            ),
          ],
        );

      case OS.iOS:
        // Go has no c-shared mode for iOS: build a c-archive, then link the
        // dylib by hand.
        final sdkPath = iosSdkPath;
        if (sdkPath == null) {
          throw StateError(
            'iOS builds need the SDK path (xcrun --show-sdk-path)',
          );
        }
        final simulator = target.iosSdk == IOSSdk.iPhoneSimulator;
        final sdkName = simulator ? 'iphonesimulator' : 'iphoneos';
        final clangArch = target.architecture == Architecture.x64
            ? 'x86_64'
            : 'arm64';
        final minFlag = simulator
            ? '-mios-simulator-version-min=${target.effectiveIosVersion}.0'
            : '-miphoneos-version-min=${target.effectiveIosVersion}.0';
        final wrapper = outputDir.resolve('clangwrap-$sdkName-$clangArch.sh');
        final archive = outputDir.resolve('libtailcat-$sdkName-$clangArch.a');
        final wrapperScript =
            '#!/bin/sh\n'
            '# Generated by the libtailcat build: clang for Go cgo on iOS.\n'
            'exec "\$(xcrun --sdk $sdkName --find clang)" '
            '-arch $clangArch -isysroot "$sdkPath" $minFlag "\$@"\n';
        return GoBuildPlan._(
          target: target,
          outputFile: Uri.file(out),
          extraFiles: [
            (path: wrapper, contents: wrapperScript, executable: true),
          ],
          steps: [
            ProcessStep(
              description: 'go build (c-archive, iOS $sdkName $clangArch)',
              executable: goExecutable,
              arguments: goBuild(
                mode: 'c-archive',
                output: archive.toFilePath(),
                // The dylib link below strips.
                ldflags: '-w -buildid=',
              ),
              environment: {...env, 'CC': wrapper.toFilePath()},
              workingDirectory: src,
            ),
            ProcessStep(
              description: 'clang -dynamiclib (iOS $sdkName $clangArch)',
              executable: 'xcrun',
              arguments: [
                '--sdk',
                sdkName,
                'clang',
                '-dynamiclib',
                '-arch',
                clangArch,
                '-isysroot',
                sdkPath,
                minFlag,
                // Room for the install name Flutter rewrites.
                '-Wl,-headerpad_max_install_names',
                '-Wl,-force_load,${archive.toFilePath()}',
                '-Wl,-x',
                '-framework',
                'CoreFoundation',
                '-framework',
                'Security',
                '-lresolv',
                '-install_name',
                '@rpath/$libName',
                '-o',
                out,
              ],
            ),
          ],
        );

      default:
        throw UnsupportedError(target.unsupportedReason);
    }
  }

  /// The target.
  final NativeTarget target;

  /// Steps to run in order.
  final List<ProcessStep> steps;

  /// The produced library.
  final Uri outputFile;

  /// Helper files to write before running the steps.
  final List<PlanFile> extraFiles;

  /// Package-relative paths of the Go patches compiled into the library.
  final List<String> patches;
}

/// Runs [GoBuildPlan]s and prepares their inputs (toolchain, SDK paths).
final class GoBuilder {
  /// Creates a builder that reports progress through [log].
  const GoBuilder({required this.log});

  /// Progress sink.
  final void Function(String message) log;

  /// The Go version [goToolchain] selects, which may download it.
  Future<String> goVersion(
    String goExecutable, {
    required String goToolchain,
  }) async {
    final ProcessResult result;
    try {
      result = await runTool(
        goExecutable,
        ['version'],
        environment: {'GOTOOLCHAIN': goToolchain},
      );
    } on ToolException catch (e) {
      throw ToolException(
        '${e.message}\nInstall Go or set the `go` user-define to its path.',
      );
    }
    return (result.stdout as String).trim();
  }

  /// `xcrun --sdk <sdkName> --show-sdk-path` (`macosx`, `iphoneos`, ...).
  Future<String> appleSdkPath(String sdkName) async {
    final result = await runTool('xcrun', [
      '--sdk',
      sdkName,
      '--show-sdk-path',
    ]);
    return (result.stdout as String).trim();
  }

  /// `(iosSdkPath, macosSdkPath)` for [target]; nulls off Apple targets.
  Future<(String?, String?)> sdkPathsFor(NativeTarget target) async =>
      switch (target.os) {
        OS.iOS => (await appleSdkPath(target.iosSdk!.type), null),
        OS.macOS => (null, await appleSdkPath('macosx')),
        _ => (null, null),
      };

  /// Runs [plan] and returns the library; throws [ToolException] on failure.
  Future<Uri> build(GoBuildPlan plan) async {
    final outputDir = Directory.fromUri(plan.outputFile.resolve('.'));
    await outputDir.create(recursive: true);
    for (final extra in plan.extraFiles) {
      final file = File.fromUri(extra.path);
      await file.writeAsString(extra.contents);
      if (extra.executable) await runTool('chmod', ['+x', file.path]);
    }
    for (final step in plan.steps) {
      log('libtailcat: ${step.description}');
      await runTool(
        step.executable,
        step.arguments,
        environment: step.environment,
        workingDirectory: step.workingDirectory,
      );
    }
    if (!File.fromUri(plan.outputFile).existsSync()) {
      throw ToolException(
        'build finished but ${plan.outputFile.toFilePath()} is missing',
      );
    }
    return plan.outputFile;
  }
}
