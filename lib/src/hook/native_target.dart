// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:code_assets/code_assets.dart';

/// A platform the native library is built for, mapped to Go's `GOOS`/`GOARCH`
/// and to release artifact names.
final class NativeTarget {
  /// Creates a target.
  const NativeTarget({
    required this.os,
    required this.architecture,
    this.iosSdk,
    this.androidNdkApi,
    this.macosVersion,
    this.iosVersion,
  });

  /// Reads the target from a build hook's code configuration.
  factory NativeTarget.fromCodeConfig(CodeConfig code) => NativeTarget(
    os: code.targetOS,
    architecture: code.targetArchitecture,
    iosSdk: code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
    iosVersion: code.targetOS == OS.iOS
        ? code.iOS.deploymentVersion.major
        : null,
    androidNdkApi: code.targetOS == OS.android
        ? code.android.targetNdkApi
        : null,
    macosVersion: code.targetOS == OS.macOS
        ? code.macOS.deploymentVersion.major
        : null,
  );

  /// Every target a native release publishes, in `SHA256SUMS` order.
  static const List<NativeTarget> releaseTargets = [
    NativeTarget(os: OS.macOS, architecture: Architecture.arm64),
    NativeTarget(os: OS.macOS, architecture: Architecture.x64),
    NativeTarget(
      os: OS.iOS,
      architecture: Architecture.arm64,
      iosSdk: IOSSdk.iPhoneOS,
    ),
    NativeTarget(
      os: OS.iOS,
      architecture: Architecture.arm64,
      iosSdk: IOSSdk.iPhoneSimulator,
    ),
    NativeTarget(
      os: OS.iOS,
      architecture: Architecture.x64,
      iosSdk: IOSSdk.iPhoneSimulator,
    ),
    NativeTarget(os: OS.linux, architecture: Architecture.x64),
    NativeTarget(os: OS.linux, architecture: Architecture.arm64),
    NativeTarget(os: OS.windows, architecture: Architecture.x64),
    NativeTarget(os: OS.android, architecture: Architecture.arm64),
    NativeTarget(os: OS.android, architecture: Architecture.x64),
    NativeTarget(os: OS.android, architecture: Architecture.arm),
  ];

  /// Go's macOS floor, which is above Flutter's.
  static const int minimumMacosVersion = 13;

  /// Minimum iOS version (the arm64 simulator slice ends up at 14).
  static const int minimumIosVersion = 13;

  /// Minimum Android API level (Flutter's `minSdkVersion`).
  static const int minimumAndroidApi = 24;

  /// Target OS.
  final OS os;

  /// Target CPU architecture.
  final Architecture architecture;

  /// Device or simulator SDK (iOS only).
  final IOSSdk? iosSdk;

  /// Android NDK API level (Android only).
  final int? androidNdkApi;

  /// Deployment target major version (macOS only).
  final int? macosVersion;

  /// Deployment target major version (iOS only).
  final int? iosVersion;

  /// Whether libtailcat is built for this target.
  bool get isSupported => switch (os) {
    OS.macOS || OS.linux =>
      architecture == Architecture.arm64 || architecture == Architecture.x64,
    OS.windows => architecture == Architecture.x64,
    OS.iOS =>
      architecture == Architecture.arm64 ||
          (architecture == Architecture.x64 &&
              iosSdk == IOSSdk.iPhoneSimulator),
    OS.android =>
      architecture == Architecture.arm64 ||
          architecture == Architecture.x64 ||
          architecture == Architecture.arm,
    _ => false,
  };

  /// Why the target is unsupported, for error messages.
  String get unsupportedReason => switch (os) {
    OS.macOS ||
    OS.linux ||
    OS.windows ||
    OS.iOS ||
    OS.android => 'libtailcat is not built for $architecture on $os',
    _ => 'libtailcat does not support $os',
  };

  /// `GOOS` for this target.
  String get goos => switch (os) {
    OS.macOS => 'darwin',
    OS.iOS => 'ios',
    OS.linux => 'linux',
    OS.android => 'android',
    OS.windows => 'windows',
    _ => throw UnsupportedError(unsupportedReason),
  };

  /// `GOARCH` for this target.
  String get goarch => switch (architecture) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'amd64',
    Architecture.arm => 'arm',
    _ => throw UnsupportedError(unsupportedReason),
  };

  /// File extension of the dynamic library, without the dot.
  String get libraryExtension => switch (os) {
    OS.linux || OS.android => 'so',
    OS.windows => 'dll',
    _ => 'dylib',
  };

  /// The file name bundled into the app; the same for every architecture.
  String get libraryFileName => 'libtailcat.$libraryExtension';

  /// E.g. `libtailcat-ios-arm64-iphonesimulator`.
  String get artifactKey {
    final sdk = iosSdk;
    final suffix = sdk == null ? '' : '-${sdk.type}';
    return 'libtailcat-${os.name}-${architecture.name}$suffix';
  }

  /// File name of the prebuilt artifact on the release page.
  String get artifactFileName => '$artifactKey.$libraryExtension';

  /// At least [minimumMacosVersion].
  int get effectiveMacosVersion => _atLeast(macosVersion, minimumMacosVersion);

  /// At least [minimumIosVersion].
  int get effectiveIosVersion => _atLeast(iosVersion, minimumIosVersion);

  /// At least [minimumAndroidApi].
  int get effectiveAndroidApi => _atLeast(androidNdkApi, minimumAndroidApi);

  static int _atLeast(int? value, int minimum) =>
      value == null || value < minimum ? minimum : value;

  @override
  String toString() => artifactKey;
}
