// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// The host, the guest and pairing, over an in-memory network.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:libtailcat/libtailcat.dart';
import 'package:tin_can/src/line/guest.dart';
import 'package:tin_can/src/line/host.dart';
import 'package:tin_can/src/line/identity.dart';
import 'package:tin_can/src/line/line_end.dart';
import 'package:tin_can/src/line/pairing.dart';
import 'package:tin_can/src/line/path.dart';
import 'package:tin_can/src/line/session.dart';
import 'package:tin_can/src/line/telemetry.dart';
import 'package:tin_can/src/telemetry/masking.dart';

import 'support/eventually.dart';
import 'support/fake_network.dart';

Future<(HostIdentity, GuestIdentity)> pair(FakeNetwork network) async {
  final hostSide = HostPairing(
    network: network,
    telemetry: LineTelemetry(),
    myName: 'Ada',
  );
  await hostSide.start();
  final guestSide = GuestPairing(
    network: network,
    telemetry: LineTelemetry(),
    myName: 'Bea',
  );
  GuestIdentity? guestIdentity;
  unawaited(
    guestSide.start(
      hostSide.address!,
      save: (identity) async => guestIdentity = identity,
    ),
  );
  await eventually(() => hostSide.stage == PairingStage.checking);
  final hostIdentity = await hostSide.confirm(save: (_) async {});
  await eventually(() => guestSide.stage == PairingStage.paired);
  return (hostIdentity, guestIdentity!);
}

Guest newGuest(
  FakeNetwork network,
  GuestIdentity identity, {
  Duration dialTimeout = const Duration(milliseconds: 100),
}) => Guest(
  network: network,
  identity: identity,
  myName: 'Bea',
  telemetry: LineTelemetry(),
  dialTimeout: dialTimeout,
  backoff: (_) => const Duration(milliseconds: 20),
  pathMonitorFactory: (link, relay) => PathMonitor(
    link: link,
    embeddedRelay: relay,
    fastInterval: const Duration(milliseconds: 20),
    slowInterval: const Duration(milliseconds: 50),
    relayInterval: const Duration(milliseconds: 50),
  ),
);

Host newHost(FakeNetwork network, HostIdentity identity) => Host(
  network: network,
  identity: identity,
  myName: 'Ada',
  telemetry: LineTelemetry(),
);

void main() {
  group('pairing', () {
    test('both sides show the same symbols, and the string is saved', () async {
      final network = FakeNetwork();
      final hostTelemetry = LineTelemetry();
      final hostSide = HostPairing(
        network: network,
        telemetry: hostTelemetry,
        myName: 'Ada',
      );
      await hostSide.start();
      expect(hostSide.stage, PairingStage.waiting);
      expect(hostSide.allowlistOpen, isTrue);
      expect(hostSide.address, isNotNull);

      final invite = GuestPairing.findInvite(
        network,
        'Catch my Tin Can string: ${hostSide.address!.reveal()} (keep it secret)',
      );
      expect(invite, hostSide.address);
      expect(GuestPairing.findInvite(network, 'hello there'), isNull);

      final guestSide = GuestPairing(
        network: network,
        telemetry: LineTelemetry(),
        myName: 'Bea',
      );
      GuestIdentity? saved;
      final done = guestSide.start(
        invite!,
        save: (identity) async => saved = identity,
      );
      await eventually(() => hostSide.stage == PairingStage.checking);
      await eventually(() => guestSide.stage == PairingStage.checking);
      expect(hostSide.code, isNotNull);
      expect(hostSide.code, guestSide.code);
      expect(hostSide.partnerName, 'Bea');
      expect(hostSide.guestKey, guestSide.clientKey);
      expect(
        saved,
        isNull,
        reason: 'nothing is saved before the host confirms',
      );

      HostIdentity? hostSaved;
      final identity = await hostSide.confirm(
        save: (identity) async => hostSaved = identity,
      );
      await done;
      expect(hostSaved, same(identity));
      expect(hostSide.stage, PairingStage.paired);
      expect(hostSide.allowlistOpen, isFalse);
      expect(guestSide.stage, PairingStage.paired);
      expect(guestSide.partnerName, 'Ada');
      expect(identity.partnerKey, guestSide.clientKey);
      expect(identity.partnerName, 'Bea');
      expect(identity.region, isNotNull, reason: 'the region is pinned');
      expect(saved!.hostAddress, hostSide.address);
      expect(saved!.partnerName, 'Ada');
      // The pairing server is closed; the line starts its own.
      expect(network.hostAt(saved!.hostAddress), isNull);
      expect(
        hostSide.steps.map((step) => step.label).join('\n'),
        contains('restarting with the allowlist closed'),
      );
    });

    test('a second guest is turned away while the first is checked', () async {
      final network = FakeNetwork();
      final hostSide = HostPairing(
        network: network,
        telemetry: LineTelemetry(),
        myName: 'Ada',
      );
      await hostSide.start();
      final first = GuestPairing(
        network: network,
        telemetry: LineTelemetry(),
        myName: 'Bea',
      );
      unawaited(first.start(hostSide.address!, save: (_) async {}));
      await eventually(() => hostSide.stage == PairingStage.checking);

      final intruder = GuestPairing(
        network: network,
        telemetry: LineTelemetry(),
        myName: 'Eve',
      );
      await intruder.start(hostSide.address!, save: (_) async {});
      expect(intruder.stage, PairingStage.cancelled);
      expect(hostSide.partnerName, 'Bea');
      await hostSide.cancel();
    });

    test('cancelling on the host leaves the guest with nothing', () async {
      final network = FakeNetwork();
      final hostSide = HostPairing(
        network: network,
        telemetry: LineTelemetry(),
        myName: 'Ada',
      );
      await hostSide.start();
      final guestSide = GuestPairing(
        network: network,
        telemetry: LineTelemetry(),
        myName: 'Bea',
      );
      var saved = false;
      final done = guestSide.start(
        hostSide.address!,
        save: (_) async => saved = true,
      );
      await eventually(() => guestSide.stage == PairingStage.checking);
      final address = hostSide.address!;
      await hostSide.cancel();
      await done;
      expect(guestSide.stage, PairingStage.cancelled);
      expect(saved, isFalse);
      expect(
        network.hostAt(address),
        isNull,
        reason: 'the invite leads nowhere',
      );
    });

    test('a text that is not an invite fails', () async {
      final network = FakeNetwork();
      final guestSide = GuestPairing(
        network: network,
        telemetry: LineTelemetry(),
        myName: 'Bea',
      );
      await guestSide.start(
        const TailcatAddress('nonsense'),
        save: (_) async {},
      );
      expect(guestSide.stage, PairingStage.failed);
      expect(guestSide.error, isA<TailcatArgumentException>());
    });
  });

  group('the line', () {
    late FakeNetwork network;
    late HostIdentity hostIdentity;
    late GuestIdentity guestIdentity;
    late Host host;
    late Guest guest;

    setUp(() async {
      network = FakeNetwork();
      (hostIdentity, guestIdentity) = await pair(network);
      host = newHost(network, hostIdentity);
      guest = newGuest(network, guestIdentity);
      addTearDown(() async {
        await guest.stop(drain: false);
        await host.stop(drain: false);
      });
    });

    Future<(Session, Session)> connect() async {
      await host.start();
      await guest.start();
      await eventually(
        () =>
            host.status.phase == LinePhase.connected &&
            guest.status.phase == LinePhase.connected,
        reason: 'both connected',
      );
      return (host.session!, guest.session!);
    }

    test('the host restarts at the same address; the guest connects', () async {
      final (hostSession, guestSession) = await connect();
      expect(host.link!.address, guestIdentity.hostAddress);
      expect(host.link!.addressFacts.relay?.label, 'Frankfurt');
      expect(hostSession.partnerName, 'Bea');
      expect(guestSession.partnerName, 'Ada');
      // The guest's first echo reveals the UDP flow to the host.
      await eventually(() => hostSession.flow != null, reason: 'host flow');
    });

    test('touches, plucks and talk reach the other side', () async {
      final (hostSession, guestSession) = await connect();
      final hostEvents = <SessionEvent>[];
      final guestEvents = <SessionEvent>[];
      hostSession.events.listen(hostEvents.add);
      guestSession.events.listen(guestEvents.add);
      await eventually(() => hostSession.flow != null);

      guestSession.touch((x: 0.25, y: 0.75));
      await eventually(() => hostSession.partnerTip != null);
      expect(hostSession.partnerTip!.x, closeTo(0.25, 0.001));
      expect(hostSession.partnerTip!.y, closeTo(0.75, 0.001));
      guestSession.touch(null);
      await eventually(() => hostSession.partnerTip == null);

      hostSession.pluck();
      await eventually(() => guestEvents.whereType<Plucked>().isNotEmpty);

      guestSession.setTalking(true);
      await eventually(() => hostSession.partnerTalking);
      guestSession.setTalking(false);
      await eventually(() => !hostSession.partnerTalking);
      expect(hostEvents.whereType<PartnerTalking>().map((e) => e.on), [
        true,
        false,
      ]);
    });

    test('the fingertips meet once, on both sides', () async {
      final (hostSession, guestSession) = await connect();
      var hostMet = 0;
      var guestMet = 0;
      hostSession.events.listen((e) => hostMet += e is FingertipsMet ? 1 : 0);
      guestSession.events.listen((e) => guestMet += e is FingertipsMet ? 1 : 0);
      await eventually(() => hostSession.flow != null);

      // The guest holds still; the host's finger joins it.
      final keepTouching = Timer.periodic(
        const Duration(milliseconds: 30),
        (_) => guestSession.touch((x: 0.5, y: 0.5)),
      );
      addTearDown(keepTouching.cancel);
      await eventually(() => hostSession.partnerTip != null);
      hostSession.touch((x: 0.52, y: 0.51));
      await eventually(() => hostMet == 1 && guestMet == 1, reason: 'a meet');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect((hostMet, guestMet), (1, 1));
      keepTouching.cancel();
    });

    test('the guest probes the path and the host hears about it', () async {
      final (hostSession, _) = await connect();
      await eventually(() => host.telemetry.path != null, reason: 'a report');
      final heard = host.telemetry.path!;
      expect(heard.reportedByPartner, isTrue);
      expect(heard.direct, isFalse);
      expect(heard.relay?.label, 'Frankfurt');
      expect(guest.telemetry.path?.reportedByPartner, isFalse);

      network.path = const TailcatPath(
        latency: Duration(milliseconds: 12),
        endpoint: '198.51.100.4:41641',
      );
      await eventually(() => host.telemetry.path?.direct ?? false);
      expect(host.telemetry.pathChanges, 1);
      expect(host.telemetry.timeToFirstDirect, isNotNull);
      // The guest sees the endpoint, masked in its log.
      expect(guest.telemetry.path?.endpoint, '198.51.100.4:41641');
      final log = guest.telemetry.log.copyText(guest.telemetry.masking);
      expect(log, isNot(contains('198.51.100.4')));
      guest.telemetry.masking.reveal(
        const Sensitive(SensitiveKind.endpoint, '198.51.100.4:41641'),
      );
      expect(
        guest.telemetry.log.copyText(guest.telemetry.masking),
        contains('198.51.100.4'),
      );
      expect(hostSession.isOpen, isTrue);
    });

    test('echoes and pings measure both round trips', () async {
      await connect();
      await eventually(
        () =>
            guest.telemetry.datagramRtt.count > 0 &&
            host.telemetry.datagramRtt.count > 0,
        reason: 'echo replies',
        timeout: const Duration(seconds: 4),
      );
      await eventually(
        () => guest.telemetry.controlRtt.count > 0,
        reason: 'a pong',
        timeout: const Duration(seconds: 4),
      );
      expect(guest.telemetry.echo.sequence.received, greaterThan(0));
      expect(host.telemetry.timings, contains('first datagram'));
      expect(guest.telemetry.timings, contains('WebSocket connect'));
      expect(host.telemetry.timings, contains('server start'));
    });

    test(
      'a guest that hangs up leaves the host waiting; it comes back',
      () async {
        final (hostSession, _) = await connect();
        await guest.stop();
        expect(await hostSession.ended, SessionEnd.partnerHungUp);
        await eventually(() => host.status.phase == LinePhase.waiting);
        expect(guest.status.phase, LinePhase.offline);

        await guest.start();
        await eventually(
          () =>
              host.status.phase == LinePhase.connected &&
              guest.status.phase == LinePhase.connected,
        );
      },
    );

    test('a host that hangs up sends the guest back to dialing', () async {
      final (_, guestSession) = await connect();
      await host.stop();
      expect(await guestSession.ended, SessionEnd.partnerHungUp);
      await eventually(() => guest.status.phase != LinePhase.connected);
      await host.start();
      await eventually(
        () => guest.status.phase == LinePhase.connected,
        reason: 'the guest redials',
      );
    });

    test('the guest keeps dialing until the host opens the app', () async {
      await guest.start();
      await eventually(() => guest.telemetry.dialAttempts >= 2);
      expect(guest.status.phase, isNot(LinePhase.connected));
      await host.start();
      await eventually(() => guest.status.phase == LinePhase.connected);
    });

    test('cutting the string ends it on both sides', () async {
      final (hostSession, guestSession) = await connect();
      await hostSession.cut();
      expect(await guestSession.ended, SessionEnd.partnerCut);
      expect(await hostSession.ended, SessionEnd.cut);
      // The string is gone, so the guest stops dialing.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(guest.session, isNull);
    });

    test('only the paired guest gets through the allowlist', () async {
      await host.start();
      final stranger = newGuest(
        network,
        GuestIdentity(
          privateKey: network.generateKeys().privateKey,
          hostAddress: guestIdentity.hostAddress,
          partnerName: 'Ada',
          tiedAt: DateTime.now(),
        ),
      );
      addTearDown(() => stranger.stop(drain: false));
      await stranger.start();
      await eventually(() => stranger.telemetry.dialAttempts >= 2);
      expect(stranger.status.phase, isNot(LinePhase.connected));
      expect(stranger.telemetry.lastError, contains('TailcatTimeoutException'));
    });

    test('a newer WebSocket from the guest replaces the old one', () async {
      final (hostSession, _) = await connect();
      // The guest's app restarted without saying goodbye.
      final again = newGuest(network, guestIdentity);
      addTearDown(() => again.stop(drain: false));
      await again.start();
      expect(await hostSession.ended, SessionEnd.replaced);
      await eventually(() => again.status.phase == LinePhase.connected);
      expect(host.status.phase, LinePhase.connected);
    });
  });
}
