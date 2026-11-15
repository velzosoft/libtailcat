// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Pinned prebuilt native artifacts, rewritten by `tool/update_manifest.dart`.
library;

/// `native-<commit>-<n>`; empty until a native release is pinned.
const nativeReleaseTag = 'native-e00cdde6ff78-1';

/// Base URL of GitHub release downloads.
const nativeReleaseBaseUrl =
    'https://github.com/velzosoft/libtailcat/releases/download';

/// SHA-256 (hex) by `NativeTarget.artifactFileName`. Generated; don't edit.
const nativeArtifacts = <String, String>{
  'libtailcat-macos-arm64.dylib':
      '423e1f01d3ed9318c606028804ce404b734efffe728c12003b10df30edc79a38',
  'libtailcat-macos-x64.dylib':
      '8de6243c56f0086e1963cce4c6457625aca46ccd74805a431a8c6812eff47321',
  'libtailcat-ios-arm64-iphoneos.dylib':
      'ac9292e2c5fd7e1b94e7df4b847e5055c35135ede7c6e59107c80d4a886cbbe6',
  'libtailcat-ios-arm64-iphonesimulator.dylib':
      '9665edcff52180810ca6e0b40513a083bc1550cbe9fee9a5a4b2d4f12fe88473',
  'libtailcat-ios-x64-iphonesimulator.dylib':
      '3416eb501ee18e7eda72cfb598d482949863525b4bfda4a1a271227dd45e44c2',
  'libtailcat-linux-x64.so':
      'b46a793ff528226d237e5cb02cf2b23a2a6ef7bb50152ce69e31a947538e4bc2',
  'libtailcat-linux-arm64.so':
      'c21d122bb925fa7354481f9d8c386dc33387a4eb82fbf516d0cd7e8559b172eb',
  'libtailcat-windows-x64.dll':
      'b6c5c91eb154233926ed3f8f5cd2a6dfb8ee7221350a81119f0a310bda542a92',
  'libtailcat-android-arm64.so':
      '7c4727ed95e95c66bab86bd5bc80c6a6e063cd88a6ddbdac5928f886936dd7c2',
  'libtailcat-android-x64.so':
      '1e7dca5805faa95fa63a0cb404a10912c54f4aff4852a851c2aea1aeb5ba17de',
  'libtailcat-android-arm.so':
      '968b524a4ab476594517b248edf01f1e78415fd6cf3db453a1c729d531178e4e',
};

/// The prebuilt artifacts of one native release.
final class NativeManifest {
  /// Creates a manifest.
  const NativeManifest({
    required this.releaseTag,
    required this.baseUrl,
    required this.artifacts,
  });

  /// The release this package version pins.
  static const pinned = NativeManifest(
    releaseTag: nativeReleaseTag,
    baseUrl: nativeReleaseBaseUrl,
    artifacts: nativeArtifacts,
  );

  /// Release tag holding the libraries; empty when none is pinned.
  final String releaseTag;

  /// URL the release tags hang under.
  final String baseUrl;

  /// SHA-256 (hex) by artifact file name.
  final Map<String, String> artifacts;

  /// The pinned SHA-256 of [artifactFileName], or `null`.
  String? sha256Of(String artifactFileName) => artifacts[artifactFileName];

  /// Download URL of [artifactFileName], or `null`.
  Uri? urlOf(String artifactFileName) => artifacts.containsKey(artifactFileName)
      ? Uri.parse('$baseUrl/$releaseTag/$artifactFileName')
      : null;
}
