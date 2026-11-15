// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import 'package:libtailcat/libtailcat.dart';
import 'package:test/test.dart';

import '../../tool/src/go_tools.dart';

/// A `skip:` reason when the native library is missing, else `null`.
final String? nativeUnavailable = () {
  try {
    Tailcat.abiVersion;
    return null;
  } on TailcatFailureException {
    return 'no native library; put {"native": "source"} in '
        'hook/local_config.json (see CONTRIBUTING.md)';
  }
}();

/// A `skip:` reason when the native library or Go (for the relay) is missing.
final String? hermeticUnavailable =
    nativeUnavailable ??
    (GoTools.isGoInstalled ? null : 'Go is needed to build the test relay');

final _tools = GoTools(log: (_) {});

/// A DERP relay and STUN server on 127.0.0.1, so no test touches the public
/// relays.
final class TestRelay {
  TestRelay._(this._process, this.region);

  final Process _process;

  /// A `DERPRegion`, for `TailcatServerConfig.region`.
  final Map<String, Object?> region;

  static Future<TestRelay> start() async {
    final binary = await _tools.testRelay();
    final process = await Process.start(binary.path, const []);
    final line = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    final region = (jsonDecode(line) as Map<String, Object?>)['region'];
    return TestRelay._(process, region! as Map<String, Object?>);
  }

  Future<void> stop() async {
    await _process.stdin.close();
    await _process.exitCode;
  }
}

Future<File> buildTailcatCli() => _tools.cli();

/// A server on a local relay and a client that reaches it.
final class Tunnel {
  Tunnel._(this.relay, this.server, this.client);

  final TestRelay relay;
  final TailcatServer server;
  final TailcatClient client;

  /// Starts a relay unless [relay] is given. With [register], tears down
  /// when the current test or group ends.
  static Future<Tunnel> open({
    TestRelay? relay,
    TailcatServerConfig Function(Map<String, Object?> region)? server,
    TailcatPrivateKey? clientKey,
    bool register = true,
  }) async {
    final ownRelay = relay == null;
    relay ??= await TestRelay.start();
    final config =
        server?.call(relay.region) ?? TailcatServerConfig(region: relay.region);
    final started = await TailcatServer.start(config);
    final tunnel = Tunnel._(
      relay,
      started,
      newClient(started.address, privateKey: clientKey),
    );
    if (register) {
      addTearDown(() => tunnel.close(stopRelay: ownRelay));
    }
    return tunnel;
  }

  /// Skips the relay-map lookup: the address embeds the test relay.
  static TailcatClient newClient(
    TailcatAddress address, {
    TailcatPrivateKey? privateKey,
  }) => TailcatClient(
    TailcatClientConfig(
      address: address,
      privateKey: privateKey,
      derpMapUrl: 'none',
    ),
  );

  Future<void> close({bool stopRelay = true}) async {
    await client.close(drain: false);
    await server.close(drain: false);
    if (stopRelay) await relay.stop();
  }
}
