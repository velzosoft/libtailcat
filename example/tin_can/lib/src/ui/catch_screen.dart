// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:libtailcat/libtailcat.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../line/pairing.dart';
import '../line/transport.dart';
import '../telemetry/masking.dart';
import 'app_controller.dart';
import 'widgets.dart';

/// The guest's pairing: scan or paste the invite, then the six symbols.
class CatchScreen extends StatefulWidget {
  const CatchScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<CatchScreen> createState() => _CatchScreenState();
}

class _CatchScreenState extends State<CatchScreen> {
  String? _error;
  bool _handled = false;

  void _use(String text) {
    if (_handled) return;
    final error = widget.controller.catchInvite(text);
    setState(() {
      _error = error;
      _handled = error == null;
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      setState(() => _error = 'The clipboard is empty.');
      return;
    }
    _use(text);
  }

  @override
  Widget build(BuildContext context) {
    final pairing = widget.controller.catching;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catch the other end'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: widget.controller.cancelPairing,
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: pairing == null
                  ? _scan(context)
                  : [..._stage(context, pairing), StepsView(pairing.steps)],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _scan(BuildContext context) {
    final theme = Theme.of(context);
    return [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Scan the QR code on the other device, or paste the invite they '
          'sent you.',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 300,
            child: MobileScanner(
              onDetect: (capture) {
                for (final barcode in capture.barcodes) {
                  final value = barcode.rawValue;
                  if (value != null) {
                    _use(value);
                    return;
                  }
                }
              },
              errorBuilder: (context, error) => ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'The camera is not available (${error.errorCode.name}). '
                      'Paste the invite instead.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Center(
        child: OutlinedButton.icon(
          icon: const Icon(Icons.content_paste),
          label: const Text('Paste invite'),
          onPressed: _paste,
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
    ];
  }

  List<Widget> _stage(BuildContext context, GuestPairing pairing) {
    final theme = Theme.of(context);
    final host = pairing.partnerName;
    switch (pairing.stage) {
      case PairingStage.starting:
        return [
          const SizedBox(height: 48),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          const Text('Dialing the other device…', textAlign: TextAlign.center),
          _inviteSection(pairing),
        ];
      case PairingStage.checking || PairingStage.confirming:
        final code = pairing.code!;
        return [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Check the knot',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
          ),
          SymbolsView(code),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'The other device shows six symbols too. When they match, the '
              'other person confirms, and the string is tied.',
              textAlign: TextAlign.center,
            ),
          ),
          const Center(child: CircularProgressIndicator()),
          DerivationView(code),
          _inviteSection(pairing),
        ];
      case PairingStage.paired:
        return [
          const SizedBox(height: 48),
          Text(
            'Tied to ${host ?? 'the other device'}.',
            textAlign: TextAlign.center,
          ),
        ];
      case PairingStage.waiting:
        return const [];
      case PairingStage.cancelled || PairingStage.failed:
        return [
          const SizedBox(height: 48),
          Icon(Icons.link_off, size: 48, color: theme.colorScheme.error),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_failure(pairing), textAlign: TextAlign.center),
          ),
          Center(
            child: FilledButton(
              onPressed: widget.controller.cancelPairing,
              child: const Text('Back'),
            ),
          ),
          _inviteSection(pairing),
        ];
    }
  }

  /// By error type, never by message text.
  static String _failure(GuestPairing pairing) => switch (pairing.error) {
    null =>
      'The other side cancelled, or someone else used the invite first. '
          'Ask for a new QR code.',
    TailcatArgumentException() => 'That is not a Tin Can invite.',
    TimeoutException() =>
      'Nobody answered. Is the QR code still on the other screen?',
    ProtocolMismatchException() =>
      'The other device runs another version of Tin Can. Update both.',
    TailcatException(:final message) => 'Network trouble: $message',
    final other => 'Could not pair: $other',
  };

  Widget _inviteSection(GuestPairing pairing) {
    final facts = pairing.inviteFacts;
    final invite = pairing.invite;
    return InfoSection(
      title: 'What the invite contains',
      children: [
        if (invite != null)
          InfoRow(
            'address',
            source: 'the invite (tap to reveal)',
            child: MaskedText(
              Sensitive(SensitiveKind.address, invite.reveal()),
              masking: widget.controller.telemetry.masking,
            ),
          ),
        InfoRow(
          'server key',
          value: facts?.publicKey,
          source: 'TailcatAddress.parse().publicKey',
        ),
        InfoRow(
          'disco key',
          value: facts?.discoPublicKey,
          source: 'TailcatAddress.parse().discoPublicKey',
        ),
        InfoRow(
          'pre-shared key',
          value: facts == null
              ? null
              : facts.hasPresharedKey
              ? 'present'
              : 'none',
          source: 'TailcatAddress.parse().hasPresharedKey',
        ),
        InfoRow(
          'relay',
          value: facts?.relay?.label,
          source: 'TailcatAddress.parse().regions',
        ),
        InfoRow(
          'your key',
          value: pairing.clientKey,
          source: 'TailcatKeys.generate().publicKey',
        ),
        InfoRow('dialing', value: 'ws://tin-can:$controlPort$pairPath'),
      ],
    );
  }
}
