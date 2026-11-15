// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

@Tags(['interop'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libtailcat/libtailcat.dart';
import 'package:test/test.dart';

import '../support/native.dart';

// Upstream's `tailcat` CLI pipes stdin/stdout over TCP port 1.
void main() {
  group('the tailcat command-line tool', () {
    late TestRelay relay;
    late File cli;
    late HttpServer derpMap;
    late Directory home;

    setUpAll(() async {
      relay = await TestRelay.start();
      cli = await buildTailcatCli();
      home = await Directory.systemTemp.createTemp('libtailcat-interop');
      // The tool reads relays from a map; serve one with only the local relay.
      derpMap = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      derpMap.listen((request) {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'Regions': {'1': relay.region},
            }),
          )
          ..close();
      });
    });

    tearDownAll(() async {
      await derpMap.close(force: true);
      await relay.stop();
      await home.delete(recursive: true);
    });

    String derpMapUrl() => 'http://127.0.0.1:${derpMap.port}/derpmap.json';

    // A fresh key and own home, so the developer's saved keys stay untouched.
    Future<Process> tailcat(List<String> arguments) => Process.start(
      cli.path,
      ['--key', 'new', '--derpmap-url', derpMapUrl(), ...arguments],
      environment: {'HOME': home.path, 'XDG_CONFIG_HOME': home.path},
    );

    test('a Dart client sends to the tool listening', () async {
      final server = await tailcat(const []);
      addTearDown(server.kill);
      final address = await server.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map(RegExp(r'Server listening with new address: (\S+)').firstMatch)
          .firstWhere((match) => match != null)
          .timeout(const Duration(seconds: 60));
      final output = utf8.decodeStream(server.stdout);

      // The tool's address names its relay by region id only.
      final resolved = await TailcatAddress(
        address!.group(1)!,
      ).resolve(derpMapUrl: derpMapUrl());
      expect(resolved.parse().isSelfContained, isTrue);
      final client = TailcatClient(
        TailcatClientConfig(address: resolved, derpMapUrl: 'none'),
      );
      addTearDown(() => client.close(drain: false));

      final socket = await client.connect(port: 1);
      socket.writeln('hello from dart');
      await socket.close();
      // The tool closes after our half-close, ending our stream.
      await socket.drain<void>();
      await client.close();

      expect(await output, 'hello from dart\n');
      expect(await server.exitCode, 0);
    });

    test('the tool connects to a Dart server', () async {
      final server = await TailcatServer.start(
        TailcatServerConfig(region: relay.region),
      );
      addTearDown(() => server.close(drain: false));
      final listener = await server.listen(port: 1);
      final accepting = listener.first;

      final client = await tailcat([server.address.reveal()]);
      addTearDown(client.kill);
      final errors = client.stderr.transform(utf8.decoder).join();
      final output = utf8.decodeStream(client.stdout);
      client.stdin.writeln('hello from the tool');
      await client.stdin.close();

      final socket = await accepting.timeout(const Duration(seconds: 60));
      expect(await utf8.decodeStream(socket), 'hello from the tool\n');
      socket.writeln('hello from dart');
      await socket.close();

      expect(await output, 'hello from dart\n');
      expect(await client.exitCode, 0, reason: await errors);
    });
  }, skip: hermeticUnavailable);
}
