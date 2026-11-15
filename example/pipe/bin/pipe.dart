// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// A two-way pipe between two machines.
///
/// Listen with `dart run bin/pipe.dart`, then on the other machine run
/// `dart run bin/pipe.dart <address>` (or `tailcat <address>`). Ctrl-D ends.
library;

import 'dart:io';

import 'package:libtailcat/libtailcat.dart';

/// The port the `tailcat` CLI uses for its pipe.
const pipePort = 1;

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.isEmpty) {
      await listen();
    } else {
      await connect(TailcatAddress(arguments.single));
    }
  } on TailcatException catch (e) {
    // Sealed hierarchy: branch on the type, never the text.
    stderr.writeln(switch (e) {
      TailcatTimeoutException() => 'Timed out. Is the other side running?',
      TailcatArgumentException() => 'That is not a Tailcat address.',
      _ => 'Failed: ${e.message}',
    });
    exitCode = 1;
  }
}

Future<void> listen() async {
  // Fresh identity, nearest public relay.
  final server = await TailcatServer.start(const TailcatServerConfig());
  final listener = await server.listen(port: pipePort);

  // The address is a secret; '$address' would print "<redacted>".
  stderr.writeln('Listening. On the other machine, run:');
  stderr.writeln('  dart run bin/pipe.dart ${server.address.reveal()}');

  final socket = await listener.first;
  stderr.writeln('Connected to ${socket.remoteAddress.address}.');
  await pipe(socket);

  // Drains first, so the last bytes reach the peer.
  await server.close();
}

Future<void> connect(TailcatAddress address) async {
  final client = TailcatClient(TailcatClientConfig(address: address));
  final socket = await client.connect(
    port: pipePort,
    timeout: const Duration(seconds: 30),
  );

  // Starts on a relay; moves to a direct path once NAT traversal succeeds.
  final path = await client.discoPing();
  stderr.writeln(
    path.isDirect
        ? 'Connected directly (${path.latency.inMilliseconds} ms).'
        : 'Connected through relay ${path.derpRegionCode} '
              '(${path.latency.inMilliseconds} ms).',
  );
  await pipe(socket);
  await client.close();
}

Future<void> pipe(Socket socket) async {
  final sending = socket.addStream(stdin).then((_) => socket.close());
  await stdout.addStream(socket);
  // The peer is done sending; stop reading the terminal.
  socket.destroy();
  await sending.catchError((Object _) => null);
}
