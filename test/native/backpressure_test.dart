// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

@Tags(['native'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:libtailcat/src/runtime/reader.dart';
import 'package:test/test.dart';

import '../support/native.dart';

void main() {
  test(
    'a paused reader holds back the writer and bounds what is buffered',
    () async {
      final tunnel = await Tunnel.open();
      final listener = await tunnel.server.listen();
      final accepting = listener.first;
      final sender = await tunnel.client.connect(port: listener.port);
      addTearDown(sender.destroy);
      final receiver = await accepting;
      addTearDown(receiver.destroy);

      const chunkSize = 64 * 1024;
      const total = 48 * 1024 * 1024;
      final chunk = Uint8List(chunkSize);
      var produced = 0;
      // An async* stream only runs on demand, so produced == pulled.
      Stream<List<int>> source() async* {
        while (produced < total) {
          produced += chunkSize;
          yield chunk;
        }
      }

      var received = 0;
      final allReceived = Completer<void>();
      final subscription = receiver.listen(
        (data) => received += data.length,
        onDone: allReceived.complete,
      );
      subscription.pause();

      final sent = sender.addStream(source()).then((_) => sender.close());

      // Ample time to fill every buffer on the way.
      await Future<void>.delayed(const Duration(seconds: 3));
      final producedWhilePaused = produced;
      final receivedWhilePaused = received;

      // The reader holds at most its window; the rest waits in TCP buffers.
      expect(receivedWhilePaused, 0);
      expect(
        producedWhilePaused,
        lessThan(total ~/ 2),
        reason: 'the source should have been paused long before the end',
      );

      await Future<void>.delayed(const Duration(seconds: 1));
      expect(produced, producedWhilePaused);

      subscription.resume();
      await sent;
      await allReceived.future;
      expect(received, total);
      expect(produced, total);
      await subscription.cancel();
    },
    skip: hermeticUnavailable,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('the reader window is small', () {
    // Dart memory a paused stream can hold, per connection.
    expect(readWindow * readChunkSize, lessThanOrEqualTo(1024 * 1024));
  });
}
