// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Pinned prebuilt native artifacts, rewritten by `tool/update_manifest.dart`.
library;

/// `native-<commit>-<n>`; empty until a native release is pinned.
const nativeReleaseTag = '';

/// Base URL of GitHub release downloads.
const nativeReleaseBaseUrl =
    'https://github.com/velzosoft/libtailcat/releases/download';

/// SHA-256 (hex) by `NativeTarget.artifactFileName`. Generated; don't edit.
const nativeArtifacts = <String, String>{};

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
