// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Runs libtailcat inside a real app sandbox, which breaks native networking
/// in ways `dart test` can't show, and logs a `LIBTAILCAT_SMOKE: PASS|FAIL`
/// line for `tool/smoke_test.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:libtailcat/libtailcat.dart';

const _marker = 'LIBTAILCAT_SMOKE';
const _regionJson = String.fromEnvironment('SMOKE_REGION');
const _stepTimeout = Duration(seconds: 60);

void main() => runApp(const SmokeApp());

/// The log line is what counts; the UI is just progress.
class SmokeApp extends StatefulWidget {
  const SmokeApp({super.key});

  @override
  State<SmokeApp> createState() => _SmokeAppState();
}

class _SmokeAppState extends State<SmokeApp> {
  final List<String> _lines = [];

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _report(String line) {
    print('$_marker: $line');
    if (mounted) setState(() => _lines.add(line));
  }

  Future<void> _run() async {
    final watch = Stopwatch()..start();
    try {
      final path = await SmokeTest(_report).run();
      _report('PASS in ${watch.elapsedMilliseconds} ms, path $path');
    } catch (error, stackTrace) {
      _report('FAIL $error');
      print(stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xFF101418),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final line in _lines)
              Text(
                line,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: line.startsWith('FAIL')
                      ? const Color(0xFFFF6B6B)
                      : line.startsWith('PASS')
                      ? const Color(0xFF6BD68A)
                      : const Color(0xFFD7DEE5),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// A server and a client in one process, talking through a relay.
class SmokeTest {
  SmokeTest(this.report);

  final void Function(String line) report;

  /// Returns the client's path; throws on the first failure.
  Future<String> run() async {
    await _step('library', () async {
      final info = Tailcat.buildInfo;
      _expect(Tailcat.abiVersion == 1, 'ABI ${Tailcat.abiVersion}');
      return '${info.goVersion}, ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}';
    });

    final keys = await _step('keys', () async => TailcatKeys.generate());

    // DNS, TLS and network probes: what app sandboxes break.
    final server = await _step(
      'server start',
      () => TailcatServer.start(
        TailcatServerConfig(
          privateKey: keys.privateKey,
          presharedKey: keys.presharedKey,
          region: _regionJson.isEmpty
              ? null
              : jsonDecode(_regionJson) as Map<String, Object?>,
        ),
      ),
    );
    _expect(server.publicKey == keys.publicKey, 'the server uses its key');
    final client = TailcatClient(TailcatClientConfig(address: server.address));

    await _step('tcp', () async {
      final listener = await server.listen();
      final accepting = listener.first;
      final dialed = await client.connect(port: listener.port);
      final accepted = await accepting;
      dialed.write('ping');
      await dialed.close();
      _expect(await utf8.decodeStream(accepted) == 'ping', 'server read');
      accepted.write('pong');
      await accepted.close();
      _expect(await utf8.decodeStream(dialed) == 'pong', 'client read');
      return 'port ${listener.port}';
    });

    await _step('udp', () async {
      final listener = await server.listenUdp();
      final accepting = listener.first;
      final flow = await client.connectUdp(port: listener.port);
      await flow.send(utf8.encode('ping'));
      final serverFlow = await accepting;
      _expect(utf8.decode(await serverFlow.first) == 'ping', 'server read');
      await flow.close();
    });

    await _step('cancel a blocked read', () async {
      final listener = await server.listen();
      final accepting = listener.first;
      final dialed = await client.connect(port: listener.port);
      final accepted = await accepting;
      final subscription = dialed.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final watch = Stopwatch()..start();
      await subscription.cancel();
      _expect(watch.elapsedMilliseconds < 1000, 'cancel took ${watch.elapsed}');
      dialed.destroy();
      accepted.destroy();
    });

    // Informational: a direct path depends on the network's NAT.
    final path = await _step('path', () async {
      var path = await client.discoPing();
      for (var i = 0; i < 10 && !path.isDirect; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        path = await client.discoPing();
      }
      return path.isDirect
          ? 'direct, ${path.latency.inMilliseconds} ms'
          : 'relayed via ${path.derpRegionCode}, '
                '${path.latency.inMilliseconds} ms';
    });

    await _step('close', () async {
      await client.close();
      await server.close(drain: false);
      _expect(client.isClosed && server.isClosed, 'both closed');
    });

    await _step('hold for hot restart', _hold);
    return path;
  }

  /// Leaves an acceptor and a reader blocked in native calls for a hot
  /// restart to get past.
  Future<void> _hold() async {
    final server = await TailcatServer.start(
      TailcatServerConfig(
        region: _regionJson.isEmpty
            ? null
            : jsonDecode(_regionJson) as Map<String, Object?>,
      ),
    );
    final listener = await server.listen();
    listener.listen((socket) => socket.listen((_) {}));
    final client = TailcatClient(TailcatClientConfig(address: server.address));
    (await client.connect(port: listener.port)).listen((_) {});
  }

  Future<T> _step<T>(String name, Future<T> Function() body) async {
    final watch = Stopwatch()..start();
    final T result;
    try {
      result = await body().timeout(_stepTimeout);
    } catch (error) {
      throw StateError('$name: $error');
    }
    final detail = result is String ? ': $result' : '';
    report('$name ok (${watch.elapsedMilliseconds} ms)$detail');
    return result;
  }

  void _expect(bool condition, String what) {
    if (!condition) throw StateError('unexpected: $what');
  }
}
