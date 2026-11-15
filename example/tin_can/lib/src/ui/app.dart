// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'app_controller.dart';
import 'catch_screen.dart';
import 'line_screen.dart';
import 'theme.dart';
import 'tie_screen.dart';
import 'welcome_screen.dart';

class TinCanApp extends StatefulWidget {
  const TinCanApp({required this.controller, super.key});

  final AppController controller;

  @override
  State<TinCanApp> createState() => _TinCanAppState();
}

class _TinCanAppState extends State<TinCanApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
  }

  /// The line lives only in the foreground. An unfocused desktop window is
  /// only `inactive`, which keeps it up.
  void _onLifecycle(AppLifecycleState state) {
    final controller = widget.controller;
    controller.telemetry.log.info('lifecycle', state.name);
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        unawaited(controller.enterBackground());
      case AppLifecycleState.resumed:
        unawaited(controller.enterForeground());
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tin Can',
    debugShowCheckedModeBanner: false,
    theme: tinCanTheme(Brightness.light),
    darkTheme: tinCanTheme(Brightness.dark),
    home: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 250),
          child: switch (controller.mode) {
            AppMode.loading => const Scaffold(
              key: ValueKey('loading'),
              body: Center(child: CircularProgressIndicator()),
            ),
            AppMode.welcome => WelcomeScreen(
              key: const ValueKey('welcome'),
              controller: controller,
            ),
            AppMode.tying => TieScreen(
              key: const ValueKey('tie'),
              controller: controller,
            ),
            AppMode.catching => CatchScreen(
              key: const ValueKey('catch'),
              controller: controller,
            ),
            AppMode.line => LineScreen(
              key: const ValueKey('line'),
              controller: controller,
            ),
          },
        );
      },
    ),
  );
}
