// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:material_ui/material_ui.dart';

import '../line/string_state.dart';
import 'app_controller.dart';
import 'scene_painter.dart';
import 'theme.dart';

/// No string yet: your name, then tie a string or catch the other end.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  late final _name = TextEditingController(text: widget.controller.myName);

  @override
  void initState() {
    super.initState();
    final notice = widget.controller.takeNotice();
    if (notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(notice)));
        }
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _saveName() => widget.controller.setName(_name.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                SizedBox(
                  height: 220,
                  child: ExcludeSemantics(
                    child: CustomPaint(
                      painter: ScenePainter(
                        colors: TinCanColors.of(context),
                        frame: () =>
                            const SceneFrame(time: 0, state: StringState.slack),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tin Can',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.displaySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'A private line between two devices. Pair once with a QR '
                  'code; then, whenever you both have the app open, see each '
                  'other\'s fingertip, pluck the string and talk.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 40,
                  decoration: const InputDecoration(
                    labelText: 'Your name',
                    helperText: 'Sent only to your partner, through the tunnel',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _saveName(),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('Tie a string'),
                  onPressed: () async {
                    await _saveName();
                    await widget.controller.tie();
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Catch the other end'),
                  onPressed: () async {
                    await _saveName();
                    widget.controller.startCatching();
                  },
                ),
                const SizedBox(height: 24),
                Text(
                  'No account and no server of ours: the two devices talk '
                  'through a WireGuard tunnel, made with libtailcat.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
