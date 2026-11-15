// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/line/safety_code.dart';

void main() {
  const host =
      'nodekey:1111111111111111111111111111111111111111111111111111111111111111';
  const guest =
      'nodekey:2222222222222222222222222222222222222222222222222222222222222222';

  test('is the first 36 bits of SHA-256(host key ‖ guest key)', () {
    final code = SafetyCode.compute(hostKey: host, guestKey: guest);
    final digest = sha256.convert(utf8.encode(host + guest)).bytes;
    var bits = '';
    for (final byte in digest.take(5)) {
      bits += byte.toRadixString(2).padLeft(8, '0');
    }
    final expected = [
      for (var i = 0; i < 6; i++)
        int.parse(bits.substring(i * 6, i * 6 + 6), radix: 2),
    ];
    expect(code.symbols.map((s) => s.index), expected);
    expect(code.bitGroups.join(), bits.substring(0, 36));
    expect(
      code.digestHex,
      startsWith(digest.first.toRadixString(16).padLeft(2, '0')),
    );
    expect(code.symbols, hasLength(SafetyCode.length));
  });

  test('both sides agree, and the order of the keys matters', () {
    final a = SafetyCode.compute(hostKey: host, guestKey: guest);
    final b = SafetyCode.compute(hostKey: host, guestKey: guest);
    final swapped = SafetyCode.compute(hostKey: guest, guestKey: host);
    expect(a, b);
    expect(a.glyphs, b.glyphs);
    expect(a == swapped, isFalse);
  });

  test('another guest key gives other symbols', () {
    final a = SafetyCode.compute(hostKey: host, guestKey: guest);
    final c = SafetyCode.compute(hostKey: host, guestKey: '${guest}3');
    expect(a.glyphs == c.glyphs, isFalse);
  });

  test('has 64 distinct symbols with names', () {
    expect(safetySymbols, hasLength(64));
    expect(safetySymbols.map((s) => s.glyph).toSet(), hasLength(64));
    expect(safetySymbols.map((s) => s.name).toSet(), hasLength(64));
    for (var i = 0; i < 64; i++) {
      expect(safetySymbols[i].index, i);
      // No variation selector: every glyph renders as an emoji by itself.
      expect(safetySymbols[i].glyph.runes.contains(0xFE0F), isFalse);
    }
    final code = SafetyCode.compute(hostKey: host, guestKey: guest);
    expect(code.spoken.split(', '), hasLength(6));
  });
}
