// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// The line over real tunnels, on a local relay.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:libtailcat/libtailcat.dart';
import 'package:tin_can/src/line/guest.dart';
import 'package:tin_can/src/line/host.dart';
import 'package:tin_can/src/line/identity.dart';
import 'package:tin_can/src/line/line_end.dart';
import 'package:tin_can/src/line/pairing.dart';
import 'package:tin_can/src/line/session.dart';
import 'package:tin_can/src/line/tailcat_network.dart';
import 'package:tin_can/src/line/telemetry.dart';
import 'package:tin_can/src/line/transport.dart';

import 'support/local_relay.dart';

// No relay map: the addresses embed the local relay.
const network = TailcatNetwork(derpMapUrl: 'none');

Future<void> eventually(
  bool Function() check, {
  Duration timeout = const Duration(seconds: 30),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting${reason == null ? '' : ' for $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late LocalRelay relay;

  setUpAll(() async {
    if (nativeUnavailable != null) return;
    relay = await LocalRelay.start();
  });

  tearDownAll(() async {
    if (nativeUnavailable != null) return;
    await relay.stop();
  });

  /// Runs [duringPairing] while the host waits to confirm the symbols.
  Future<(HostIdentity, GuestIdentity)> pair({
    Future<void> Function(HostPairing host)? duringPairing,
  }) async {
    final hostSide = HostPairing(
      network: network,
      telemetry: LineTelemetry(),
      myName: 'Ada',
      region: relay.region,
    );
    addTearDown(hostSide.cancel);
    await hostSide.start();
    expect(hostSide.stage, PairingStage.waiting, reason: '${hostSide.error}');
    final guestSide = GuestPairing(
      network: network,
      telemetry: LineTelemetry(),
      myName: 'Bea',
    );
    addTearDown(guestSide.cancel);
    GuestIdentity? guestIdentity;
    final guestDone = guestSide.start(
      hostSide.address!,
      save: (identity) async => guestIdentity = identity,
    );
    await eventually(() => hostSide.stage == PairingStage.checking);
    await eventually(() => guestSide.stage == PairingStage.checking);
    expect(hostSide.code, guestSide.code);
    await duringPairing?.call(hostSide);
    final hostIdentity = await hostSide.confirm(save: (_) async {});
    await guestDone;
    expect(guestSide.stage, PairingStage.paired, reason: '${guestSide.error}');
    return (hostIdentity, guestIdentity!);
  }

  Host newHost(HostIdentity identity) {
    final host = Host(
      network: network,
      identity: identity,
      myName: 'Ada',
      telemetry: LineTelemetry(),
    );
    addTearDown(() => host.stop(drain: false));
    return host;
  }

  Guest newGuest(GuestIdentity identity) {
    final guest = Guest(
      network: network,
      identity: identity,
      myName: 'Bea',
      telemetry: LineTelemetry(),
      backoff: (_) => const Duration(milliseconds: 200),
    );
    addTearDown(() => guest.stop(drain: false));
    return guest;
  }

  Future<void> bothConnected(Host host, Guest guest) => eventually(
    () =>
        host.status.phase == LinePhase.connected &&
        guest.status.phase == LinePhase.connected,
    reason: 'both ends connected',
  );

  group('Tin Can over real tunnels', () {
    test('pairs, and the host comes back at the saved address', () async {
      final (hostIdentity, guestIdentity) = await pair();
      expect(hostIdentity.region, isNotNull);
      final host = newHost(hostIdentity);
      await host.start();
      expect(host.link!.address, guestIdentity.hostAddress);
      final guest = newGuest(guestIdentity);
      await guest.start();
      await bothConnected(host, guest);
      expect(host.session!.partnerName, 'Bea');
      expect(guest.session!.partnerName, 'Ada');
    });

    test(
      'a client from the pairing window is gone; a third is refused',
      () async {
        late TailcatClient stranger;
        // Closed with the stranger's client.
        // ignore: close_sinks
        late TailcatSocket strangerSocket;
        final (hostIdentity, guestIdentity) = await pair(
          duringPairing: (hostSide) async {
            // The allowlist is open during pairing.
            stranger = TailcatClient(
              TailcatClientConfig(
                address: hostSide.address!,
                derpMapUrl: 'none',
              ),
            );
            strangerSocket = await stranger.connect(port: controlPort);
          },
        );
        addTearDown(() => stranger.close(drain: false));
        // Confirming closed the pairing server and the stranger with it.
        await strangerSocket.drain<void>().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('the stranger is still connected'),
        );

        final host = newHost(hostIdentity);
        await host.start();
        final guest = newGuest(guestIdentity);
        await guest.start();
        await bothConnected(host, guest);

        for (final client in [
          stranger,
          TailcatClient(
            TailcatClientConfig(
              address: guestIdentity.hostAddress,
              derpMapUrl: 'none',
            ),
          ),
        ]) {
          addTearDown(() => client.close(drain: false));
          await expectLater(
            client.connect(
              port: controlPort,
              timeout: const Duration(seconds: 3),
            ),
            throwsA(isA<TailcatException>()),
          );
        }
        expect(host.session?.isOpen, isTrue);
      },
    );

    test('touch datagrams make the round trip', () async {
      final (hostIdentity, guestIdentity) = await pair();
      final host = newHost(hostIdentity);
      await host.start();
      final guest = newGuest(guestIdentity);
      await guest.start();
      await bothConnected(host, guest);
      final hostSession = host.session!;
      final guestSession = guest.session!;
      await eventually(() => hostSession.flow != null, reason: 'the UDP flow');

      final keepTouching = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => guestSession.touch((x: 0.3, y: 0.6)),
      );
      addTearDown(keepTouching.cancel);
      await eventually(() => hostSession.partnerTip != null);
      expect(hostSession.partnerTip!.x, closeTo(0.3, 0.001));
      keepTouching.cancel();

      hostSession.touch((x: 0.9, y: 0.1));
      await eventually(() => guestSession.partnerTip != null);
      expect(guestSession.partnerTip!.y, closeTo(0.1, 0.001));

      await eventually(() => guest.telemetry.datagramRtt.count > 0);
      await eventually(() => host.telemetry.controlRtt.count > 0);
      expect(host.telemetry.touch.sequence.received, greaterThan(0));
      await eventually(() => host.telemetry.path != null);
      expect(host.telemetry.path!.reportedByPartner, isTrue);
    });

    test('the guest reconnects after its client is closed', () async {
      final (hostIdentity, guestIdentity) = await pair();
      final host = newHost(hostIdentity);
      await host.start();
      final guest = newGuest(guestIdentity);
      await guest.start();
      await bothConnected(host, guest);
      final first = host.session!;

      await guest.stop();
      expect(await first.ended, SessionEnd.partnerHungUp);
      await eventually(() => host.status.phase == LinePhase.waiting);

      await guest.start();
      await bothConnected(host, guest);
      expect(identical(host.session, first), isFalse);
    });

    test('a restarted host is still reachable at the saved address', () async {
      final (hostIdentity, guestIdentity) = await pair();
      var host = newHost(hostIdentity);
      await host.start();
      final guest = newGuest(guestIdentity);
      await guest.start();
      await bothConnected(host, guest);

      await host.stop();
      await eventually(() => guest.status.phase != LinePhase.connected);

      host = newHost(hostIdentity);
      await host.start();
      expect(host.link!.address, guestIdentity.hostAddress);
      await bothConnected(host, guest);
    });

    test('the identities survive a round trip through JSON', () async {
      final (hostIdentity, guestIdentity) = await pair();
      final restoredHost = StringIdentity.fromJson(
        jsonDecode(jsonEncode(hostIdentity.toJson())) as Map<String, Object?>,
      ) as HostIdentity;
      final restoredGuest = StringIdentity.fromJson(
        jsonDecode(jsonEncode(guestIdentity.toJson())) as Map<String, Object?>,
      ) as GuestIdentity;
      final host = newHost(restoredHost);
      await host.start();
      expect(host.link!.address, restoredGuest.hostAddress);
      final guest = newGuest(restoredGuest);
      await guest.start();
      await bothConnected(host, guest);
    });
  }, skip: nativeUnavailable);
}
