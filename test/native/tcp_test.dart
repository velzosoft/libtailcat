// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

@Tags(['native'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:libtailcat/libtailcat.dart';
import 'package:test/test.dart';

import '../support/native.dart';

void main() {
  group('TCP over a tunnel', () {
    late Tunnel tunnel;
    late TailcatServerSocket listener;
    late StreamQueue<Socket> accepted;

    setUpAll(() async {
      tunnel = await Tunnel.open();
      listener = await tunnel.server.listen();
      accepted = StreamQueue(listener);
    });

    /// The client's end and the server's.
    Future<(TailcatSocket, Socket)> connect() async {
      final dialed = await tunnel.client.connect(port: listener.port);
      final other = await accepted.next;
      addTearDown(dialed.destroy);
      addTearDown(other.destroy);
      return (dialed, other);
    }

    group('a TCP connection', () {
      test('round-trips with a half-close on each side', () async {
        final (dialed, other) = await connect();

        dialed.write('ping');
        await dialed.close();
        // Ends the peer's stream, not our read side.
        expect(await utf8.decodeStream(other), 'ping');

        other.write('pong');
        await other.close();
        expect(await utf8.decodeStream(dialed), 'pong');
        await dialed.done;
      });

      test('reports both ends', () async {
        final (dialed, other) = await connect();
        expect(other, isA<TailcatSocket>());
        expect(dialed.remotePort, listener.port);
        expect(dialed.remoteAddress, tunnel.server.localAddress);
        expect(dialed.remoteAddress, listener.address);
        expect(other.port, listener.port);
        expect(other.remotePort, dialed.port);
        expect(other.remoteAddress, dialed.address);
        expect('$dialed', contains(':${listener.port}'));
      });

      test('carries a large transfer intact in both directions', () async {
        final (dialed, other) = await connect();
        final payload = _pattern(6 * 1024 * 1024 + 123);

        Future<Uint8List> echoThrough(Socket from, Socket to) async {
          final received = _collect(to);
          from.add(payload);
          await from.close();
          return received;
        }

        expect(await echoThrough(dialed, other), payload);
        expect(await echoThrough(other, dialed), payload);
      });

      test('pipes a stream with addStream', () async {
        final (dialed, other) = await connect();
        final chunks = [for (var i = 0; i < 50; i++) utf8.encode('line $i\n')];
        await dialed.addStream(Stream.fromIterable(chunks));
        dialed.writeln('done');
        await dialed.flush();
        await dialed.close();
        final lines = const LineSplitter().convert(
          await utf8.decodeStream(other),
        );
        expect(lines, [for (var i = 0; i < 50; i++) 'line $i', 'done']);
      });

      test('destroy ends the local stream and the peer sees the end', () async {
        final (dialed, other) = await connect();
        final localDone = dialed.drain<void>();
        final remoteDone = other
            .drain<void>()
            .then((_) => 'closed')
            .catchError((Object _) => 'reset');
        dialed.destroy();
        await localDone;
        expect(await remoteDone, anyOf('closed', 'reset'));
        // Writes after destroy are dropped silently, like dart:io.
        dialed.write('into the void');
        await dialed.flush();
      });

      test('behaves like a dart:io socket where it cannot do better', () async {
        final (dialed, _) = await connect();
        expect(dialed.setOption(SocketOption.tcpNoDelay, true), isFalse);
        expect(() => dialed.addError('x'), throwsUnsupportedError);
        expect(
          () => dialed.getRawOption(RawSocketOption.fromBool(0, 0, true)),
          throwsUnsupportedError,
        );
        expect(dialed.encoding, utf8);
        dialed.encoding = latin1;
        expect(dialed.encoding, latin1);
      });

      test('64 connections run concurrently', () async {
        final echoes = <Future<void>>[];
        final sockets = await Future.wait([
          for (var i = 0; i < 64; i++)
            tunnel.client.connect(port: listener.port),
        ]);
        for (var i = 0; i < sockets.length; i++) {
          final other = await accepted.next;
          echoes.add(other.addStream(other).then((_) => other.close()));
        }
        final replies = await Future.wait([
          for (final (i, socket) in sockets.indexed)
            () async {
              socket.write('connection $i');
              await socket.close();
              return utf8.decodeStream(socket);
            }(),
        ]);
        expect(replies, [for (var i = 0; i < 64; i++) 'connection $i']);
        await Future.wait(echoes);
      }, timeout: const Timeout(Duration(minutes: 2)));
    });

    group('a listener', () {
      test('binds the port it is asked for', () async {
        final fixed = await tunnel.server.listen(port: 4242);
        expect(fixed.port, 4242);
        final accepting = fixed.first;
        final dialed = await tunnel.client.connect(port: 4242);
        addTearDown(dialed.destroy);
        final other = await accepting;
        addTearDown(other.destroy);
        expect(other.port, 4242);
      });

      test('refuses a port that is already taken', () async {
        await expectLater(
          tunnel.server.listen(port: listener.port),
          throwsA(isA<TailcatFailureException>()),
        );
      });

      test('rejects a port outside the range', () {
        expect(() => tunnel.server.listen(port: 65536), throwsRangeError);
        expect(() => tunnel.client.connect(port: 0), throwsRangeError);
        expect(() => tunnel.client.connect(port: -1), throwsRangeError);
      });

      test('leaves accepted sockets open when it closes', () async {
        final second = await tunnel.server.listen();
        final queue = StreamQueue(second);
        final dialed = await tunnel.client.connect(port: second.port);
        addTearDown(dialed.destroy);
        final other = await queue.next;
        addTearDown(other.destroy);

        await second.close();
        expect(await queue.hasNext, isFalse);
        await expectLater(
          tunnel.client.connect(port: second.port),
          throwsA(isA<TailcatFailureException>()),
        );

        other.write('still here');
        await other.close();
        expect(await utf8.decodeStream(dialed), 'still here');
      });

      test(
        'closes, like dart:io, when its subscription is cancelled',
        () async {
          final once = await tunnel.server.listen();
          final accepting = once.first;
          final dialed = await tunnel.client.connect(port: once.port);
          addTearDown(dialed.destroy);
          (await accepting).destroy();
          await expectLater(
            tunnel.client.connect(port: once.port),
            throwsA(isA<TailcatFailureException>()),
          );
        },
      );

      test('nobody listening is a failure, not a hang', () async {
        await expectLater(
          tunnel.client.connect(port: 9),
          throwsA(isA<TailcatFailureException>()),
        );
      });
    });
  }, skip: hermeticUnavailable);
}

/// Varying bytes, so a dropped, repeated or reordered chunk shows.
Uint8List _pattern(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + (i >> 8)) & 0xff;
  }
  return bytes;
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await stream.forEach(builder.add);
  return builder.takeBytes();
}
