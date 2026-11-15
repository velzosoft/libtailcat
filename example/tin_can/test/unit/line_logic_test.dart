// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';
import 'package:libtailcat/libtailcat.dart';
import 'package:tin_can/src/line/identity.dart';
import 'package:tin_can/src/line/line_end.dart';
import 'package:tin_can/src/line/meet.dart';
import 'package:tin_can/src/line/path.dart';
import 'package:tin_can/src/line/relays.dart';
import 'package:tin_can/src/line/string_state.dart';
import 'package:tin_can/src/store/string_store.dart';

void main() {
  group('relays', () {
    test('a public region is named by its node host name', () {
      // What a server on the public relays embeds in its address.
      final relay = Relays.fromRegion({
        'RegionID': 1,
        'RegionCode': '1',
        'RegionName': '',
        'Nodes': [
          {
            'Name': 'tc303a.ipn.dev',
            'RegionID': 1,
            'HostName': 'tc303a.ipn.dev',
          },
        ],
      });
      expect(relay.regionId, 303);
      expect(relay.code, 'fra');
      expect(relay.label, 'Frankfurt');
      expect(relay.hostName, 'tc303a.ipn.dev');
    });

    test('a region of your own is shown as it describes itself', () {
      final relay = Relays.fromRegion({
        'RegionID': 900,
        'RegionCode': 'mine',
        'RegionName': 'My relay',
        'Nodes': [
          {'Name': '900a', 'RegionID': 900, 'HostName': 'derp.example.com'},
        ],
      });
      expect(
        (relay.regionId, relay.code, relay.label),
        (900, 'mine', 'My relay'),
      );
      expect(Relays.fromRegion({'RegionCode': 'x'}).label, 'x');
    });

    test('a discoPing region code maps to a city, or falls back', () {
      expect(Relays.fromCode('tok').label, 'Tokyo');
      const embedded = RelayInfo(code: 'fra', city: 'Frankfurt');
      // The compact region in an address has code "1".
      expect(Relays.fromCode('1', embedded: embedded).label, 'Frankfurt');
      expect(Relays.fromCode('zzz').label, 'zzz');
    });
  });

  group('meet detector', () {
    Duration ms(int n) => Duration(milliseconds: n);

    test('fires once when both fingertips stay close for 250 ms', () {
      final meet = MeetDetector();
      const a = (x: 0.5, y: 0.5);
      const b = (x: 0.53, y: 0.52);
      expect(meet.update(ms(0), a, b), isFalse);
      expect(meet.isPending, isTrue);
      expect(meet.update(ms(200), a, b), isFalse);
      expect(meet.update(ms(260), a, b), isTrue);
      expect(meet.update(ms(600), a, b), isFalse, reason: 'only once');
    });

    test('needs both fingers down and close', () {
      final meet = MeetDetector();
      const a = (x: 0.1, y: 0.1);
      expect(meet.update(ms(0), a, null), isFalse);
      expect(meet.update(ms(0), a, (x: 0.5, y: 0.5)), isFalse);
      expect(meet.update(ms(500), a, (x: 0.5, y: 0.5)), isFalse);
      expect(meet.isPending, isFalse);
    });

    test('moving apart restarts the hold', () {
      final meet = MeetDetector();
      const a = (x: 0.5, y: 0.5);
      meet.update(ms(0), a, a);
      meet.update(ms(200), a, (x: 0.7, y: 0.5));
      expect(meet.update(ms(300), a, a), isFalse);
      expect(meet.update(ms(560), a, a), isTrue);
    });

    test('re-arms when the fingertips part or one lifts', () {
      final meet = MeetDetector();
      const a = (x: 0.5, y: 0.5);
      meet.update(ms(0), a, a);
      expect(meet.update(ms(300), a, a), isTrue);
      // A little apart is not enough.
      meet.update(ms(400), a, (x: 0.58, y: 0.5));
      meet.update(ms(500), a, a);
      expect(meet.update(ms(800), a, a), isFalse);
      // Far enough apart re-arms.
      meet.update(ms(900), a, (x: 0.8, y: 0.5));
      meet.update(ms(1000), a, a);
      expect(meet.update(ms(1300), a, a), isTrue);
      // So does lifting a finger.
      meet.update(ms(1400), null, a);
      meet.update(ms(1500), a, a);
      expect(meet.update(ms(1800), a, a), isTrue);
    });
  });

  group('string state', () {
    final t0 = DateTime(2026, 11, 15, 12);
    PathReport path({required bool direct}) => PathReport(
      at: t0,
      direct: direct,
      latency: const Duration(milliseconds: 30),
    );

    test('follows the line and the last path report', () {
      StringState at(LinePhase phase, {PathReport? report, int seconds = 0}) =>
          stringStateFor(
            LineStatus(phase, t0),
            path: report,
            now: t0.add(Duration(seconds: seconds)),
          );
      expect(at(LinePhase.offline), StringState.slack);
      expect(at(LinePhase.connecting), StringState.pulling);
      expect(at(LinePhase.waiting), StringState.pulling);
      expect(at(LinePhase.waiting, seconds: 25), StringState.slack);
      expect(at(LinePhase.connected), StringState.pulling);
      expect(
        at(LinePhase.connected, report: path(direct: false)),
        StringState.relayed,
      );
      expect(
        at(LinePhase.connected, report: path(direct: true)),
        StringState.direct,
      );
    });

    test('trembles more with more latency', () {
      expect(trembleFor(null), 0);
      expect(trembleFor(const Duration(milliseconds: 5)), 0);
      expect(
        trembleFor(const Duration(milliseconds: 80)),
        greaterThan(trembleFor(const Duration(milliseconds: 20))),
      );
      expect(trembleFor(const Duration(seconds: 2)), 1);
    });
  });

  test('dial backoff is 1, 2 and 4 s, then every 10 s', () {
    expect(
      [for (var i = 1; i <= 6; i++) dialBackoff(i).inSeconds],
      [1, 2, 4, 10, 10, 10],
    );
  });

  group('string store', () {
    final tiedAt = DateTime.utc(2026, 11, 15, 9, 30);

    test('keeps a host string, region pin included', () async {
      final store = StringStore(MemoryStore());
      expect(await store.load(), isNull);
      final host = HostIdentity(
        privateKey: const TailcatPrivateKey('private'),
        presharedKey: const TailcatPresharedKey('psk'),
        region: const {'RegionID': 1, 'RegionCode': '1'},
        partnerKey: 'nodekey:guest',
        partnerName: 'Bea',
        tiedAt: tiedAt,
      );
      await store.save(host);
      final loaded = await store.load() as HostIdentity;
      expect(loaded.privateKey, host.privateKey);
      expect(loaded.presharedKey, host.presharedKey);
      expect(loaded.region, host.region);
      expect(loaded.regionId, isNull);
      expect(loaded.partnerKey, 'nodekey:guest');
      expect(loaded.partnerName, 'Bea');
      expect(loaded.tiedAt, tiedAt);
      expect(loaded.role, Role.host);
    });

    test('keeps a guest string; cutting deletes it', () async {
      final store = StringStore(MemoryStore());
      await store.save(
        GuestIdentity(
          privateKey: const TailcatPrivateKey('client'),
          hostAddress: const TailcatAddress('address'),
          partnerName: 'Ada',
          tiedAt: tiedAt,
        ),
      );
      final loaded = await store.load() as GuestIdentity;
      expect(loaded.hostAddress, const TailcatAddress('address'));
      expect(loaded.withPartnerName('Ada L.').partnerName, 'Ada L.');
      await store.cut();
      expect(await store.load(), isNull);
    });

    test('a broken stored string counts as none', () async {
      final memory = MemoryStore()..values['tin_can.string.v1'] = '{"role":1}';
      expect(await StringStore(memory).load(), isNull);
      memory.values['tin_can.string.v1'] = '[]';
      expect(await StringStore(memory).load(), isNull);
    });

    test('keeps the name', () async {
      final store = StringStore(MemoryStore());
      expect(await store.loadName(), '');
      await store.saveName('Ada');
      expect(await store.loadName(), 'Ada');
    });

    test('identities never print their secrets', () {
      final guest = GuestIdentity(
        privateKey: const TailcatPrivateKey('client-secret'),
        hostAddress: const TailcatAddress('address-secret'),
        partnerName: 'Ada',
        tiedAt: tiedAt,
      );
      expect('$guest', isNot(contains('secret')));
    });
  });

  group('path reports', () {
    test('a probe says where the packets go', () {
      const embedded = RelayInfo(regionId: 303, code: 'fra', city: 'Frankfurt');
      final relayed = PathReport.fromProbe(
        const TailcatPath(
          latency: Duration(milliseconds: 84),
          derpRegionId: 1,
          derpRegionCode: '1',
        ),
        at: DateTime(2026),
        embeddedRelay: embedded,
      );
      expect(relayed.direct, isFalse);
      expect(relayed.relay?.label, 'Frankfurt');
      final message = relayed.toMessage(
        relayRtt: const Duration(milliseconds: 90),
      );
      expect(
        (message.direct, message.ms, message.relay, message.relayMs),
        (false, 84.0, 'fra', 90.0),
      );

      final direct = PathReport.fromProbe(
        const TailcatPath(
          latency: Duration(microseconds: 23456),
          endpoint: '203.0.113.7:41641',
        ),
        at: DateTime(2026),
      );
      expect(direct.direct, isTrue);
      expect(direct.toMessage().ms, 23.5);
      // The endpoint stays on this side.
      expect(direct.toMessage().encode(), isNot(contains('203.0.113.7')));

      final heard = PathReport.fromMessage(
        message,
        at: DateTime(2026),
        embeddedRelay: embedded,
      );
      expect(heard.reportedByPartner, isTrue);
      expect(heard.latency, const Duration(milliseconds: 84));
      expect(heard.relay?.label, 'Frankfurt');
    });
  });
}
