// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Push-to-talk voice and the twang. Push-to-talk means no echo cancellation.
library;

import 'dart:async';
import 'dart:typed_data';

import '../telemetry/clock.dart';
import '../telemetry/jitter.dart';
import 'filters.dart';
import 'framer.dart';
import 'jitter_buffer.dart';
import 'mixer.dart';
import 'mulaw.dart';
import 'pluck.dart';
import 'voice_format.dart';

abstract interface class AudioInput {
  /// Asks the user the first time.
  Future<bool> requestPermission();

  /// 16 kHz mono PCM16 LE, in chunks of any size.
  Future<Stream<Uint8List>> start();

  Future<void> stop();

  Future<void> dispose();
}

/// A pull-based PCM player.
abstract interface class AudioOutput {
  /// [onNeedMore] gets the queued sample count whenever it drops below
  /// [threshold].
  Future<void> setup({
    required int threshold,
    required void Function(int queued) onNeedMore,
  });

  /// Makes the player ask for samples again after it ran dry.
  void kick();

  Future<void> feed(Int16List samples);

  Future<void> dispose();
}

/// The Inspector's Voice section.
final class VoiceMetrics {
  VoiceMetrics(this._engine);

  final VoiceEngine _engine;

  String get codec => VoiceFormat.codec;

  int get sampleRate => VoiceFormat.sampleRate;

  int get frameSamples => VoiceFormat.frameSamples;

  Duration get frameDuration => VoiceFormat.frameDuration;

  /// RFC 3550 interarrival jitter of the partner's voice.
  Duration get jitter => _engine._estimator.jitter;

  JitterBuffer get buffer => _engine._buffer;

  int get framesSent => _engine._framesSent;

  int get framesReceived => _engine._framesReceived;

  /// Average time between microphone chunks.
  Duration? get captureChunk => _engine._captureChunk;

  /// Samples the player had queued at its last request.
  int get playbackQueued => _engine._lastQueued;

  /// Set by the caller.
  Duration? networkRoundTrip;

  /// Estimated mouth-to-ear delay; only the jitter buffer part is exact.
  List<({String part, Duration delay})> get delayParts {
    final chunk = captureChunk ?? frameDuration;
    final rtt = networkRoundTrip;
    return [
      (part: 'capture: one frame', delay: frameDuration),
      (part: 'capture: recorder chunk', delay: chunk),
      (
        part: 'network: half the echo round trip',
        delay: (rtt ?? Duration.zero) ~/ 2,
      ),
      (part: 'jitter buffer', delay: buffer.depthDuration),
      (
        part: 'playback queue',
        delay: Duration(
          microseconds: playbackQueued * 1000000 ~/ VoiceFormat.sampleRate,
        ),
      ),
    ];
  }

  Duration get mouthToEar =>
      delayParts.fold(Duration.zero, (sum, part) => sum + part.delay);
}

final class VoiceEngine {
  VoiceEngine({
    required this._input,
    required this._output,
    this._clock = systemClock,
  });

  final AudioInput _input;
  final AudioOutput _output;
  final Clock _clock;

  static const playbackThreshold = 2 * VoiceFormat.frameSamples;

  final _buffer = JitterBuffer();
  final _estimator = JitterEstimator(clockRate: VoiceFormat.sampleRate);
  final _filter = TelephoneFilter();
  final _mixer = Mixer();
  final _framer = PcmFramer();
  late final Int16List _twang = synthesizePluck();

  StreamSubscription<Uint8List>? _capture;
  bool _ready = false;
  bool _feeding = false;
  int _framesSent = 0;
  int _framesReceived = 0;
  int _lastQueued = 0;
  DateTime? _lastChunkAt;
  Duration? _captureChunk;

  late final VoiceMetrics metrics = VoiceMetrics(this);

  /// Why playback is unavailable, or `null`.
  String? get unavailable => _unavailable;
  String? _unavailable = 'not started';

  bool get isTalking => _capture != null;

  /// Failures leave the engine silent, not broken.
  Future<void> start() async {
    try {
      await _output.setup(
        threshold: playbackThreshold,
        onNeedMore: _onNeedMore,
      );
      _ready = true;
      _unavailable = null;
    } on Exception catch (e) {
      _unavailable = 'playback unavailable: $e';
    }
  }

  /// Sends each 20 ms frame μ-law encoded. `false` when the microphone is
  /// denied.
  Future<bool> startTalking(void Function(Uint8List frame) send) async {
    if (_capture != null) return true;
    if (!await _input.requestPermission()) return false;
    _framer.reset();
    _lastChunkAt = null;
    final stream = await _input.start();
    _capture = stream.listen((chunk) {
      final now = _clock();
      final last = _lastChunkAt;
      if (last != null) {
        final gap = now.difference(last);
        final previous = _captureChunk;
        _captureChunk = previous == null ? gap : (previous * 7 + gap) ~/ 8;
      }
      _lastChunkAt = now;
      for (final frame in _framer.add(chunk)) {
        _framesSent++;
        send(MuLaw.encode(frame));
      }
    });
    return true;
  }

  Future<void> stopTalking() async {
    if (_capture == null) return;
    await _capture?.cancel();
    _capture = null;
    await _input.stop();
  }

  /// [arrival] is on a monotonic clock.
  void receive({
    required int seq,
    required int sampleTime,
    required Uint8List samples,
    required Duration arrival,
  }) {
    _framesReceived++;
    _estimator.add(timestamp: sampleTime, arrival: arrival);
    _buffer.push(seq, MuLaw.decode(samples));
    _play();
  }

  void pluck() {
    _mixer.play(_twang);
    _play();
  }

  /// A new session starts its sequence numbers afresh.
  void resetPartner() {
    _buffer.reset();
    _estimator.reset();
    _filter.reset();
  }

  void _play() {
    if (!_ready || _feeding) return;
    _feeding = true;
    _output.kick();
  }

  /// Tops the player up to two frames; with nothing to play it runs dry and
  /// [_play] restarts it.
  void _onNeedMore(int queued) {
    _lastQueued = queued;
    final out = <Int16List>[];
    var pending = queued;
    while (pending < playbackThreshold) {
      final voice = _buffer.pop();
      if (voice != null) _filter.processInPlace(voice);
      if (voice == null && _mixer.isIdle && !_buffer.isPlaying) break;
      out.add(_mixer.mix(voice, VoiceFormat.frameSamples));
      pending += VoiceFormat.frameSamples;
    }
    if (out.isEmpty) {
      // Until it runs dry the player keeps calling back by itself.
      if (queued == 0) _feeding = false;
      return;
    }
    final samples = Int16List(out.length * VoiceFormat.frameSamples);
    for (var i = 0; i < out.length; i++) {
      samples.setAll(i * VoiceFormat.frameSamples, out[i]);
    }
    unawaited(_output.feed(samples).catchError((Object _) {}));
  }

  Future<void> dispose() async {
    await stopTalking();
    _ready = false;
    await _input.dispose();
    await _output.dispose();
  }
}
