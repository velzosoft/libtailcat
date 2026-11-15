// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Run by `shutdown_test.dart`: exits with helpers blocked in native calls,
/// like a Flutter hot restart. The VM must still shut down.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:libtailcat/libtailcat.dart';

Future<void> main(List<String> arguments) async {
  final region = jsonDecode(arguments.single) as Map<String, Object?>;
  final server = await TailcatServer.start(TailcatServerConfig(region: region));
  final listener = await server.listen();
  final client = TailcatClient(
    TailcatClientConfig(address: server.address, derpMapUrl: 'none'),
  );
  // ignore: close_sinks, abandoned on purpose
  final dialed = await client.connect(port: listener.port);
  listener.listen((accepted) => accepted.listen((_) {}));
  dialed.listen((_) {});
  // Long enough for the helpers to be inside their native calls.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  stdout.writeln('ready');
  await stdout.flush();
  Isolate.exit();
}
