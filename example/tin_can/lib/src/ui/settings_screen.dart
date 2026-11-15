// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:material_ui/material_ui.dart';

import '../line/line_end.dart';
import 'app_controller.dart';

/// Your name, and cutting the string.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _name = TextEditingController(text: widget.controller.myName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _cut() async {
    final controller = widget.controller;
    final online = controller.line?.status.phase == LinePhase.connected;
    final partner = controller.line?.partnerName ?? 'your partner';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cut the string?'),
        content: Text(
          'The keys of this string are deleted for good. '
          '${online ? '$partner is online, so their end is cut too.' : '$partner is not online; their app keeps waiting until they cut their end too.'}'
          ' To talk again, tie a new string.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cut'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    await controller.cut();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Your name',
              helperText: 'Sent only to your partner, with the next hello',
              border: OutlineInputBorder(),
            ),
            onSubmitted: widget.controller.setName,
            onEditingComplete: () => widget.controller.setName(_name.text),
          ),
          const SizedBox(height: 32),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.content_cut),
            label: const Text('Cut the string'),
            style: FilledButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            onPressed: _cut,
          ),
          const SizedBox(height: 32),
          Text(
            'Tin Can is an example for the libtailcat Dart package. The two '
            'devices talk through a WireGuard tunnel over Tailscale\'s relays '
            'and NAT traversal; there is no account and no server of ours. '
            'The keys are kept in plain app preferences, which is fine for an '
            'example: a real app keeps them in the keychain or keystore.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
