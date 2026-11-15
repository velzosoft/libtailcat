// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/line/datagrams.dart';
import 'package:tin_can/src/line/messages.dart';

void main() {
  group('control messages', () {
    const examples = <ControlMessage>[
      PairMessage(name: 'Ada', key: 'nodekey:abc'),
      PairedMessage(name: 'Bea'),
      HelloMessage(name: 'Ada'),
      WelcomeMessage(name: 'Bea'),
      PathMessage(direct: true, ms: 23.4),
      PathMessage(direct: false, ms: 84, relay: 'fra', relayMs: 90),
      PluckMessage(),
      MeetMessage(),
      TalkMessage(on: true),
      CutMessage(),
      ByeMessage(),
      PingMessage(t: 1234),
      PongMessage(t: 1234),
    ];

    test('round-trip through JSON', () {
      for (final message in examples) {
        final decoded = ControlMessage.decode(message.encode());
        expect(decoded?.encode(), message.encode(), reason: message.type);
        expect(decoded.runtimeType, message.runtimeType);
      }
    });

    test('carry the type and fields of the plan', () {
      expect(
        jsonDecode(
          const PathMessage(direct: false, ms: 84, relay: 'fra').encode(),
        ),
        {'type': 'path', 'direct': false, 'ms': 84, 'relay': 'fra'},
      );
      expect(jsonDecode(const PluckMessage().encode()), {'type': 'pluck'});
      expect(jsonDecode(const PingMessage(t: 7).encode()), {
        'type': 'ping',
        't': 7,
      });
    });

    test('an unknown type is ignored, and so are unknown fields', () {
      expect(ControlMessage.decode('{"type":"hug","strength":3}'), isNull);
      final hello = ControlMessage.decode(
        '{"type":"hello","name":"Ada","mood":"sunny"}',
      );
      expect(hello, isA<HelloMessage>());
    });

    test('malformed messages are rejected', () {
      for (final text in [
        'not json',
        '[1, 2]',
        '{"no":"type"}',
        '{"type":"talk"}',
        '{"type":"talk","on":"yes"}',
        '{"type":"ping","t":1.5}',
        '{"type":"pair","name":"Ada"}',
      ]) {
        expect(
          () => ControlMessage.decode(text),
          throwsFormatException,
          reason: text,
        );
      }
    });

    test('a message over 64 KB is rejected', () {
      final big = jsonEncode({
        'type': 'hello',
        'name': 'x' * maxControlMessageBytes,
      });
      expect(() => ControlMessage.decode(big), throwsFormatException);
    });

    test('names are cleaned and cut', () {
      expect(cleanName('  Ada\u0000\n '), 'Ada');
      expect(cleanName('x' * 100).length, maxNameLength);
      final decoded = ControlMessage.decode(
        jsonEncode({'type': 'hello', 'name': '  ${'y' * 60}'}),
      ) as HelloMessage;
      expect(decoded.name, 'y' * maxNameLength);
    });
  });

  group('datagrams', () {
    test('have the sizes of the plan, far below the 1232-byte limit', () {
      expect(
        TouchDatagram.at(seq: 1, x: 0, y: 0, down: true).encode(),
        hasLength(8),
      );
      expect(
        VoiceDatagram(seq: 1, sampleTime: 0, samples: Uint8List(320)).encode(),
        hasLength(327),
      );
      expect(const EchoDatagram(seq: 1, time: 2).encode(), hasLength(7));
      expect(const EchoReplyDatagram(seq: 1, time: 2).encode(), hasLength(7));
    });

    test('touch round-trips, big-endian with the kind first', () {
      final touch = TouchDatagram.at(seq: 0x0102, x: 1, y: 0.5, down: true);
      final bytes = touch.encode();
      expect(bytes.sublist(0, 3), [1, 0x01, 0x02]);
      expect(bytes.sublist(3, 5), [0xFF, 0xFF]);
      final decoded = Datagram.decode(bytes)! as TouchDatagram;
      expect(decoded.seq, 0x0102);
      expect(decoded.dx, 1.0);
      expect(decoded.dy, closeTo(0.5, 1 / 65535));
      expect(decoded.isDown, isTrue);
      expect(
        (Datagram.decode(
                  TouchDatagram.at(seq: 2, x: 2, y: -1, down: false).encode(),
                )!
                as TouchDatagram)
            .isDown,
        isFalse,
      );
    });

    test('voice round-trips with its sample time', () {
      final samples = Uint8List.fromList(List.generate(320, (i) => i & 0xFF));
      final voice = VoiceDatagram(
        seq: 65535,
        sampleTime: 0xFFFFFFFF,
        samples: samples,
      );
      final decoded = Datagram.decode(voice.encode())! as VoiceDatagram;
      expect(decoded.seq, 65535);
      expect(decoded.sampleTime, 0xFFFFFFFF);
      expect(decoded.samples, samples);
      expect(
        () => VoiceDatagram(seq: 0, sampleTime: 0, samples: Uint8List(10)),
        throwsArgumentError,
      );
    });

    test('echoes round-trip, and a reply carries the echo\'s fields', () {
      const echo = EchoDatagram(seq: 9, time: 123456);
      final decoded = Datagram.decode(echo.encode())! as EchoDatagram;
      expect((decoded.seq, decoded.time), (9, 123456));
      final reply = EchoReplyDatagram.to(decoded);
      final back = Datagram.decode(reply.encode())! as EchoReplyDatagram;
      expect((back.seq, back.time), (9, 123456));
    });

    test('unknown kinds and wrong sizes are dropped', () {
      expect(Datagram.decode(Uint8List(0)), isNull);
      expect(Datagram.decode(Uint8List.fromList([9, 0, 0])), isNull);
      expect(Datagram.decode(Uint8List.fromList([1, 0, 0])), isNull);
      expect(Datagram.decode(Uint8List(327)..[0] = 3), isNull);
    });

    test('sequence numbers compare across the wrap', () {
      expect(isNewerSeq(1, 0), isTrue);
      expect(isNewerSeq(0, 65535), isTrue);
      expect(isNewerSeq(65535, 0), isFalse);
      expect(isNewerSeq(5, 5), isFalse);
      final counter = SeqCounter();
      for (var i = 0; i < 65535; i++) {
        counter.next();
      }
      expect(counter.next(), 65535);
      expect(counter.next(), 0);
    });
  });
}
