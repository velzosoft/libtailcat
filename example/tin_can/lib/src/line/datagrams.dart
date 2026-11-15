// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// The realtime protocol: big-endian UDP datagrams, kind in the first byte.
library;

import 'dart:typed_data';

const datagramPort = 5000;

sealed class Datagram {
  const Datagram();

  int get kind;

  /// 16 bits, counted per kind so loss is measured per kind.
  int get seq;

  Uint8List encode();

  /// One line, for the wire tap.
  String describe();

  /// `null` for an unknown kind or a malformed datagram.
  static Datagram? decode(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    final data = ByteData.sublistView(bytes);
    return switch (bytes[0]) {
      TouchDatagram.kindByte when bytes.length == TouchDatagram.size =>
        TouchDatagram(
          seq: data.getUint16(1),
          x: data.getUint16(3),
          y: data.getUint16(5),
          flags: data.getUint8(7),
        ),
      VoiceDatagram.kindByte when bytes.length == VoiceDatagram.size =>
        VoiceDatagram(
          seq: data.getUint16(1),
          sampleTime: data.getUint32(3),
          samples: Uint8List.fromList(bytes.sublist(VoiceDatagram.headerSize)),
        ),
      EchoDatagram.kindByte when bytes.length == EchoDatagram.size =>
        EchoDatagram(seq: data.getUint16(1), time: data.getUint32(3)),
      EchoReplyDatagram.kindByte when bytes.length == EchoReplyDatagram.size =>
        EchoReplyDatagram(seq: data.getUint16(1), time: data.getUint32(3)),
      _ => null,
    };
  }
}

/// Kind 1: the sender's fingertip, normalised to 0..65535 per axis so screens
/// of different shapes map onto each other.
final class TouchDatagram extends Datagram {
  const TouchDatagram({
    required this.seq,
    required this.x,
    required this.y,
    required this.flags,
  });

  /// [x] and [y] in 0..1.
  factory TouchDatagram.at({
    required int seq,
    required double x,
    required double y,
    required bool down,
  }) => TouchDatagram(
    seq: seq & 0xFFFF,
    x: _toU16(x),
    y: _toU16(y),
    flags: down ? downFlag : upFlag,
  );

  static const kindByte = 1;

  /// kind u8, seq u16, x u16, y u16, flags u8.
  static const size = 8;

  static const downFlag = 0x01;

  /// The position is where the finger left.
  static const upFlag = 0x02;

  @override
  int get kind => kindByte;

  @override
  final int seq;

  /// 0 (left) to 65535 (right).
  final int x;

  /// 0 (top) to 65535 (bottom).
  final int y;

  /// [downFlag] or [upFlag].
  final int flags;

  bool get isDown => flags & downFlag != 0;

  double get dx => x / 0xFFFF;

  double get dy => y / 0xFFFF;

  @override
  Uint8List encode() {
    final data = ByteData(size)
      ..setUint8(0, kind)
      ..setUint16(1, seq)
      ..setUint16(3, x)
      ..setUint16(5, y)
      ..setUint8(7, flags);
    return data.buffer.asUint8List();
  }

  @override
  String describe() =>
      'seq $seq x ${dx.toStringAsFixed(3)} y ${dy.toStringAsFixed(3)} '
      '${isDown ? 'down' : 'up'}';

  static int _toU16(double value) => (value.clamp(0.0, 1.0) * 0xFFFF).round();
}

/// Kind 2: 20 ms of voice, as 320 μ-law samples at 16 kHz.
final class VoiceDatagram extends Datagram {
  VoiceDatagram({
    required this.seq,
    required this.sampleTime,
    required this.samples,
  }) {
    if (samples.length != samplesPerFrame) {
      throw ArgumentError.value(
        samples.length,
        'samples',
        'a voice frame has $samplesPerFrame samples',
      );
    }
  }

  static const kindByte = 2;

  /// 20 ms at 16 kHz.
  static const samplesPerFrame = 320;

  /// kind u8, seq u16, sample time u32.
  static const headerSize = 7;

  static const size = headerSize + samplesPerFrame;

  @override
  int get kind => kindByte;

  @override
  final int seq;

  /// Index of the first sample in the sender's capture, wrapping at 2^32.
  /// Used for interarrival jitter (RFC 3550).
  final int sampleTime;

  /// One μ-law byte per sample.
  final Uint8List samples;

  @override
  Uint8List encode() {
    final bytes = Uint8List(size);
    ByteData.sublistView(bytes)
      ..setUint8(0, kind)
      ..setUint16(1, seq)
      ..setUint32(3, sampleTime);
    bytes.setRange(headerSize, size, samples);
    return bytes;
  }

  @override
  String describe() =>
      'seq $seq sample time $sampleTime, $samplesPerFrame μ-law samples';
}

/// Kind 3: a probe the receiver sends straight back. Keeps the UDP flow alive
/// past `udpIdleTimeout` and measures round trip and loss.
final class EchoDatagram extends Datagram {
  const EchoDatagram({required this.seq, required this.time});

  static const kindByte = 3;

  /// kind u8, seq u16, time u32.
  static const size = 7;

  @override
  int get kind => kindByte;

  @override
  final int seq;

  /// The sender's clock in milliseconds, wrapping at 2^32.
  final int time;

  @override
  Uint8List encode() => _encodeEcho(kind, seq, time);

  @override
  String describe() => 'seq $seq time $time ms';
}

/// Kind 4: an [EchoDatagram] sent back with its seq and time.
final class EchoReplyDatagram extends Datagram {
  const EchoReplyDatagram({required this.seq, required this.time});

  factory EchoReplyDatagram.to(EchoDatagram echo) =>
      EchoReplyDatagram(seq: echo.seq, time: echo.time);

  static const kindByte = 4;

  static const size = 7;

  @override
  int get kind => kindByte;

  @override
  final int seq;

  final int time;

  @override
  Uint8List encode() => _encodeEcho(kind, seq, time);

  @override
  String describe() => 'seq $seq time $time ms';
}

Uint8List _encodeEcho(int kind, int seq, int time) {
  final data = ByteData(7)
    ..setUint8(0, kind)
    ..setUint16(1, seq & 0xFFFF)
    ..setUint32(3, time & 0xFFFFFFFF);
  return data.buffer.asUint8List();
}

/// Whether 16-bit [a] comes after [b], with wraparound (RFC 1982).
bool isNewerSeq(int a, int b) {
  final delta = (a - b) & 0xFFFF;
  return delta != 0 && delta < 0x8000;
}

/// Wraps after 65535.
final class SeqCounter {
  int _next = 0;

  int next() {
    final seq = _next;
    _next = (_next + 1) & 0xFFFF;
    return seq;
  }
}
