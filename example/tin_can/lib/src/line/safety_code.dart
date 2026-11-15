// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';

import 'package:crypto/crypto.dart';

final class SafetySymbol {
  const SafetySymbol(this.index, this.glyph, this.name);

  /// 0 to 63.
  final int index;

  /// An emoji.
  final String glyph;

  /// Read out loud, and by screen readers.
  final String name;

  @override
  String toString() => '$glyph $name';
}

/// The first 36 bits of SHA-256(host public key ‖ guest public key), six per
/// symbol. The guest takes the host's key from the invite, so a stolen
/// invite or swapped keys make the two screens disagree.
final class SafetyCode {
  SafetyCode._(this.hostKey, this.guestKey, this.digest)
    : symbols = List.unmodifiable([
        for (var i = 0; i < length; i++)
          safetySymbols[_bits(digest, i * bitsPerSymbol, bitsPerSymbol)],
      ]);

  /// From the keys' text form.
  factory SafetyCode.compute({
    required String hostKey,
    required String guestKey,
  }) => SafetyCode._(
    hostKey,
    guestKey,
    sha256.convert(utf8.encode(hostKey + guestKey)).bytes,
  );

  static const length = 6;

  static const bitsPerSymbol = 6;

  final String hostKey;

  final String guestKey;

  final List<int> digest;

  final List<SafetySymbol> symbols;

  String get digestHex =>
      digest.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  List<String> get bitGroups => [
    for (final symbol in symbols)
      symbol.index.toRadixString(2).padLeft(bitsPerSymbol, '0'),
  ];

  String get glyphs => symbols.map((symbol) => symbol.glyph).join(' ');

  String get spoken => symbols.map((symbol) => symbol.name).join(', ');

  @override
  bool operator ==(Object other) =>
      other is SafetyCode && other.digestHex == digestHex;

  @override
  int get hashCode => digestHex.hashCode;

  @override
  String toString() => 'SafetyCode($glyphs)';

  /// Most significant bit first.
  static int _bits(List<int> bytes, int offset, int count) {
    var value = 0;
    for (var i = offset; i < offset + count; i++) {
      final bit = (bytes[i >> 3] >> (7 - (i & 7))) & 1;
      value = (value << 1) | bit;
    }
    return value;
  }
}

/// Distinct-looking, short-named, and colour emoji without a variation
/// selector.
const List<SafetySymbol> safetySymbols = [
  SafetySymbol(0, '🍎', 'apple'),
  SafetySymbol(1, '🍌', 'banana'),
  SafetySymbol(2, '🍇', 'grapes'),
  SafetySymbol(3, '🍉', 'melon'),
  SafetySymbol(4, '🍒', 'cherries'),
  SafetySymbol(5, '🍋', 'lemon'),
  SafetySymbol(6, '🍍', 'pineapple'),
  SafetySymbol(7, '🥝', 'kiwi'),
  SafetySymbol(8, '🥕', 'carrot'),
  SafetySymbol(9, '🌽', 'corn'),
  SafetySymbol(10, '🍄', 'mushroom'),
  SafetySymbol(11, '🥦', 'broccoli'),
  SafetySymbol(12, '🥑', 'avocado'),
  SafetySymbol(13, '🥨', 'pretzel'),
  SafetySymbol(14, '🧀', 'cheese'),
  SafetySymbol(15, '🍩', 'doughnut'),
  SafetySymbol(16, '🍪', 'cookie'),
  SafetySymbol(17, '🎂', 'cake'),
  SafetySymbol(18, '🍿', 'popcorn'),
  SafetySymbol(19, '☕', 'coffee'),
  SafetySymbol(20, '🐶', 'dog'),
  SafetySymbol(21, '🐱', 'cat'),
  SafetySymbol(22, '🐭', 'mouse'),
  SafetySymbol(23, '🐰', 'rabbit'),
  SafetySymbol(24, '🦊', 'fox'),
  SafetySymbol(25, '🐻', 'bear'),
  SafetySymbol(26, '🐼', 'panda'),
  SafetySymbol(27, '🐨', 'koala'),
  SafetySymbol(28, '🐯', 'tiger'),
  SafetySymbol(29, '🦁', 'lion'),
  SafetySymbol(30, '🐮', 'cow'),
  SafetySymbol(31, '🐷', 'pig'),
  SafetySymbol(32, '🐸', 'frog'),
  SafetySymbol(33, '🐵', 'monkey'),
  SafetySymbol(34, '🐔', 'chicken'),
  SafetySymbol(35, '🐧', 'penguin'),
  SafetySymbol(36, '🐦', 'bird'),
  SafetySymbol(37, '🦆', 'duck'),
  SafetySymbol(38, '🦉', 'owl'),
  SafetySymbol(39, '🐝', 'bee'),
  SafetySymbol(40, '🐞', 'ladybird'),
  SafetySymbol(41, '🦋', 'butterfly'),
  SafetySymbol(42, '🐌', 'snail'),
  SafetySymbol(43, '🐢', 'turtle'),
  SafetySymbol(44, '🐙', 'octopus'),
  SafetySymbol(45, '🐳', 'whale'),
  SafetySymbol(46, '🐬', 'dolphin'),
  SafetySymbol(47, '🦀', 'crab'),
  SafetySymbol(48, '🌵', 'cactus'),
  SafetySymbol(49, '🌲', 'tree'),
  SafetySymbol(50, '🌻', 'sunflower'),
  SafetySymbol(51, '🌹', 'rose'),
  SafetySymbol(52, '🍀', 'clover'),
  SafetySymbol(53, '🌙', 'moon'),
  SafetySymbol(54, '⭐', 'star'),
  SafetySymbol(55, '🌞', 'sun'),
  SafetySymbol(56, '🌈', 'rainbow'),
  SafetySymbol(57, '⛄', 'snowman'),
  SafetySymbol(58, '🔥', 'fire'),
  SafetySymbol(59, '💧', 'drop'),
  SafetySymbol(60, '⚓', 'anchor'),
  SafetySymbol(61, '🔑', 'key'),
  SafetySymbol(62, '🔔', 'bell'),
  SafetySymbol(63, '🎈', 'balloon'),
];
