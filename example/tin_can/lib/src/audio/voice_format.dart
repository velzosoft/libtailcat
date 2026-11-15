// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// 16 kHz mono in 20 ms frames (one per datagram), sent as 8-bit μ-law.
abstract final class VoiceFormat {
  static const sampleRate = 16000;

  static const frameSamples = 320;

  static const frameDuration = Duration(milliseconds: 20);

  static const codec = 'G.711 μ-law';
}
