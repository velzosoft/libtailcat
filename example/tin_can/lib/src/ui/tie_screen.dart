// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../line/pairing.dart';
import '../line/transport.dart';
import '../telemetry/masking.dart';
import 'app_controller.dart';
import 'widgets.dart';

/// The host's pairing: the QR code, then the six symbols.
class TieScreen extends StatelessWidget {
  const TieScreen({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final pairing = controller.tying;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tie a string'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: controller.cancelPairing,
        ),
      ),
      body: pairing == null
          ? const SizedBox()
          : SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      ..._stage(context, pairing),
                      StepsView(pairing.steps),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  List<Widget> _stage(BuildContext context, HostPairing pairing) {
    final theme = Theme.of(context);
    final masking = controller.telemetry.masking;
    switch (pairing.stage) {
      case PairingStage.starting || PairingStage.confirming:
        return [
          const SizedBox(height: 48),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Text(
            pairing.stage == PairingStage.starting
                ? 'Starting a server on the nearest relay…'
                : 'Tying the knot…',
            textAlign: TextAlign.center,
          ),
        ];
      case PairingStage.failed || PairingStage.cancelled:
        return [
          const SizedBox(height: 48),
          Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          Text(
            'Could not start: ${pairing.error ?? 'cancelled'}',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Center(
            child: FilledButton(
              onPressed: controller.cancelPairing,
              child: const Text('Back'),
            ),
          ),
        ];
      case PairingStage.waiting:
        final address = pairing.address!;
        return [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'On the other device, tap "Catch the other end" and scan this '
              'code.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
          Center(
            child: Semantics(
              label: 'QR code of the invite',
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(
                  data: address.reveal(),
                  size: 260,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy invite'),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text:
                        'Catch my Tin Can string (keep this private): '
                        '${address.reveal()}',
                  ),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invite copied')),
                  );
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              'The invite is a secret until you have checked the symbols: '
              'whoever uses it first catches the string. Send it only to '
              'the person you mean.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
          _addressSection(pairing, masking),
        ];
      case PairingStage.checking:
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
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Does ${_name(pairing.partnerName)} see the same six symbols? '
              'If they don\'t, someone else used the invite: cancel.',
              textAlign: TextAlign.center,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: controller.cancelPairing,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: controller.confirmTie,
                child: const Text('They match'),
              ),
            ],
          ),
          DerivationView(code),
          _addressSection(pairing, masking),
        ];
      case PairingStage.paired:
        return const [];
    }
  }

  static String _name(String? name) =>
      name == null || name.isEmpty ? 'the other person' : name;

  Widget _addressSection(HostPairing pairing, Masking masking) {
    final facts = pairing.addressFacts;
    final relay = facts?.relay;
    return InfoSection(
      title: 'What the address contains',
      children: [
        InfoRow(
          'address',
          source: 'TailcatServer.address (tap to reveal)',
          child: MaskedText(
            Sensitive(SensitiveKind.address, pairing.address!.reveal()),
            masking: masking,
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
              ? 'present (the key itself is never shown)'
              : 'none',
          source: 'TailcatAddress.parse().hasPresharedKey',
        ),
        InfoRow(
          'relay',
          value: relay == null
              ? 'region id ${facts?.regionId}'
              : '${relay.label} (${relay.hostName ?? relay.code}), '
                    'embedded; region id ${facts?.regionId}',
          source: 'TailcatAddress.parse().regions',
        ),
        InfoRow(
          'tunnel address',
          value: pairing.tunnelAddress,
          source: 'TailcatServer.localAddress',
        ),
        InfoRow(
          'allowlist',
          value: pairing.allowlistOpen
              ? 'open: anyone with the address may connect'
              : 'closed',
          source: 'TailcatServerConfig.allowedClients',
        ),
        InfoRow(
          'serving',
          value: 'HTTP on TCP $controlPort, WebSocket $pairPath',
        ),
      ],
    );
  }
}
