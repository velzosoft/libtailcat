// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:material_ui/material_ui.dart';

/// Colours of the cans, the string and the fingertips.
@immutable
final class TinCanColors extends ThemeExtension<TinCanColors> {
  const TinCanColors({
    required this.backdrop,
    required this.tin,
    required this.tinShade,
    required this.twine,
    required this.peg,
    required this.partnerGlow,
    required this.ownGlow,
    required this.xray,
  });

  static const light = TinCanColors(
    backdrop: Color(0xFFF4EFE6),
    tin: Color(0xFFB8BEC6),
    tinShade: Color(0xFF7D8590),
    twine: Color(0xFFC0392B),
    peg: Color(0xFF6B4F3A),
    partnerGlow: Color(0xFF00A6A6),
    ownGlow: Color(0xFFE08E0B),
    xray: Color(0xFF2F5D8A),
  );

  static const dark = TinCanColors(
    backdrop: Color(0xFF10151C),
    tin: Color(0xFF8D96A3),
    tinShade: Color(0xFF4D5562),
    twine: Color(0xFFFF6B57),
    peg: Color(0xFFB08968),
    partnerGlow: Color(0xFF3FE0D0),
    ownGlow: Color(0xFFFFB84D),
    xray: Color(0xFF8CC3FF),
  );

  final Color backdrop;

  final Color tin;

  /// The cans' shadows and ridges.
  final Color tinShade;

  /// The string.
  final Color twine;

  /// What a relayed string bends over.
  final Color peg;

  /// The partner's fingertip.
  final Color partnerGlow;

  final Color ownGlow;

  final Color xray;

  static TinCanColors of(BuildContext context) =>
      Theme.of(context).extension<TinCanColors>() ?? light;

  @override
  TinCanColors copyWith() => this;

  @override
  TinCanColors lerp(TinCanColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return TinCanColors(
      backdrop: mix(backdrop, other.backdrop),
      tin: mix(tin, other.tin),
      tinShade: mix(tinShade, other.tinShade),
      twine: mix(twine, other.twine),
      peg: mix(peg, other.peg),
      partnerGlow: mix(partnerGlow, other.partnerGlow),
      ownGlow: mix(ownGlow, other.ownGlow),
      xray: mix(xray, other.xray),
    );
  }
}

ThemeData tinCanTheme(Brightness brightness) {
  final colors = brightness == Brightness.light
      ? TinCanColors.light
      : TinCanColors.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: colors.twine,
    brightness: brightness,
    surface: colors.backdrop,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.backdrop,
    extensions: [colors],
    appBarTheme: AppBarTheme(
      backgroundColor: colors.backdrop,
      surfaceTintColor: Colors.transparent,
    ),
  );
}

const TextStyle monoStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Menlo', 'Courier', 'monospace'],
  fontSize: 12,
);
