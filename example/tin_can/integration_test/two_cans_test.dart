// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Two cans in one app, driven through the UI. Uses the public relays, so
/// it's not in CI: `flutter test integration_test -d macos`.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show EditableText;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tin_can/src/audio/devices.dart';
import 'package:tin_can/src/audio/voice_engine.dart';
import 'package:tin_can/src/line/line_end.dart';
import 'package:tin_can/src/line/pairing.dart';
import 'package:tin_can/src/line/session.dart';
import 'package:tin_can/src/line/tailcat_network.dart';
import 'package:tin_can/src/store/string_store.dart';
import 'package:tin_can/src/ui/app.dart';
import 'package:tin_can/src/ui/app_controller.dart';

/// For the second can: the audio plugins are one per process.
final class _SilentInput implements AudioInput {
  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<Stream<Never>> start() async => const Stream.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

final class _SilentOutput implements AudioOutput {
  @override
  Future<void> setup({
    required int threshold,
    required void Function(int queued) onNeedMore,
  }) async {}

  @override
  void kick() {}

  @override
  Future<void> feed(Object samples) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> until(
    WidgetTester tester,
    bool Function() check, {
    Duration timeout = const Duration(seconds: 60),
    required String what,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!check()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out: $what');
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('two cans pair through the UI and talk over the tunnel', (
    tester,
  ) async {
    final ada = AppController(
      store: StringStore(MemoryStore()),
      network: const TailcatNetwork(),
      voice: VoiceEngine(input: RecordInput(), output: PcmSoundOutput()),
    );
    final bea = AppController(
      store: StringStore(MemoryStore()),
      network: const TailcatNetwork(),
      voice: VoiceEngine(input: _SilentInput(), output: _SilentOutput()),
    );
    addTearDown(() async {
      await ada.enterBackground();
      await bea.enterBackground();
    });
    await ada.init();
    await bea.init();
    await bea.setName('Bea');

    await tester.pumpWidget(TinCanApp(controller: ada));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'Ada');
    await tester.tap(find.text('Tie a string'));
    await until(
      tester,
      () => ada.tying?.stage == PairingStage.waiting,
      what: 'the pairing server',
    );
    expect(find.text('Copy invite'), findsOneWidget);

    // The other can "scans" the QR code.
    expect(bea.catchInvite(ada.tying!.address!.reveal()), isNull);
    await until(
      tester,
      () => ada.tying?.stage == PairingStage.checking,
      what: 'the guest\'s "pair"',
    );
    expect(ada.tying!.code, bea.catching!.code);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('They match'));

    await until(
      tester,
      () =>
          ada.line?.status.phase == LinePhase.connected &&
          bea.line?.status.phase == LinePhase.connected,
      what: 'the line',
    );
    expect(ada.line!.partnerName, 'Bea');
    expect(bea.line!.partnerName, 'Ada');
    await until(
      tester,
      () => ada.telemetry.path != null,
      what: 'a path report',
    );

    final plucked = Completer<void>();
    final subscription = ada.effects.listen((event) {
      if (event is Plucked && !plucked.isCompleted) plucked.complete();
    });
    addTearDown(subscription.cancel);
    final hostSession = ada.line!.session!;
    await until(tester, () {
      bea.line!.session!.touch((x: 0.4, y: 0.4));
      return hostSession.partnerTip != null;
    }, what: 'a touch datagram');
    bea.pluck();
    await until(tester, () => plucked.isCompleted, what: 'the pluck');
    expect(find.textContaining('ms'), findsWidgets);
  });
}
