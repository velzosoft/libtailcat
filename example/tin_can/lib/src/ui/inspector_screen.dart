// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:libtailcat/libtailcat.dart';
import 'package:material_ui/material_ui.dart';

import '../audio/voice_engine.dart';
import '../line/host.dart';
import '../line/identity.dart';
import '../line/telemetry.dart';
import '../line/transport.dart';
import '../telemetry/channel_stats.dart';
import '../telemetry/event_log.dart';
import '../telemetry/latency_history.dart';
import '../telemetry/masking.dart';
import '../telemetry/wire_tap.dart';
import 'app_controller.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets.dart';
import 'xray.dart';

/// Every technical detail; each value names its source (a libtailcat API or
/// the app's own measurement).
class InspectorScreen extends StatelessWidget {
  const InspectorScreen({required this.controller, super.key});

  final AppController controller;

  static const _measured = 'measured by the app';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Inspector')),
    body: Ticking(
      builder: (context) {
        final telemetry = controller.telemetry;
        return ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _path(context, telemetry),
            _latencies(context, telemetry),
            _channels(telemetry),
            _voice(controller.voice.metrics, telemetry),
            _WireSection(tap: telemetry.tap),
            _identity(telemetry.masking),
            _resources(telemetry),
            _tunnel(),
            _library(),
            _log(context, telemetry.log, telemetry.masking),
          ],
        );
      },
    ),
  );

  Widget _path(BuildContext context, LineTelemetry telemetry) {
    final path = telemetry.path;
    final relay = path?.relay ?? controller.addressFacts?.relay;
    final reported = path?.reportedByPartner ?? false
        ? 'TailcatClient.discoPing(), reported by the guest'
        : 'TailcatClient.discoPing()';
    return InfoSection(
      title: 'Path',
      children: [
        InfoRow(
          'path',
          value: path == null
              ? 'not probed yet'
              : path.direct
              ? 'direct'
              : 'relayed',
          source: reported,
        ),
        if (path?.endpoint case final endpoint?)
          InfoRow(
            'endpoint',
            source: 'TailcatPath.endpoint (the peer\'s real address; tap)',
            child: MaskedText(
              Sensitive(SensitiveKind.endpoint, endpoint),
              masking: telemetry.masking,
            ),
          ),
        InfoRow(
          'relay',
          value: relay == null
              ? null
              : '${relay.label} · code ${relay.code ?? '?'} · region '
                    '${relay.regionId ?? '?'} · ${relay.hostName ?? ''}',
          source: 'TailcatPath.derpRegionCode, TailcatAddress.parse().regions',
        ),
        InfoRow(
          'probe round trip',
          value: _history(telemetry.pathLatency),
          source: reported,
        ),
        _sparkline(context, telemetry.pathLatency),
        InfoRow(
          'relay round trip',
          value: _history(telemetry.relayLatency),
          source:
              'TailcatClient.ping() (whole milliseconds)'
              '${controller.identity?.role == Role.host ? ', reported by the guest' : ''}',
        ),
        InfoRow(
          'first direct path',
          value: telemetry.timeToFirstDirect == null
              ? 'not yet'
              : 'after ${ms(telemetry.timeToFirstDirect)}',
          source: _measured,
        ),
        InfoRow(
          'path changes',
          value: '${telemetry.pathChanges}',
          source: _measured,
        ),
      ],
    );
  }

  static String _history(LatencyHistory history) {
    if (history.count == 0) return '–';
    return 'last ${ms(history.last)} · min ${ms(history.min)} · '
        'avg ${ms(history.average)} · max ${ms(history.max)} '
        '(${history.count} in ${history.span.inSeconds} s)';
  }

  Widget _sparkline(BuildContext context, LatencyHistory history) => Padding(
    padding: const EdgeInsets.only(left: 148, top: 2, bottom: 6),
    child: SizedBox(
      height: 32,
      child: CustomPaint(
        painter: SparklinePainter(history, TinCanColors.of(context).xray),
      ),
    ),
  );

  Widget _latencies(BuildContext context, LineTelemetry telemetry) {
    final rows = [
      ('path probe', telemetry.pathLatency.last, 'discoPing()'),
      ('relay', telemetry.relayLatency.last, 'ping()'),
      ('WebSocket', telemetry.controlRtt.last, 'the app\'s ping/pong'),
      ('UDP', telemetry.datagramRtt.last, 'the app\'s echo'),
    ];
    final longest = rows
        .map((row) => row.$2?.inMicroseconds ?? 0)
        .fold(1, math.max);
    final colors = TinCanColors.of(context);
    return InfoSection(
      title: 'Latency compared',
      children: [
        for (final (label, value, source) in rows)
          InfoRow(
            label,
            source: source,
            child: Row(
              children: [
                SizedBox(width: 64, child: Text(ms(value), style: monoStyle)),
                Expanded(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: (value?.inMicroseconds ?? 0) / longest,
                    child: Container(height: 8, color: colors.xray),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _channels(LineTelemetry telemetry) => InfoSection(
    title: 'Channels (payload bytes, counted by the app)',
    children: [
      for (final channel in [
        telemetry.control,
        telemetry.touch,
        telemetry.voice,
        telemetry.echo,
      ])
        InfoRow(channel.name, value: _channel(channel), source: _measured),
    ],
  );

  static String _channel(ChannelStats channel) {
    final lines = [
      'sent ${channel.sent.totalCount} (${bytes(channel.sent.totalBytes)}), '
          '${rate(channel.sent.perSecond)}, ${kbits(channel.sent.bitsPerSecond)}',
      'received ${channel.received.totalCount} '
          '(${bytes(channel.received.totalBytes)}), '
          '${rate(channel.received.perSecond)}, '
          '${kbits(channel.received.bitsPerSecond)}',
    ];
    if (channel.sequenced) {
      final sequence = channel.sequence;
      lines.add(
        'loss ${sequence.lost} (${percent(sequence.lossRatio)}), '
        'reordered ${sequence.reordered}, duplicates ${sequence.duplicates}',
      );
    }
    if (channel.maxPayloadSize case final limit?) {
      lines.add(
        'sizes ${channel.smallest ?? '–'}–${channel.largest ?? '–'} B '
        'of at most $limit (TailcatDatagramSocket.maxPayloadSize)',
      );
    }
    return lines.join('\n');
  }

  Widget _voice(VoiceMetrics voice, LineTelemetry telemetry) {
    voice.networkRoundTrip = telemetry.datagramRtt.last;
    final buffer = voice.buffer;
    return InfoSection(
      title: 'Voice',
      children: [
        InfoRow(
          'codec',
          value:
              '${voice.codec}, ${voice.sampleRate ~/ 1000} kHz, '
              '${voice.frameSamples} samples (${ms(voice.frameDuration)}) per '
              'datagram',
        ),
        if (controller.voice.unavailable case final reason?)
          InfoRow('playback', value: reason),
        InfoRow(
          'frames',
          value: 'sent ${voice.framesSent}, received ${voice.framesReceived}',
          source: _measured,
        ),
        InfoRow(
          'jitter',
          value: ms(voice.jitter),
          source: 'interarrival jitter (RFC 3550), $_measured',
        ),
        InfoRow(
          'jitter buffer',
          value:
              '${buffer.depth} frames (${ms(buffer.depthDuration)}), '
              '${buffer.isPlaying ? 'playing' : 'filling'}; target '
              '${buffer.depthFrames} frames',
          source: _measured,
        ),
        InfoRow(
          'frames played',
          value:
              'played ${buffer.played}, late ${buffer.late}, lost '
              '${buffer.lost}, concealed ${buffer.concealed}, underruns '
              '${buffer.underruns}',
          source: _measured,
        ),
        InfoRow(
          'mouth to ear',
          value: [
            'about ${ms(voice.mouthToEar)}:',
            for (final part in voice.delayParts)
              '  ${ms(part.delay).padLeft(7)}  ${part.part}',
          ].join('\n'),
          source: 'estimated by the app from its parts',
        ),
      ],
    );
  }

  Widget _identity(Masking masking) {
    final identity = controller.identity;
    final facts = controller.addressFacts;
    final line = controller.line;
    final address = switch (identity) {
      GuestIdentity(:final hostAddress) => hostAddress,
      HostIdentity() => line is Host ? line.link?.address : null,
      null => null,
    };
    return InfoSection(
      title: 'Identity',
      children: [
        InfoRow('role', value: identity?.role.name ?? 'no string'),
        InfoRow(
          'your key',
          value: controller.ownPublicKey,
          source: identity?.role == Role.host
              ? 'TailcatServer.publicKey'
              : 'TailcatClient.publicKey',
        ),
        InfoRow(
          'partner\'s key',
          value: controller.partnerPublicKey,
          source: identity?.role == Role.host
              ? 'the guest\'s "pair" message'
              : 'TailcatAddress.parse().publicKey',
        ),
        if (address != null)
          InfoRow(
            'address',
            source: 'a TailcatSecret (tap to reveal)',
            child: MaskedText(
              Sensitive(SensitiveKind.address, address.reveal()),
              masking: masking,
            ),
          ),
        if (facts != null) ...[
          InfoRow(
            'disco key',
            value: facts.discoPublicKey,
            source: 'TailcatAddress.parse().discoPublicKey',
          ),
          InfoRow(
            'pre-shared key',
            value: facts.hasPresharedKey ? 'present' : 'none',
            source: 'TailcatAddress.parse().hasPresharedKey',
          ),
          InfoRow(
            'region',
            value:
                'id ${facts.regionId}; ${facts.regions.length} embedded'
                '${facts.relay == null ? '' : ': ${facts.relay!.label} (${facts.relay!.hostName})'}',
            source: 'TailcatAddress.parse().regionId, .regions',
          ),
        ],
        if (identity case final HostIdentity host) ...[
          InfoRow(
            'pinned region',
            value: host.region != null
                ? const JsonEncoder.withIndent('  ').convert(host.region)
                : 'region id ${host.regionId}',
            source:
                'TailcatServerConfig.region, saved when the string was tied',
          ),
          InfoRow(
            'allowlist',
            value: host.partnerKey,
            source: 'TailcatServerConfig.allowedClients',
          ),
          if (line is Host)
            InfoRow(
              'UDP idle timeout',
              value: '${line.udpIdleTimeout.inSeconds} s',
              source: 'TailcatServerConfig.udpIdleTimeout',
            ),
        ],
        if (identity case final StringIdentity tied)
          InfoRow('tied', value: tied.tiedAt.toLocal().toString()),
        InfoRow(
          'secrets',
          value:
              'kept in shared_preferences: fine for an example; a real '
              'app keeps them in the keychain or keystore',
        ),
      ],
    );
  }

  Widget _resources(LineTelemetry telemetry) {
    final resources = controller.line?.resources ?? const <OpenResource>[];
    return InfoSection(
      title: 'Resources',
      children: [
        if (resources.isEmpty) const InfoRow('open', value: 'nothing'),
        for (final resource in resources)
          InfoRow(
            resource.kind,
            value: resource.description,
            source: 'library getters',
          ),
        for (final MapEntry(key: label, value: duration)
            in telemetry.timings.entries)
          InfoRow(label, value: ms(duration), source: _measured),
      ],
    );
  }

  Widget _tunnel() => const InfoSection(
    title: 'Tunnel',
    children: [
      InfoRow(
        'encryption',
        value: 'WireGuard: Noise_IKpsk2, Curve25519, ChaCha20-Poly1305',
      ),
      InfoRow('MTU', value: '1280-byte tunnel MTU, 1232-byte datagram limit'),
      InfoRow('relays', value: 'DERP over HTTPS, when there is no direct path'),
      InfoRow(
        'NAT traversal',
        value: 'disco: probes over the relay and directly',
      ),
      InfoRow('source', value: 'documentation'),
    ],
  );

  Widget _library() {
    int? abi;
    TailcatBuildInfo? info;
    String? error;
    try {
      abi = Tailcat.abiVersion;
      info = Tailcat.buildInfo;
    } on TailcatException catch (e) {
      error = '${e.runtimeType}: ${e.message}';
    }
    final deps = switch (info?.go['Deps']) {
      final List<Object?> list => [
        for (final dep in list)
          if (dep case {
            'Path': final String path,
            'Version': final String version,
          })
            '$path $version',
      ],
      _ => const <String>[],
    };
    final settings = switch (info?.go['Settings']) {
      final List<Object?> list => [
        for (final setting in list)
          if (setting case {
            'Key': final String key,
            'Value': final String value,
          })
            '$key=$value',
      ],
      _ => const <String>[],
    };
    return InfoSection(
      title: 'Library',
      children: [
        if (error != null) InfoRow('error', value: error),
        InfoRow('C ABI', value: '${abi ?? '–'}', source: 'Tailcat.abiVersion'),
        InfoRow(
          'Go',
          value: info?.goVersion,
          source: 'Tailcat.buildInfo.goVersion',
        ),
        InfoRow(
          'modules',
          value: deps.isEmpty ? '–' : deps.join('\n'),
          source: 'Tailcat.buildInfo.go["Deps"]',
        ),
        InfoRow(
          'build settings',
          value: settings.isEmpty ? '–' : settings.join('\n'),
          source: 'Tailcat.buildInfo.go["Settings"]',
        ),
      ],
    );
  }

  Widget _log(BuildContext context, EventLog log, Masking masking) =>
      InfoSection(
        title: 'Log',
        trailing: IconButton(
          icon: const Icon(Icons.copy_all),
          tooltip: 'Copy the log (masked unless revealed)',
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: log.copyText(masking)));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Log copied, with masking')),
              );
            }
          },
        ),
        children: [
          for (final event in log.events.reversed.take(200))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(
                event.render(masking),
                style: monoStyle.copyWith(fontSize: 11),
              ),
            ),
        ],
      );
}

class _WireSection extends StatefulWidget {
  const _WireSection({required this.tap});

  final WireTap tap;

  @override
  State<_WireSection> createState() => _WireSectionState();
}

class _WireSectionState extends State<_WireSection> {
  @override
  Widget build(BuildContext context) {
    final tap = widget.tap;
    final records = tap.records.reversed.take(40).toList();
    return InfoSection(
      title: 'Wire',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('pause'),
          Switch(
            value: tap.paused,
            onChanged: (value) => setState(() => tap.paused = value),
          ),
        ],
      ),
      children: [
        if (records.isEmpty) const Text('no traffic yet'),
        for (final record in records)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '${LogEvent.formatTime(record.at)} '
              '${record.direction == WireDirection.sent ? '→' : '←'} '
              '${record.channel.padRight(10)} ${record.bytes} B  '
              '${record.summary}\n    ${record.raw ?? ''}',
              style: monoStyle.copyWith(fontSize: 10.5),
            ),
          ),
      ],
    );
  }
}
