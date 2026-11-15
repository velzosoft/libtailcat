// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../line/pairing.dart';
import '../line/safety_code.dart';
import '../telemetry/masking.dart';
import 'theme.dart';

/// A secret or real IP, masked until tapped.
class MaskedText extends StatefulWidget {
  const MaskedText(this.value, {required this.masking, super.key, this.style});

  final Sensitive value;

  final Masking masking;

  /// Monospaced by default.
  final TextStyle? style;

  @override
  State<MaskedText> createState() => _MaskedTextState();
}

class _MaskedTextState extends State<MaskedText> {
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = widget.masking.changes.listen((_) => setState(() {}));
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final revealed = widget.masking.isRevealed(widget.value);
    return Semantics(
      button: true,
      label: revealed
          ? '${widget.value.kind.name}, shown. Tap to hide.'
          : '${widget.value.kind.name}, hidden. Tap to show.',
      excludeSemantics: !revealed,
      child: InkWell(
        onTap: () => widget.masking.toggle(widget.value),
        child: Text(
          widget.masking.render(widget.value),
          style: widget.style ?? monoStyle,
        ),
      ),
    );
  }
}

/// Rebuilds every [period], for rates, ages and countdowns.
class Ticking extends StatefulWidget {
  const Ticking({
    required this.builder,
    super.key,
    this.period = const Duration(milliseconds: 500),
  });

  final WidgetBuilder builder;

  final Duration period;

  @override
  State<Ticking> createState() => _TickingState();
}

class _TickingState extends State<Ticking> {
  late final Timer _timer = Timer.periodic(
    widget.period,
    (_) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    _timer;
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class InfoSection extends StatelessWidget {
  const InfoSection({
    required this.title,
    required this.children,
    super.key,
    this.trailing,
  });

  final String title;

  final List<Widget> children;

  /// Next to the heading, such as a copy button.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 6),
        ...children,
      ],
    ),
  );
}

/// One value and its source: an API or "measured by the app".
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, {super.key, this.value, this.child, this.source});

  final String label;

  final String? value;

  /// Instead of [value], such as a [MaskedText].
  final Widget? child;

  /// Such as `TailcatClient.discoPing()`.
  final String? source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                child ?? SelectableText(value ?? '–', style: monoStyle),
                if (source != null)
                  Text(
                    source!,
                    style: theme.textTheme.labelSmall?.copyWith(color: faint),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The six symbols, with names for reading aloud and screen readers.
class SymbolsView extends StatelessWidget {
  const SymbolsView(this.code, {super.key});

  final SafetyCode code;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Safety symbols: ${code.spoken}',
    excludeSemantics: true,
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        for (final symbol in code.symbols)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(symbol.glyph, style: const TextStyle(fontSize: 44)),
              Text(symbol.name, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
      ],
    ),
  );
}

/// How the symbols were made: the digest, the 36 bits and the indices.
class DerivationView extends StatelessWidget {
  const DerivationView(this.code, {super.key});

  final SafetyCode code;

  @override
  Widget build(BuildContext context) => InfoSection(
    title: 'How the symbols are made',
    children: [
      InfoRow(
        'host key',
        value: code.hostKey,
        source: 'TailcatServer.publicKey / TailcatAddress.parse().publicKey',
      ),
      InfoRow(
        'guest key',
        value: code.guestKey,
        source: 'TailcatClient.publicKey',
      ),
      InfoRow(
        'SHA-256',
        value: code.digestHex,
        source: 'SHA-256(host key ‖ guest key)',
      ),
      InfoRow(
        'first 36 bits',
        value: [
          for (var i = 0; i < code.symbols.length; i++)
            '${code.bitGroups[i]} = ${code.symbols[i].index} ${code.symbols[i].glyph}',
        ].join('\n'),
        source: 'six bits per symbol, 64 symbols',
      ),
    ],
  );
}

/// The pairing steps with their timing.
class StepsView extends StatelessWidget {
  const StepsView(this.steps, {super.key});

  final List<PairingStep> steps;

  @override
  Widget build(BuildContext context) => InfoSection(
    title: 'Steps',
    children: [
      for (final step in steps)
        InfoRow('${step.at.inMilliseconds} ms', value: step.label),
    ],
  );
}
