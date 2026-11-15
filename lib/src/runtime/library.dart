// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import '../bindings/native_api.dart' as native;
import 'errors.dart';

/// The C ABI version the bindings in this package were generated for.
const int supportedAbiVersion = 1;

bool _verified = false;

/// Verifies once per isolate that the native library is bundled and speaks
/// [supportedAbiVersion]; throws [TailcatFailureException] otherwise.
void ensureNativeLibrary() {
  if (_verified) return;
  final int version;
  try {
    version = native.abiVersion();
  } on ArgumentError {
    // The build hook bundled no library for this platform.
    throw const TailcatFailureException(
      'the libtailcat native library is not bundled with this application; '
      'see "Build configuration" in the README of package:libtailcat',
    );
  }
  if (version != supportedAbiVersion) {
    throw TailcatFailureException(
      'the bundled libtailcat speaks ABI version $version, but this package '
      'needs version $supportedAbiVersion',
    );
  }
  _verified = true;
}
