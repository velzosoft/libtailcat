// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/audio/voice_engine.dart';
import 'package:tin_can/src/line/identity.dart';
import 'package:tin_can/src/line/line_end.dart';
import 'package:tin_can/src/line/pairing.dart';
import 'package:tin_can/src/store/string_store.dart';
import 'package:tin_can/src/ui/app_controller.dart';

import 'support/eventually.dart';
import 'support/fake_audio.dart';
import 'support/fake_network.dart';

AppController newApp(FakeNetwork network, {MemoryStore? memory}) =>
    AppController(
      store: StringStore(memory ?? MemoryStore()),
      network: network,
      voice: VoiceEngine(input: FakeInput(), output: FakeOutput()),
    );

Future<(AppController, AppController)> tied(FakeNetwork network) async {
  final ada = newApp(network);
  final bea = newApp(network);
  await ada.init();
  await bea.init();
  await ada.setName('Ada');
  await bea.setName('Bea');
  await ada.tie();
  expect(ada.mode, AppMode.tying);
  bea.startCatching();
  expect(bea.mode, AppMode.catching);
  expect(bea.catchInvite('not an invite'), isNotNull);
  expect(bea.catchInvite(ada.tying!.address!.reveal()), isNull);
  await eventually(() => ada.tying?.stage == PairingStage.checking);
  expect(ada.tying!.code, bea.catching!.code);
  await ada.confirmTie();
  await eventually(() => bea.mode == AppMode.line);
  expect(ada.mode, AppMode.line);
  await eventually(
    () =>
        ada.line?.status.phase == LinePhase.connected &&
        bea.line?.status.phase == LinePhase.connected,
    reason: 'the line connects after pairing',
  );
  return (ada, bea);
}

void main() {
  test('ties a string and connects', () async {
    final network = FakeNetwork();
    final (ada, bea) = await tied(network);
    expect(ada.identity?.role, Role.host);
    expect(bea.identity?.role, Role.guest);
    expect(ada.line!.partnerName, 'Bea');
    expect(bea.line!.partnerName, 'Ada');
    expect(ada.partnerPublicKey, bea.ownPublicKey);
    expect(bea.partnerPublicKey, ada.ownPublicKey);
    expect(bea.addressFacts?.relay?.label, 'Frankfurt');
  });

  test('a stored string starts the line at once', () async {
    final network = FakeNetwork();
    final memory = MemoryStore();
    final first = newApp(network, memory: memory);
    await first.init();
    await first.tie();
    final bea = newApp(network);
    await bea.init();
    bea.catchInvite(first.tying!.address!.reveal());
    await eventually(() => first.tying?.stage == PairingStage.checking);
    await first.confirmTie();
    await first.enterBackground();

    final again = newApp(network, memory: memory);
    await again.init();
    expect(again.mode, AppMode.line);
    expect(again.identity, isA<HostIdentity>());
    await eventually(() => again.line?.status.phase == LinePhase.connected);
  });

  test('cutting the string clears both ends', () async {
    final network = FakeNetwork();
    final (ada, bea) = await tied(network);
    await bea.cut();
    expect(bea.mode, AppMode.welcome);
    expect(bea.identity, isNull);
    await eventually(() => ada.mode == AppMode.welcome);
    expect(ada.identity, isNull);
    expect(ada.takeNotice(), 'Bea cut the string.');
    expect(ada.takeNotice(), isNull);
  });

  test('the background hangs up and the foreground dials again', () async {
    final network = FakeNetwork();
    final (ada, bea) = await tied(network);
    await bea.enterBackground();
    expect(bea.line!.status.phase, LinePhase.offline);
    await eventually(() => ada.line!.status.phase == LinePhase.waiting);
    await bea.enterForeground();
    await eventually(
      () =>
          ada.line!.status.phase == LinePhase.connected &&
          bea.line!.status.phase == LinePhase.connected,
    );
  });

  test('closing the app during pairing throws the keys away', () async {
    final network = FakeNetwork();
    final ada = newApp(network);
    await ada.init();
    await ada.tie();
    final address = ada.tying!.address!;
    await ada.enterBackground();
    expect(ada.mode, AppMode.welcome);
    expect(network.hostAt(address), isNull);
  });

  test('a pluck reaches the partner and plays there', () async {
    final network = FakeNetwork();
    final (ada, bea) = await tied(network);
    final plucks = <Object>[];
    bea.effects.listen(plucks.add);
    ada.pluck();
    await eventually(() => plucks.isNotEmpty);
  });
}
