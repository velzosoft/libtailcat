// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Dart bindings for [Tailcat](https://github.com/tailscale/tailcat):
/// encrypted point-to-point TCP and UDP tunnels over Tailscale's relays, with
/// no account.
///
/// A [TailcatServer] has a [TailcatAddress]; a [TailcatClient] given that
/// address connects to it and gets `dart:io` sockets back.
///
/// Every failure is a [TailcatException]. Addresses and keys are
/// [TailcatSecret]s and never print their value.
library;

export 'src/address.dart';
export 'src/client.dart';
export 'src/config.dart' show TailcatClientConfig, TailcatServerConfig;
export 'src/info.dart' show Tailcat, TailcatBuildInfo, TailcatPath;
export 'src/io/datagram.dart';
export 'src/io/server_socket.dart';
export 'src/io/socket.dart';
export 'src/keys.dart';
export 'src/runtime/errors.dart' hide exceptionForStatus;
export 'src/secret.dart';
export 'src/server.dart';
