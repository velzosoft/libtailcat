// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

@Tags(['network'])
library;

import 'dart:convert';

import 'package:libtailcat/libtailcat.dart';
import 'package:test/test.dart';

import '../support/native.dart';

// The public relays are rate limited, so this runs only when asked for:
// `dart test --run-skipped -t network`.
void main() {
  test('a server and a client meet over the public relays', () async {
    final server = await TailcatServer.start(
      const TailcatServerConfig(),
      timeout: const Duration(minutes: 1),
    );
    addTearDown(() => server.close(drain: false));
    final info = server.address.parse();
    printOnFailure('address: $info');
    expect(info.isSelfContained || info.regionId > 0, isTrue);

    // Resolving embeds the region, saving the client the lookup.
    final resolved = await server.address.resolve();
    expect(resolved.parse().isSelfContained, isTrue);
    expect(resolved.parse().publicKey, server.publicKey);

    final listener = await server.listen(port: 1);
    final accepting = listener.first;
    final client = TailcatClient(TailcatClientConfig(address: server.address));
    addTearDown(() => client.close(drain: false));

    final socket = await client.connect(
      port: 1,
      timeout: const Duration(minutes: 1),
    );
    socket.write('over the public relay');
    await socket.close();
    final accepted = await accepting;
    expect(await utf8.decodeStream(accepted), 'over the public relay');
    await accepted.close();
    await socket.drain<void>();

    expect(await client.ping(), greaterThanOrEqualTo(Duration.zero));
    final path = await client.discoPing();
    printOnFailure('path: $path');
    expect(path.isDirect || path.derpRegionId > 0, isTrue);
  }, skip: nativeUnavailable);
}
