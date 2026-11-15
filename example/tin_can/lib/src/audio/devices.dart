// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Microphone and speaker over the `record` and `flutter_pcm_sound` plugins.
library;

import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart'
    show AudioEncoder, AudioRecorder, RecordConfig;

import 'voice_engine.dart';
import 'voice_format.dart';

final class RecordInput implements AudioInput {
  final _recorder = AudioRecorder();

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: VoiceFormat.sampleRate,
      numChannels: 1,
      autoGain: true,
      noiseSuppress: true,
    ),
  );

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Pulls samples when its queue runs low, which suits the jitter buffer.
final class PcmSoundOutput implements AudioOutput {
  @override
  Future<void> setup({
    required int threshold,
    required void Function(int queued) onNeedMore,
  }) async {
    // The plugin logs every call by default.
    await FlutterPcmSound.setLogLevel(LogLevel.none);
    await FlutterPcmSound.setup(
      sampleRate: VoiceFormat.sampleRate,
      channelCount: 1,
      // Speaker even with the ringer off; `record` switches the session to
      // play-and-record while the can is held.
      iosAudioCategory: IosAudioCategory.playback,
    );
    await FlutterPcmSound.setFeedThreshold(threshold);
    FlutterPcmSound.setFeedCallback(onNeedMore);
  }

  @override
  void kick() => FlutterPcmSound.start();

  @override
  Future<void> feed(Int16List samples) {
    // The plugin sends the whole backing buffer, so copy any view.
    final exact =
        samples.offsetInBytes == 0 &&
            samples.buffer.lengthInBytes == samples.lengthInBytes
        ? samples
        : Int16List.fromList(samples);
    return FlutterPcmSound.feed(
      PcmArrayInt16(bytes: exact.buffer.asByteData()),
    );
  }

  @override
  Future<void> dispose() async {
    FlutterPcmSound.setFeedCallback(null);
    await FlutterPcmSound.release();
  }
}
