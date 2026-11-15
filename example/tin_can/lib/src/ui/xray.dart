// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../line/host.dart';
import '../line/identity.dart';
import '../line/line_end.dart';
import '../telemetry/channel_stats.dart';
import '../telemetry/latency_history.dart';
import '../telemetry/masking.dart';
import 'app_controller.dart';
import 'format.dart';
import 'scene_painter.dart';
import 'theme.dart';
import 'widgets.dart';

/// Notes over the line showing what happens underneath; each names its
/// source.
class XrayOverlay extends StatelessWidget {
  const XrayOverlay({
    required this.controller,
    required this.layout,
    super.key,
  });

  final AppController controller;

  final SceneLayout layout;

  @override
  Widget build(BuildContext context) {
    final colors = TinCanColors.of(context);
    final style = monoStyle.copyWith(fontSize: 10.5, color: colors.xray);
    final faint = style.copyWith(color: colors.xray.withValues(alpha: 0.7));
    return Ticking(
      period: const Duration(milliseconds: 250),
      builder: (context) {
        final line = controller.line;
        final session = line?.session;
        final status = line?.status;
        final connected = status?.phase == LinePhase.connected;
        final role = controller.identity?.role;
        final noteWidth = math.max(
          120.0,
          layout.size.width / 2 - layout.canSize.width / 2 - 16,
        );
        final tip = session?.partnerTip;
        final touch = session?.partnerTouch;
        return Stack(
          children: [
            // The partner's can.
            Positioned(
              left: layout.partnerCan.right + 8,
              top: layout.partnerCan.top,
              width: noteWidth,
              child: IgnorePointer(
                child: Text(
                  [
                    role == Role.host ? 'guest' : 'host',
                    shortKey(controller.partnerPublicKey),
                    if (session?.flow case final flow?)
                      'UDP ${flow.remoteEndpoint}',
                  ].join('\n'),
                  style: style,
                ),
              ),
            ),
            // This side's can.
            Positioned(
              left: layout.ownCan.right + 8,
              top: layout.ownCan.top,
              width: noteWidth,
              child: IgnorePointer(
                child: Text(
                  [
                    'you · ${role?.name ?? '–'}',
                    shortKey(controller.ownPublicKey),
                    if (session?.flow case final flow?)
                      'UDP ${flow.localEndpoint}'
                    else if (line is Host && line.link != null)
                      'tunnel ${line.link!.tunnelAddress}',
                  ].join('\n'),
                  style: style,
                ),
              ),
            ),
            // The string.
            Positioned(
              left: 8,
              top: (layout.top.dy + layout.bottom.dy) / 2 - 40,
              width: layout.size.width / 2 - 24,
              child: connected
                  ? _pathNote(style, faint, role)
                  : IgnorePointer(child: _waitingNote(style, faint, line)),
            ),
            // The partner's fingertip.
            if (tip != null && touch != null)
              Positioned(
                left: (tip.x * layout.size.width + 28).clamp(
                  0,
                  layout.size.width - 120,
                ),
                top: (tip.y * layout.size.height - 30).clamp(
                  0,
                  layout.size.height - 20,
                ),
                child: IgnorePointer(
                  child: Text(
                    'seq ${touch.seq} · ${session!.partnerTouchAge?.inMilliseconds ?? '–'} ms ago',
                    style: style,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _pathNote(TextStyle style, TextStyle faint, Role? role) {
    final telemetry = controller.telemetry;
    final path = telemetry.path;
    if (path == null) {
      return Text('probing the path…\nTailcatClient.discoPing()', style: style);
    }
    final first = telemetry.timeToFirstDirect;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (path.direct)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'DIRECT ',
                style: style.copyWith(fontWeight: FontWeight.bold),
              ),
              if (path.endpoint case final endpoint?)
                Flexible(
                  child: MaskedText(
                    Sensitive(SensitiveKind.endpoint, endpoint),
                    masking: telemetry.masking,
                    style: style,
                  ),
                ),
            ],
          )
        else
          Text(
            'RELAY ${path.relay?.code ?? path.relayCode ?? '?'} · '
            '${path.relay?.label ?? ''}',
            style: style.copyWith(fontWeight: FontWeight.bold),
          ),
        Text('discoPing ${ms(path.latency)}', style: style),
        SizedBox(
          height: 22,
          width: 120,
          child: CustomPaint(
            painter: SparklinePainter(telemetry.pathLatency, style.color!),
          ),
        ),
        if (first != null)
          Text('first direct after ${ms(first)}', style: style),
        Text(
          'TailcatClient.discoPing()'
          '${role == Role.host ? '\nreported by the guest' : ''}',
          style: faint,
        ),
      ],
    );
  }

  Widget _waitingNote(TextStyle style, TextStyle faint, LineEnd? line) {
    final telemetry = controller.telemetry;
    final lines = <String>[
      if (line is Host) ...[
        'server ${telemetry.timings['server start'] == null ? 'starting' : 'up in ${ms(telemetry.timings['server start'])}'}',
        'listening on TCP 80 and UDP 5000',
        'waiting for the guest to dial',
      ] else ...[
        'dial attempt ${telemetry.dialAttempts}',
        ?nextAttempt(telemetry, DateTime.now()),
      ],
      ?telemetry.lastError,
    ];
    return Text(lines.join('\n'), style: style);
  }
}

/// One chip per channel, and the last three log events.
class XrayFooter extends StatelessWidget {
  const XrayFooter({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final colors = TinCanColors.of(context);
    final style = monoStyle.copyWith(fontSize: 10, color: colors.xray);
    final faint = style.copyWith(color: colors.xray.withValues(alpha: 0.7));
    return Ticking(
      period: const Duration(milliseconds: 250),
      builder: (context) {
        final telemetry = controller.telemetry;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final channel in [
                    telemetry.control,
                    telemetry.touch,
                    telemetry.voice,
                    telemetry.echo,
                  ])
                    _ChannelChip(channel, style: style),
                ],
              ),
              const SizedBox(height: 4),
              for (final event
                  in telemetry.log.events.reversed.take(3).toList().reversed)
                Text(
                  event.render(telemetry.masking),
                  style: faint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ChannelChip extends StatelessWidget {
  const _ChannelChip(this.channel, {required this.style});

  final ChannelStats channel;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final colors = TinCanColors.of(context);
    final bits = channel.sent.bitsPerSecond + channel.received.bitsPerSecond;
    final name = channel.name == 'WebSocket' ? 'ws' : channel.name;
    final text = StringBuffer(
      '$name ↑${channel.sent.perSecond.toStringAsFixed(1)} '
      '↓${rate(channel.received.perSecond)} ${kbits(bits)}',
    );
    if (channel.sequenced && channel.sequence.expected > 0) {
      text.write(' loss ${percent(channel.sequence.lossRatio)}');
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.backdrop.withValues(alpha: 0.75),
        border: Border.all(color: colors.xray.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text.toString(), style: style),
    );
  }
}

class SparklinePainter extends CustomPainter {
  SparklinePainter(this.history, this.color);

  final LatencyHistory history;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final samples = history.samples;
    if (samples.length < 2) return;
    // Evenly spaced, newest on the right.
    final top = samples
        .map((sample) => sample.latency.inMicroseconds)
        .reduce(math.max)
        .clamp(1, 1 << 40);
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = size.width * i / (samples.length - 1);
      final y =
          size.height * (1 - samples[i].latency.inMicroseconds / top) * 0.9 +
          size.height * 0.05;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(SparklinePainter oldDelegate) => true;
}
