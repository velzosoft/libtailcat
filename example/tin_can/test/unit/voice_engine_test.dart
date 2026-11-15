// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/audio/mulaw.dart';
import 'package:tin_can/src/audio/voice_engine.dart';

import 'support/fake_audio.dart';

Uint8List pcmBytes(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  late FakeInput input;
  late FakeOutput output;
  late VoiceEngine engine;

  setUp(() async {
    input = FakeInput();
    output = FakeOutput();
    engine = VoiceEngine(input: input, output: output);
    await engine.start();
  });

  test('sends 20 ms μ-law frames while talking, and nothing after', () async {
    final sent = <Uint8List>[];
    expect(await engine.startTalking(sent.add), isTrue);
    expect(engine.isTalking, isTrue);
    // 50 ms of a tone, in uneven chunks.
    final tone = [
      for (var i = 0; i < 800; i++)
        (8000 * math.sin(2 * math.pi * 440 * i / 16000)).round(),
    ];
    input.controller!
      ..add(pcmBytes(tone.sublist(0, 333)))
      ..add(pcmBytes(tone.sublist(333)));
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(2), reason: '800 samples make two whole frames');
    expect(sent.first, hasLength(320));
    expect(MuLaw.decode(sent.first)[100], closeTo(tone[100], 300));
    expect(engine.metrics.framesSent, 2);

    await engine.stopTalking();
    expect(engine.isTalking, isFalse);
  });

  test('a denied microphone sends nothing', () async {
    input.allowed = false;
    expect(await engine.startTalking((_) => fail('sent')), isFalse);
    expect(engine.isTalking, isFalse);
  });

  test('plays received voice after the 60 ms jitter buffer fills', () {
    final frame = MuLaw.encode(Int16List.fromList(List.filled(320, 4000)));
    engine.receive(
      seq: 0,
      sampleTime: 0,
      samples: frame,
      arrival: Duration.zero,
    );
    expect(output.fed, isEmpty, reason: 'still filling');
    for (var seq = 1; seq < 4; seq++) {
      engine.receive(
        seq: seq,
        sampleTime: seq * 320,
        samples: frame,
        arrival: Duration(milliseconds: seq * 20),
      );
    }
    expect(output.fed, isNotEmpty);
    final played = output.fed.expand((samples) => samples).toList();
    expect(played.any((sample) => sample != 0), isTrue);
    expect(engine.metrics.framesReceived, 4);
    expect(engine.metrics.jitter, Duration.zero, reason: 'evenly spaced');
    expect(engine.metrics.delayParts, isNotEmpty);
  });

  test('a pluck plays the twang through the same output', () {
    engine.pluck();
    expect(output.kicks, 1);
    final played = output.fed.expand((samples) => samples).toList();
    expect(played.map((s) => s.abs()).reduce(math.max), greaterThan(1000));
  });
}
