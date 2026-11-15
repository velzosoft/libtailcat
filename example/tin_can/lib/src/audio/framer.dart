// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:typed_data';

import 'voice_format.dart';

/// Cuts PCM16 LE chunks of any size (even mid-sample) into whole frames, one
/// per voice datagram.
final class PcmFramer {
  PcmFramer({this.frameSamples = VoiceFormat.frameSamples})
    : _pending = Uint8List(frameSamples * 2);

  final int frameSamples;

  final Uint8List _pending;
  int _filled = 0;

  /// Returns the frames completed by [bytes], oldest first.
  List<Int16List> add(Uint8List bytes) {
    final frames = <Int16List>[];
    var offset = 0;
    while (offset < bytes.length) {
      final take = (_pending.length - _filled).clamp(0, bytes.length - offset);
      _pending.setRange(_filled, _filled + take, bytes, offset);
      _filled += take;
      offset += take;
      if (_filled == _pending.length) {
        frames.add(_frameFromPending());
        _filled = 0;
      }
    }
    return frames;
  }

  void reset() => _filled = 0;

  Int16List _frameFromPending() {
    final data = ByteData.sublistView(_pending);
    final frame = Int16List(frameSamples);
    for (var i = 0; i < frameSamples; i++) {
      frame[i] = data.getInt16(i * 2, Endian.little);
    }
    return frame;
  }
}
