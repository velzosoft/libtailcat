// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:collection';
import 'dart:typed_data';

import 'voice_format.dart';

/// Reorders voice frames by sequence number, drops late ones and plays silence
/// for missing ones.
///
/// Sequence numbers are u16 and wrap: `a` is before `b` when
/// `(b - a) & 0xFFFF` is in 1..0x7FFF.
final class JitterBuffer {
  JitterBuffer({this.depthFrames = 3, this.maxFrames = 25})
    : assert(depthFrames >= 1),
      assert(maxFrames >= depthFrames);

  /// Frames to collect before playback starts (3 = 60 ms).
  final int depthFrames;

  /// Beyond this the oldest frame is dropped.
  final int maxFrames;

  final SplayTreeMap<int, Int16List> _frames = SplayTreeMap(_compare);

  bool _playing = false;
  int _next = 0;
  int? _lastPlayed;

  int _played = 0;
  int _late = 0;
  int _lost = 0;
  int _concealed = 0;
  int _duplicates = 0;
  int _underruns = 0;
  int _overflows = 0;

  int get depth => _frames.length;

  Duration get depthDuration => VoiceFormat.frameDuration * depth;

  /// `false` while it fills up.
  bool get isPlaying => _playing;

  int get played => _played;

  int get late => _late;

  /// Missing at their turn while later frames had arrived.
  int get lost => _lost;

  /// Turns played as silence: [lost] plus [underruns].
  int get concealed => _concealed;

  int get duplicates => _duplicates;

  int get underruns => _underruns;

  int get overflows => _overflows;

  /// Returns `false` when the frame was dropped as late or a duplicate.
  bool push(int seq, Int16List samples) {
    final s = seq & 0xFFFF;
    if (_isLate(s)) {
      _late++;
      return false;
    }
    if (_frames.containsKey(s)) {
      _duplicates++;
      return false;
    }
    _frames[s] = samples;
    while (_frames.length > maxFrames) {
      final oldest = _frames.firstKey()!;
      _frames.remove(oldest);
      _overflows++;
      if (_playing && oldest == _next) _next = (_next + 1) & 0xFFFF;
    }
    return true;
  }

  /// The frame for this 20 ms turn, or `null` for silence.
  Int16List? pop() {
    if (!_playing) {
      if (_frames.length < depthFrames) return null;
      _playing = true;
      _next = _frames.firstKey()!;
    }
    if (_frames.isEmpty) {
      _underruns++;
      _concealed++;
      _playing = false;
      return null;
    }
    final current = _next;
    _next = (_next + 1) & 0xFFFF;
    final frame = _frames.remove(current);
    if (frame != null) {
      _played++;
      _lastPlayed = current;
      return frame;
    }
    _lost++;
    _concealed++;
    _lastPlayed = current;
    return null;
  }

  void reset() {
    _frames.clear();
    _playing = false;
    _next = 0;
    _lastPlayed = null;
    _played = _late = _lost = _concealed = 0;
    _duplicates = _underruns = _overflows = 0;
  }

  /// While refilling after an underrun, only frames just behind the last
  /// played are late; one far behind means the sender restarted its count.
  bool _isLate(int seq) {
    if (_playing) return _isBefore(seq, _next);
    final lastPlayed = _lastPlayed;
    if (lastPlayed == null) return false;
    return ((lastPlayed - seq) & 0xFFFF) < maxFrames * 2;
  }

  static bool _isBefore(int a, int b) {
    final diff = (b - a) & 0xFFFF;
    return diff >= 1 && diff <= 0x7FFF;
  }

  static int _compare(int a, int b) {
    if (a == b) return 0;
    return _isBefore(a, b) ? -1 : 1;
  }
}
