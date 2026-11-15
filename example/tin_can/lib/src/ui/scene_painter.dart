// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../line/string_state.dart';
import 'theme.dart';

final class SceneLayout {
  SceneLayout(this.size)
    : canSize = Size(
        (size.width * 0.26).clamp(64.0, 120.0),
        (size.height * 0.12).clamp(64.0, 110.0),
      ) {
    partnerCan = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.12 + canSize.height / 4),
      width: canSize.width,
      height: canSize.height,
    );
    ownCan = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.86 - canSize.height / 4),
      width: canSize.width,
      height: canSize.height,
    );
  }

  final Size size;

  final Size canSize;

  late final Rect partnerCan;

  late final Rect ownCan;

  /// The height of a can's end, seen at an angle.
  double get ellipseHeight => canSize.width * 0.28;

  /// Where the string leaves the partner's can.
  Offset get top => partnerCan.bottomCenter - Offset(0, ellipseHeight / 2);

  /// Where the string leaves this side's can.
  Offset get bottom => ownCan.topCenter + Offset(0, ellipseHeight / 2);

  /// Where a relayed string bends.
  Offset get peg =>
      Offset(size.width / 2 + size.width * 0.24, (top.dy + bottom.dy) / 2);

  Offset toCanvas(({double x, double y}) tip) =>
      Offset(tip.x * size.width, tip.y * size.height);

  /// Normalised to 0..1.
  ({double x, double y}) toNormal(Offset position) => (
    x: (position.dx / size.width).clamp(0.0, 1.0),
    y: (position.dy / size.height).clamp(0.0, 1.0),
  );
}

final class SceneFrame {
  const SceneFrame({
    required this.time,
    required this.state,
    this.tremble = 0,
    this.pluck = 0,
    this.snap = 0,
    this.relayLabel,
    this.partnerTip,
    this.partnerTipFade = 1,
    this.ownTip,
    this.burstAt,
    this.burst = 0,
    this.talking = false,
    this.partnerTalking = false,
    this.reduceMotion = false,
  });

  /// Seconds.
  final double time;

  final StringState state;

  /// 0 to 1, from the latency.
  final double tremble;

  /// 1 just after a pluck, decaying to 0.
  final double pluck;

  /// 1 just after snapping straight, decaying to 0.
  final double snap;

  /// The relay's city, for the peg.
  final String? relayLabel;

  /// Normalised to 0..1, like [ownTip] and [burstAt].
  final ({double x, double y})? partnerTip;

  /// 1 for a fresh fingertip, fading to 0 as it goes stale.
  final double partnerTipFade;

  final ({double x, double y})? ownTip;

  /// Where the fingertips met.
  final ({double x, double y})? burstAt;

  /// How far the burst has spread, 0 to 1.
  final double burst;

  final bool talking;

  final bool partnerTalking;

  /// The system's reduce-motion setting.
  final bool reduceMotion;
}

class ScenePainter extends CustomPainter {
  ScenePainter({
    required this.frame,
    required this.colors,
    this.labelStyle = const TextStyle(fontSize: 13),
    super.repaint,
  });

  final TextStyle labelStyle;

  /// Read when painting.
  final SceneFrame Function() frame;

  final TinCanColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame();
    final layout = SceneLayout(size);
    final points = stringPoints(layout, f);
    _paintString(canvas, points, f);
    if (f.state == StringState.relayed) {
      _paintPeg(canvas, layout.peg, f.relayLabel, size);
    }
    _paintCan(
      canvas,
      layout.partnerCan,
      opensDown: false,
      dimmed: f.state == StringState.slack,
      talking: f.partnerTalking,
      glow: colors.partnerGlow,
      time: f.reduceMotion ? 0 : f.time,
    );
    _paintCan(
      canvas,
      layout.ownCan,
      opensDown: true,
      dimmed: false,
      talking: f.talking,
      glow: colors.ownGlow,
      time: f.reduceMotion ? 0 : f.time,
    );
    final partnerTip = f.partnerTip;
    if (partnerTip != null && f.partnerTipFade > 0) {
      _paintGlow(
        canvas,
        layout.toCanvas(partnerTip),
        colors.partnerGlow,
        f.partnerTipFade,
      );
    }
    final ownTip = f.ownTip;
    if (ownTip != null) {
      canvas.drawCircle(
        layout.toCanvas(ownTip),
        22,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colors.ownGlow.withValues(alpha: 0.8),
      );
    }
    final burstAt = f.burstAt;
    if (burstAt != null && f.burst > 0 && f.burst < 1) {
      _paintBurst(canvas, layout.toCanvas(burstAt), f.burst, f.reduceMotion);
    }
  }

  /// A polyline from the partner's can to this side's.
  static List<Offset> stringPoints(SceneLayout layout, SceneFrame f) {
    const count = 48;
    final a = layout.top;
    final b = layout.bottom;
    final width = layout.size.width;
    final t = f.reduceMotion ? 0.0 : f.time;
    // Sideways displacement at s, 0..1 along the string.
    double sway(double s) {
      final hump = math.sin(math.pi * s);
      var dx = 0.0;
      switch (f.state) {
        case StringState.slack:
          dx = width * 0.16 * hump + width * 0.03 * math.sin(2 * math.pi * s);
        case StringState.pulling:
          final pull = f.reduceMotion
              ? 0.5
              : 0.5 + 0.5 * math.sin(2 * math.pi * t / 1.6);
          dx = width * (0.03 + 0.10 * pull) * hump;
        case StringState.relayed || StringState.direct:
          dx = f.tremble * 3.5 * hump * math.sin(2 * math.pi * 11 * t + s * 9);
      }
      // A pluck rings as a decaying standing wave.
      dx += f.pluck * 16 * hump * math.sin(2 * math.pi * 7 * t);
      // Snapping straight overshoots once.
      dx += f.snap * 22 * hump * math.cos(math.pi * 3 * (1 - f.snap));
      return dx;
    }

    if (f.state == StringState.relayed) {
      final peg = layout.peg;
      final half = count ~/ 2;
      return [
        for (var i = 0; i <= half; i++)
          Offset.lerp(a, peg, i / half)! + Offset(sway(i / count) * 0.5, 0),
        for (var i = 1; i <= half; i++)
          Offset.lerp(peg, b, i / half)! +
              Offset(sway((half + i) / count) * 0.5, 0),
      ];
    }
    return [
      for (var i = 0; i <= count; i++)
        Offset.lerp(a, b, i / count)! + Offset(sway(i / count), 0),
    ];
  }

  void _paintString(Canvas canvas, List<Offset> points, SceneFrame f) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    final slack = f.state == StringState.slack;
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = slack ? 2.5 : 3.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = colors.twine.withValues(alpha: slack ? 0.55 : 1),
    );
  }

  void _paintPeg(Canvas canvas, Offset peg, String? label, Size size) {
    canvas.drawCircle(peg, 9, Paint()..color = colors.peg);
    canvas.drawCircle(
      peg,
      3,
      Paint()..color = colors.backdrop.withValues(alpha: 0.8),
    );
    if (label == null) return;
    final text = TextPainter(
      text: TextSpan(
        text: '$label\nrelay',
        style: labelStyle.copyWith(
          color: colors.peg,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(40, size.width - peg.dx - 20));
    text.paint(canvas, peg + Offset(14, -text.height / 2));
  }

  void _paintCan(
    Canvas canvas,
    Rect rect, {
    required bool opensDown,
    required bool dimmed,
    required bool talking,
    required Color glow,
    required double time,
  }) {
    final alpha = dimmed ? 0.45 : 1.0;
    final ellipseHeight = rect.width * 0.28;
    final body = Rect.fromLTRB(
      rect.left,
      rect.top + ellipseHeight / 2,
      rect.right,
      rect.bottom - ellipseHeight / 2,
    );
    if (talking) {
      final pulse = 0.5 + 0.5 * math.sin(time * 2 * math.pi * 2);
      canvas.drawOval(
        rect.inflate(10 + 6 * pulse),
        Paint()
          ..shader = RadialGradient(
            colors: [glow.withValues(alpha: 0.45), glow.withValues(alpha: 0)],
          ).createShader(rect.inflate(20)),
      );
    }
    final tin = Paint()
      ..shader = LinearGradient(
        colors: [
          colors.tinShade.withValues(alpha: alpha),
          colors.tin.withValues(alpha: alpha),
          Color.lerp(colors.tin, Colors.white, 0.5)!.withValues(alpha: alpha),
          colors.tin.withValues(alpha: alpha),
          colors.tinShade.withValues(alpha: alpha),
        ],
        stops: const [0, 0.25, 0.45, 0.7, 1],
      ).createShader(body);
    canvas.drawRect(body, tin);
    final bottomEllipse = Rect.fromCenter(
      center: body.bottomCenter,
      width: rect.width,
      height: ellipseHeight,
    );
    final topEllipse = Rect.fromCenter(
      center: body.topCenter,
      width: rect.width,
      height: ellipseHeight,
    );
    canvas.drawOval(bottomEllipse, tin);
    final ridge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = colors.tinShade.withValues(alpha: 0.6 * alpha);
    for (final y in [0.3, 0.5, 0.7]) {
      final ridgeRect = Rect.fromCenter(
        center: Offset(body.center.dx, body.top + body.height * y),
        width: rect.width,
        height: ellipseHeight,
      );
      canvas.drawArc(ridgeRect, 0, math.pi, false, ridge);
    }
    // The open end faces away from the string.
    final open = opensDown ? bottomEllipse : topEllipse;
    final closed = opensDown ? topEllipse : bottomEllipse;
    canvas.drawOval(
      closed,
      Paint()
        ..color = Color.lerp(
          colors.tin,
          Colors.white,
          0.3,
        )!.withValues(alpha: alpha),
    );
    canvas.drawOval(
      open,
      Paint()..color = colors.tinShade.withValues(alpha: 0.9 * alpha),
    );
    canvas.drawOval(
      open.deflate(4),
      Paint()..color = Colors.black.withValues(alpha: 0.35 * alpha),
    );
    canvas.drawCircle(
      closed.center,
      3,
      Paint()..color = colors.twine.withValues(alpha: alpha),
    );
  }

  void _paintGlow(Canvas canvas, Offset at, Color color, double fade) {
    const radius = 42.0;
    canvas.drawCircle(
      at,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.85 * fade),
            color.withValues(alpha: 0.25 * fade),
            color.withValues(alpha: 0),
          ],
          stops: const [0, 0.4, 1],
        ).createShader(Rect.fromCircle(center: at, radius: radius)),
    );
  }

  void _paintBurst(Canvas canvas, Offset at, double progress, bool still) {
    final fade = 1 - progress;
    canvas.drawCircle(
      at,
      20 + 140 * progress,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6 * fade
        ..color = colors.ownGlow.withValues(alpha: fade),
    );
    if (still) return;
    final sparks = Paint()..color = colors.partnerGlow.withValues(alpha: fade);
    for (var i = 0; i < 14; i++) {
      final angle = i * 2 * math.pi / 14;
      final distance = 30 + 120 * Curves.easeOut.transform(progress);
      canvas.drawCircle(
        at + Offset(math.cos(angle), math.sin(angle)) * distance,
        4 * fade + 1,
        sparks,
      );
    }
  }

  @override
  bool shouldRepaint(ScenePainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.frame != frame ||
      oldDelegate.labelStyle != labelStyle;
}

double distanceToPolyline(Offset point, List<Offset> points) {
  var best = double.infinity;
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    final ab = b - a;
    final length2 = ab.dx * ab.dx + ab.dy * ab.dy;
    final t = length2 == 0
        ? 0.0
        : (((point - a).dx * ab.dx + (point - a).dy * ab.dy) / length2).clamp(
            0.0,
            1.0,
          );
    final nearest = a + ab * t;
    best = math.min(best, (point - nearest).distance);
  }
  return best;
}
