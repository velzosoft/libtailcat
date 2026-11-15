// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

@Tags(['native'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:libtailcat/libtailcat.dart';
import 'package:test/test.dart';

import '../support/native.dart';

void main() {
  group('UDP over a tunnel', () {
    late Tunnel tunnel;
    late TailcatDatagramListener listener;
    late StreamQueue<TailcatDatagramSocket> flows;

    setUpAll(() async {
      tunnel = await Tunnel.open();
      listener = await tunnel.server.listenUdp();
      flows = StreamQueue(listener);
    });

    // The server only learns of a flow from its first datagram, [hello].
    Future<(TailcatDatagramSocket, StreamQueue<Uint8List>)> connect(
      String hello,
    ) async {
      final flow = await tunnel.client.connectUdp(port: listener.port);
      addTearDown(flow.close);
      await flow.send(utf8.encode(hello));
      final serverFlow = await flows.next;
      addTearDown(serverFlow.close);
      _serverFlows[flow] = serverFlow;
      return (flow, StreamQueue(serverFlow));
    }

    group('a UDP flow', () {
      test('carries datagrams both ways, one per event', () async {
        final (flow, received) = await connect('hello');
        final replies = StreamQueue(flow);
        expect(utf8.decode(await received.next), 'hello');

        await flow.send(utf8.encode('one'));
        await flow.send(utf8.encode('two'));
        expect(utf8.decode(await received.next), 'one');
        expect(utf8.decode(await received.next), 'two');

        final serverFlow = _serverFlows[flow]!;
        await serverFlow.send(utf8.encode('world'));
        expect(utf8.decode(await replies.next), 'world');
        expect(serverFlow.remotePort, flow.port);
        expect(flow.remotePort, listener.port);
      });

      test('delivers an empty datagram as an empty event', () async {
        final (flow, received) = await connect('first');
        expect(utf8.decode(await received.next), 'first');
        await flow.send(const []);
        await flow.send(utf8.encode('after'));
        expect(await received.next, isEmpty);
        expect(utf8.decode(await received.next), 'after');
      });

      test('takes the largest payload and rejects one byte more', () async {
        final (flow, received) = await connect('first');
        expect(utf8.decode(await received.next), 'first');

        expect(TailcatDatagramSocket.maxPayloadSize, 1232);
        final largest = Uint8List(1232)..fillRange(0, 1232, 0x5a);
        await flow.send(largest);
        expect(await received.next, largest);

        await expectLater(
          flow.send(Uint8List(1233)),
          throwsA(isA<TailcatArgumentException>()),
        );
        await flow.send(utf8.encode('still open'));
        expect(utf8.decode(await received.next), 'still open');
      });

      test('keeps flows apart', () async {
        final (first, firstReceived) = await connect('from first');
        final (second, secondReceived) = await connect('from second');
        expect(first.port, isNot(second.port));
        expect(utf8.decode(await firstReceived.next), 'from first');
        expect(utf8.decode(await secondReceived.next), 'from second');
      });

      test('fails sends once it is closed', () async {
        final (flow, _) = await connect('first');
        final ended = flow.drain<void>();
        await flow.close();
        await ended;
        expect(flow.isClosed, isTrue);
        await expectLater(
          flow.send(utf8.encode('late')),
          throwsA(isA<TailcatClosedException>()),
        );
      });
    });
  }, skip: hermeticUnavailable);
}

final _serverFlows = Expando<TailcatDatagramSocket>();
