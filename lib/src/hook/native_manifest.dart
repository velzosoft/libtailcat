// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Pinned prebuilt native artifacts, rewritten by `tool/update_manifest.dart`.
library;

/// `native-<commit>-<n>`; empty until a native release is pinned.
const nativeReleaseTag = 'native-b9491c13c639-1';

/// Base URL of GitHub release downloads.
const nativeReleaseBaseUrl =
    'https://github.com/velzosoft/libtailcat/releases/download';

/// SHA-256 (hex) by `NativeTarget.artifactFileName`. Generated; don't edit.
const nativeArtifacts = <String, String>{
  'libtailcat-macos-arm64.dylib':
      '20e56de26086b381b8a37eabcd4e582013c10fdec75c408fab880be7e32a9b48',
  'libtailcat-macos-x64.dylib':
      '21b4910fcde247191eaa024b3f6d9d4e2d671dc9fea919f3cab14e8a150a7a7b',
  'libtailcat-ios-arm64-iphoneos.dylib':
      'a11b0d6ff5c2e0c31728cc7429e3729c7dd5acf4610cd25f9d4879b3592f6495',
  'libtailcat-ios-arm64-iphonesimulator.dylib':
      '661d93a3c04093a62d5b50341774f90e828722b0a0d123d5a5610f4979666eeb',
  'libtailcat-ios-x64-iphonesimulator.dylib':
      '1673d447a652e2f3c393db243105753c88fb5e15a54616f8b57ae797b7370279',
  'libtailcat-linux-x64.so':
      'cb246c11f2de63326024faa380cc28a0ba2beb96feb53b5e10788bf82d248806',
  'libtailcat-linux-arm64.so':
      '6d4f3c56eff80c0255eb1dd1fdd5364899d5b441ea071afbdda78c696d2807c4',
  'libtailcat-windows-x64.dll':
      '121339cc5702403fb17d58bd6e613511a64ea94bc16543d342e6fe273d946d41',
  'libtailcat-android-arm64.so':
      'ee93dd5c2f0c011fb55eab819deb8ce81c0be9e0b762307393e9ecf48bba74ec',
  'libtailcat-android-x64.so':
      '6517193426e98e78b5d0f976ade9d321e37b0aacda744113ceedcf4d5d1131fb',
  'libtailcat-android-arm.so':
      'd65c01b09ef2a675d48f0ce036812816c5e44c5c3e23fbc6671585d7db6709fe',
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
