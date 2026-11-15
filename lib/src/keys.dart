// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'bindings/native_api.dart' as native;
import 'json.dart';
import 'runtime/library.dart';
import 'secret.dart';

/// The private node key of a client or server. Persist it to keep a stable
/// identity across restarts.
final class TailcatPrivateKey extends TailcatSecret {
  /// Wraps a private key in its text encoding.
  const TailcatPrivateKey(String value) : super(value, 'TailcatPrivateKey');
}

/// The WireGuard pre-shared key that is part of a server's address.
final class TailcatPresharedKey extends TailcatSecret {
  /// Wraps a pre-shared key in its text encoding.
  const TailcatPresharedKey(String value) : super(value, 'TailcatPresharedKey');
}

/// A node identity. A server reusing [privateKey] and [presharedKey] keeps
/// its address; a client reusing [privateKey] keeps its [publicKey].
final class TailcatKeys {
  /// Combines existing keys.
  const TailcatKeys({
    required this.privateKey,
    required this.publicKey,
    required this.presharedKey,
  });

  /// Generates a fresh identity, without network access.
  factory TailcatKeys.generate() {
    ensureNativeLibrary();
    final json = JsonObject.decode(
      native.generateKeys(),
      what: 'key generation',
    );
    return TailcatKeys(
      privateKey: TailcatPrivateKey(json.string('private_key')),
      publicKey: json.string('public_key'),
      presharedKey: TailcatPresharedKey(json.string('preshared_key')),
    );
  }

  /// The private node key. Secret.
  final TailcatPrivateKey privateKey;

  /// The public node key, as held by a server's allowlist. Not secret.
  final String publicKey;

  /// A random pre-shared key. Secret.
  final TailcatPresharedKey presharedKey;

  @override
  String toString() => 'TailcatKeys(publicKey: $publicKey)';
}
