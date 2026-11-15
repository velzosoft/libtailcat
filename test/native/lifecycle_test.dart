// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

// Sockets are closed through their owners, which is what's under test.
// ignore_for_file: close_sinks

@Tags(['native'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:libtailcat/libtailcat.dart';
import 'package:test/test.dart';

import '../support/native.dart';

void main() {
  group('lifecycle', () {
    late TestRelay relay;

    setUpAll(() async => relay = await TestRelay.start());
    tearDownAll(() => relay.stop());

    group('closing a client', () {
      test('ends its sockets and makes further use fail', () async {
        final tunnel = await Tunnel.open(relay: relay);
        final listener = await tunnel.server.listen();
        final accepted = StreamQueue(listener);
        final socket = await tunnel.client.connect(port: listener.port);
        final other = await accepted.next;
        final flow = await tunnel.client.connectUdp(port: listener.port);

        // Both blocked in a read when the client closes.
        final socketEnded = socket.drain<void>();
        final flowEnded = flow.drain<void>();
        await tunnel.client.close(drain: false);
        await socketEnded;
        await flowEnded;

        expect(tunnel.client.isClosed, isTrue);
        expect(flow.isClosed, isTrue);
        await expectLater(
          tunnel.client.connect(port: listener.port),
          throwsA(isA<TailcatClosedException>()),
        );
        await expectLater(
          tunnel.client.ping(),
          throwsA(isA<TailcatClosedException>()),
        );
        // Closing again, in any order, is harmless.
        await tunnel.client.close();
        socket.destroy();
        await flow.close();
        other.destroy();
      });

      test('with a drain delivers what was written just before', () async {
        final tunnel = await Tunnel.open(relay: relay);
        final listener = await tunnel.server.listen();
        final accepting = listener.first;
        final socket = await tunnel.client.connect(port: listener.port);
        final received = utf8.decodeStream(await accepting);

        socket.write('last words');
        await socket.flush();
        await tunnel.client.close();
        expect(await received, 'last words');
      });
    });

    group('closing a server', () {
      test('ends its listeners and accepted sockets', () async {
        final tunnel = await Tunnel.open(relay: relay);
        final listener = await tunnel.server.listen();
        final udp = await tunnel.server.listenUdp();
        final accepted = StreamQueue(listener);
        final dialed = await tunnel.client.connect(port: listener.port);
        addTearDown(dialed.destroy);
        final other = await accepted.next;

        // An accept and a read blocked when the server closes.
        final listenerEnded = accepted.hasNext;
        final udpEnded = udp.isEmpty;
        final socketEnded = other.drain<void>();
        await tunnel.server.close(drain: false);

        expect(await listenerEnded, isFalse);
        expect(await udpEnded, isTrue);
        await socketEnded;
        expect(tunnel.server.isClosed, isTrue);
        await expectLater(
          tunnel.server.listen(),
          throwsA(isA<TailcatClosedException>()),
        );
        await expectLater(
          tunnel.server.allowClient(tunnel.client.publicKey),
          throwsA(isA<TailcatClosedException>()),
        );
        await tunnel.server.close();
      });
    });

    group('a blocked wait', () {
      test('on read ends when the subscription is cancelled, and the socket '
          'can still write', () async {
        final tunnel = await Tunnel.open(relay: relay);
        final listener = await tunnel.server.listen();
        final accepting = listener.first;
        final socket = await tunnel.client.connect(port: listener.port);
        addTearDown(socket.destroy);
        final other = await accepting;
        addTearDown(other.destroy);

        final subscription = socket.listen((_) {});
        // Let the reader get into its native call.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final watch = Stopwatch()..start();
        await subscription.cancel();
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));

        socket.write('after cancel');
        await socket.close();
        expect(await utf8.decodeStream(other), 'after cancel');
      });

      test('on accept ends when the listener is closed', () async {
        final tunnel = await Tunnel.open(relay: relay);
        final listener = await tunnel.server.listen();
        final ended = listener.isEmpty;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final watch = Stopwatch()..start();
        await listener.close();
        expect(await ended, isTrue);
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      });

      test('survives several slices and still delivers', () async {
        final tunnel = await Tunnel.open(relay: relay);
        final listener = await tunnel.server.listen();
        final accepted = StreamQueue(listener);
        // Block an accept, then a read, well past one slice each.
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        final socket = await tunnel.client.connect(port: listener.port);
        addTearDown(socket.destroy);
        final other = await accepted.next;
        addTearDown(other.destroy);
        final received = StreamQueue(
          other.cast<List<int>>().transform(utf8.decoder),
        );
        final first = received.next;
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        socket.write('late');
        await socket.flush();
        expect(await first, 'late');
      });
    });

    group('a timeout', () {
      test('ends a connect to a server that is gone', () async {
        final tunnel = await Tunnel.open(relay: relay);
        final gone = await TailcatServer.start(
          TailcatServerConfig(region: relay.region),
        );
        final address = gone.address;
        await gone.close(drain: false);
        final client = Tunnel.newClient(address);
        addTearDown(() => client.close(drain: false));

        const timeout = Duration(milliseconds: 800);
        final watch = Stopwatch()..start();
        await expectLater(
          client.connect(port: 1, timeout: timeout),
          throwsA(
            isA<TailcatTimeoutException>()
                .having((e) => e.duration, 'duration', timeout)
                .having(
                  (e) => e,
                  'as TimeoutException',
                  isA<TimeoutException>(),
                ),
          ),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        // The other tunnel is unaffected.
        expect(await tunnel.client.ping(), isA<Duration>());
      });

      test(
        'ends a connect that is cancelled through its ConnectionTask',
        () async {
          final gone = await TailcatServer.start(
            TailcatServerConfig(region: relay.region),
          );
          final address = gone.address;
          await gone.close(drain: false);
          final client = Tunnel.newClient(address);
          addTearDown(() => client.close(drain: false));

          final task = await client.connectionFactory(
            Uri.parse('http://tailcat:8080/'),
            null,
            null,
          );
          final failure = expectLater(
            task.socket,
            throwsA(isA<TailcatCancelledException>()),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          task.cancel();
          await failure;
        },
      );
    });

    group('identity', () {
      test(
        'a client configured with a private key has its public key',
        () async {
          final tunnel = await Tunnel.open(relay: relay);
          final keys = TailcatKeys.generate();
          final client = Tunnel.newClient(
            tunnel.server.address,
            privateKey: keys.privateKey,
          );
          addTearDown(() => client.close(drain: false));
          expect(client.publicKey, keys.publicKey);
          expect(tunnel.client.publicKey, isNot(keys.publicKey));
        },
      );

      test('a server restarted with its keys keeps its address', () async {
        final keys = TailcatKeys.generate();
        TailcatServerConfig config() => TailcatServerConfig(
          region: relay.region,
          privateKey: keys.privateKey,
          presharedKey: keys.presharedKey,
        );
        final first = await TailcatServer.start(config());
        final address = first.address;
        expect(first.publicKey, keys.publicKey);
        await first.close(drain: false);

        final second = await TailcatServer.start(config());
        addTearDown(() => second.close(drain: false));
        expect(second.address, address);
        expect(second.address.parse().publicKey, keys.publicKey);
      });

      test('an allowlist admits only the listed clients', () async {
        final allowed = TailcatKeys.generate();
        final tunnel = await Tunnel.open(
          relay: relay,
          server: (region) => TailcatServerConfig(
            region: region,
            allowedClients: [allowed.publicKey],
          ),
          clientKey: allowed.privateKey,
        );
        final listener = await tunnel.server.listen();
        final accepted = StreamQueue(listener);

        final socket = await tunnel.client.connect(port: listener.port);
        addTearDown(socket.destroy);
        (await accepted.next).destroy();

        final stranger = TailcatKeys.generate();
        final strangerClient = Tunnel.newClient(
          tunnel.server.address,
          privateKey: stranger.privateKey,
        );
        addTearDown(() => strangerClient.close(drain: false));
        await expectLater(
          strangerClient.connect(
            port: listener.port,
            timeout: const Duration(seconds: 2),
          ),
          throwsA(isA<TailcatException>()),
        );

        await tunnel.server.allowClient(stranger.publicKey);
        final late = await strangerClient.connect(port: listener.port);
        addTearDown(late.destroy);
        (await accepted.next).destroy();

        await expectLater(
          tunnel.server.allowClient('not a key'),
          throwsA(isA<TailcatArgumentException>()),
        );
      });
    });

    group('diagnostics', () {
      test('ping and discoPing describe the path', () async {
        final tunnel = await Tunnel.open(relay: relay);
        expect(await tunnel.client.ping(), greaterThanOrEqualTo(Duration.zero));
        final path = await tunnel.client.discoPing();
        expect(path.latency, greaterThanOrEqualTo(Duration.zero));
        if (path.isDirect) {
          expect(path.endpoint, contains(':'));
        } else {
          expect(path.derpRegionCode, 'test');
          expect(path.derpRegionId, 1);
        }
      });

      test('the address describes the relay it embeds', () async {
        final tunnel = await Tunnel.open(relay: relay);
        final info = tunnel.server.address.parse();
        expect(info.publicKey, tunnel.server.publicKey);
        expect(info.hasPresharedKey, isTrue);
        expect(info.isSelfContained, isTrue);
        expect(info.regions.single['RegionID'], 1);
        // Self-contained, so resolving needs no lookup.
        final resolved = await tunnel.server.address.resolve(
          derpMapUrl: 'none',
        );
        expect(resolved.parse().publicKey, info.publicKey);
        expect('${tunnel.server.address}', 'TailcatAddress(<redacted>)');
      });

      test('drain returns once the closed sockets are flushed', () async {
        final tunnel = await Tunnel.open(relay: relay);
        // A no-op before any traffic.
        await tunnel.client.drain();
        final listener = await tunnel.server.listen();
        final accepting = listener.first;
        final socket = await tunnel.client.connect(port: listener.port);
        final Socket other = await accepting;
        socket.write('bye');
        await socket.close();
        expect(await utf8.decodeStream(other), 'bye');
        await other.close();
        await socket.drain<void>();
        await tunnel.client.drain();
        await tunnel.server.drain();
      });
    });
  }, skip: hermeticUnavailable);
}
