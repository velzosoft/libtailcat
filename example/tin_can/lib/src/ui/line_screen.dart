// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../line/identity.dart';
import '../line/line_end.dart';
import '../line/meet.dart';
import '../line/session.dart';
import '../line/string_state.dart';
import 'app_controller.dart';
import 'format.dart';
import 'inspector_screen.dart';
import 'scene_painter.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'widgets.dart';
import 'xray.dart';

/// A full-screen touch canvas: the partner's can at the top, yours at the
/// bottom (hold to talk), the string between.
class LineScreen extends StatefulWidget {
  const LineScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<LineScreen> createState() => _LineScreenState();
}

class _LineScreenState extends State<LineScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final _repaint = ValueNotifier<int>(0);
  StreamSubscription<SessionEvent>? _effects;
  Duration _elapsed = Duration.zero;
  Size _canvas = Size.zero;
  bool _xray = true;

  int? _touchPointer;
  Offset? _touchStart;
  Duration? _touchStartAt;
  bool _moved = false;
  Fingertip? _ownTip;
  int? _talkPointer;

  double _pluckAt = -100;
  double _snapAt = -100;
  double _burstAt = -100;
  Fingertip? _burstWhere;
  bool _wasDirect = false;

  AppController get _controller => widget.controller;

  double get _time => _elapsed.inMicroseconds / 1e6;

  @override
  void initState() {
    super.initState();
    unawaited(_ticker.start());
    _effects = _controller.effects.listen(_onEffect);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    unawaited(_effects?.cancel());
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    _repaint.value++;
  }

  void _onEffect(SessionEvent event) {
    switch (event) {
      case Plucked():
        unawaited(HapticFeedback.mediumImpact());
        _pluckAt = _time;
      case FingertipsMet():
        unawaited(HapticFeedback.heavyImpact());
        final session = _controller.line?.session;
        final a = _ownTip ?? session?.localTip;
        final b = session?.partnerTip;
        _burstWhere = a != null && b != null
            ? (x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            : (a ?? b ?? (x: 0.5, y: 0.5));
        _burstAt = _time;
      case PathReported(:final report):
        if (report.direct && !_wasDirect) {
          // Went direct: the string snaps straight with a twang.
          unawaited(HapticFeedback.lightImpact());
          _controller.voice.pluck();
          _snapAt = _time;
        }
        _wasDirect = report.direct;
      case SessionEnded():
        _wasDirect = false;
      case PartnerTouched() || PartnerTalking() || VoiceArrived():
        break;
    }
  }

  SceneFrame _frame() {
    final line = _controller.line;
    final session = line?.session;
    final status =
        line?.status ?? LineStatus(LinePhase.offline, DateTime.now());
    final connected = status.phase == LinePhase.connected;
    final path = connected ? _controller.telemetry.path : null;
    final state = stringStateFor(status, path: path, now: DateTime.now());
    final age = session?.partnerTouchAge;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return SceneFrame(
      time: _time,
      state: state,
      tremble: reduceMotion ? 0 : trembleFor(path?.latency),
      pluck: reduceMotion ? 0 : math.max(0, 1 - (_time - _pluckAt) / 1.4),
      snap: reduceMotion ? 0 : math.max(0, 1 - (_time - _snapAt) / 0.6),
      relayLabel: path?.relay?.label,
      partnerTip: session?.partnerTip,
      partnerTipFade: age == null
          ? 0
          : (1 - age.inMilliseconds / session!.touchTimeout.inMilliseconds)
                .clamp(0.0, 1.0),
      ownTip: _ownTip,
      burstAt: _burstWhere,
      burst: (_time - _burstAt) / 0.7,
      talking: _controller.talking,
      partnerTalking: session?.partnerTalking ?? false,
      reduceMotion: reduceMotion,
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    final layout = SceneLayout(_canvas);
    if (_talkPointer == null &&
        layout.ownCan.inflate(16).contains(event.localPosition)) {
      _talkPointer = event.pointer;
      unawaited(_startTalking());
      return;
    }
    if (_touchPointer != null) return;
    _touchPointer = event.pointer;
    _touchStart = event.localPosition;
    _touchStartAt = _elapsed;
    _moved = false;
    _touch(event.localPosition);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _touchPointer) return;
    if ((event.localPosition - _touchStart!).distance > 12) _moved = true;
    _touch(event.localPosition);
  }

  void _onPointerUp(PointerEvent event) {
    if (event.pointer == _talkPointer) {
      _talkPointer = null;
      unawaited(_controller.stopTalking());
      return;
    }
    if (event.pointer != _touchPointer) return;
    _touchPointer = null;
    final quick =
        !_moved &&
        _elapsed - (_touchStartAt ?? _elapsed) <
            const Duration(milliseconds: 350);
    if (quick && event is PointerUpEvent) {
      final points = ScenePainter.stringPoints(SceneLayout(_canvas), _frame());
      if (distanceToPolyline(event.localPosition, points) < 32) _pluck();
    }
    _ownTip = null;
    _controller.line?.session?.touch(null);
  }

  void _touch(Offset position) {
    final tip = SceneLayout(_canvas).toNormal(position);
    _ownTip = tip;
    _controller.line?.session?.touch(tip);
  }

  void _pluck() {
    unawaited(HapticFeedback.selectionClick());
    _controller.pluck();
    _pluckAt = _time;
  }

  Future<void> _startTalking() async {
    final started = await _controller.startTalking();
    if (!started && mounted) {
      _talkPointer = null;
      final reason = _controller.line?.session == null
          ? 'Talking works once you are connected.'
          : 'Tin Can needs the microphone to talk.';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(reason)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = TinCanColors.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final line = _controller.line;
        final status =
            line?.status ?? LineStatus(LinePhase.offline, DateTime.now());
        final partner = line?.partnerName ?? '';
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _canvas = constraints.biggest;
                      final layout = SceneLayout(_canvas);
                      return Stack(
                        children: [
                          Positioned.fill(
                            child: Semantics(
                              label: _describe(status),
                              hint:
                                  'Touch anywhere to show your fingertip. Tap the '
                                  'string to pluck it.',
                              customSemanticsActions: {
                                const CustomSemanticsAction(
                                  label: 'Pluck the string',
                                ): _pluck,
                              },
                              child: Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerDown: _onPointerDown,
                                onPointerMove: _onPointerMove,
                                onPointerUp: _onPointerUp,
                                onPointerCancel: _onPointerUp,
                                child: CustomPaint(
                                  painter: ScenePainter(
                                    frame: _frame,
                                    colors: colors,
                                    labelStyle:
                                        theme.textTheme.labelLarge ??
                                        const TextStyle(fontSize: 13),
                                    repaint: _repaint,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Partner's name.
                          Positioned(
                            left: 0,
                            right: 0,
                            top: math.max(0, layout.partnerCan.top - 28),
                            child: IgnorePointer(
                              child: Text(
                                partner.isEmpty ? 'your partner' : partner,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                          ),
                          // Status line.
                          Positioned(
                            left: 16,
                            right: 16,
                            top: layout.ownCan.top - 56,
                            child: IgnorePointer(
                              child: Ticking(
                                period: const Duration(milliseconds: 250),
                                builder: (context) => Column(
                                  children: [
                                    DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: colors.backdrop.withValues(
                                          alpha: 0.85,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 2,
                                        ),
                                        child: Text(
                                          statusLine(
                                            status,
                                            _controller.telemetry.path,
                                            partner,
                                          ),
                                          textAlign: TextAlign.center,
                                          style: theme.textTheme.titleSmall,
                                        ),
                                      ),
                                    ),
                                    if (status.phase != LinePhase.connected)
                                      Text(
                                        'There is no server to ring their phone: '
                                        'the line is live while both apps are open.',
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          // Your can.
                          Positioned(
                            left: 0,
                            right: 0,
                            top: layout.ownCan.bottom + 6,
                            child: Semantics(
                              button: true,
                              label: _controller.talking
                                  ? 'Your can. Talking. Tap to stop.'
                                  : 'Your can. Hold to talk.',
                              onTap: () => _controller.talking
                                  ? _controller.stopTalking()
                                  : _controller.startTalking(),
                              child: IgnorePointer(
                                child: Text(
                                  _controller.talking
                                      ? 'talking…'
                                      : 'hold your can to talk',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ),
                          ),
                          if (_xray)
                            XrayOverlay(
                              controller: _controller,
                              layout: layout,
                            ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: _TopButtons(
                              xray: _xray,
                              onXray: () => setState(() => _xray = !_xray),
                              onInspector: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      InspectorScreen(controller: _controller),
                                ),
                              ),
                              onSettings: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      SettingsScreen(controller: _controller),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                if (_xray) XrayFooter(controller: _controller),
              ],
            ),
          ),
        );
      },
    );
  }

  /// For screen readers.
  String _describe(LineStatus status) {
    final path = status.phase == LinePhase.connected
        ? _controller.telemetry.path
        : null;
    final state = stringStateFor(status, path: path, now: DateTime.now());
    final role = _controller.identity?.role == Role.host ? 'host' : 'guest';
    return switch (state) {
      StringState.slack => 'The string is slack: your partner is not online.',
      StringState.pulling => 'The string is pulling: connecting.',
      StringState.relayed =>
        'The string bends over the ${path?.relay?.label ?? ''} relay, '
            '${ms(path?.latency)}. You are the $role.',
      StringState.direct =>
        'The string is straight: a direct connection, ${ms(path?.latency)}. '
            'You are the $role.',
    };
  }
}

class _TopButtons extends StatelessWidget {
  const _TopButtons({
    required this.xray,
    required this.onXray,
    required this.onInspector,
    required this.onSettings,
  });

  final bool xray;
  final VoidCallback onXray;
  final VoidCallback onInspector;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        icon: Icon(xray ? Icons.layers : Icons.layers_clear),
        tooltip: xray ? 'Hide the X-ray' : 'Show the X-ray',
        onPressed: onXray,
      ),
      IconButton(
        icon: const Icon(Icons.troubleshoot),
        tooltip: 'Inspector',
        onPressed: onInspector,
      ),
      IconButton(
        icon: const Icon(Icons.settings_outlined),
        tooltip: 'Settings',
        onPressed: onSettings,
      ),
    ],
  );
}
