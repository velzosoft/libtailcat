// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

@Tags(['native'])
library;

import 'dart:io';

import 'package:libtailcat/libtailcat.dart';
import 'package:libtailcat/src/bindings/native_api.dart' as native;
import 'package:libtailcat/src/runtime/token.dart';
import 'package:test/test.dart';

import '../support/native.dart';

// Calls that never touch the network.
void main() {
  test('the bundled library speaks the supported ABI', () {
    expect(Tailcat.abiVersion, 1);
    final info = Tailcat.buildInfo;
    expect(info.abiVersion, 1);
    expect(info.goVersion, startsWith('go1.'));
    expect(info.go, containsPair('Path', contains('libtailcat')));
  }, skip: nativeUnavailable);

  group('TailcatKeys.generate', () {
    test('returns a distinct identity each time', () {
      final first = TailcatKeys.generate();
      final second = TailcatKeys.generate();
      expect(first.publicKey, startsWith('nodekey:'));
      expect(first.privateKey.reveal(), startsWith('privkey:'));
      expect(first.presharedKey.reveal(), isNotEmpty);
      expect(first.publicKey, isNot(second.publicKey));
      expect(first.privateKey, isNot(second.privateKey));
    });
  }, skip: nativeUnavailable);

  group('a malformed input is a TailcatArgumentException', () {
    test('address', () {
      expect(
        () => const TailcatAddress('not an address').parse(),
        throwsA(isA<TailcatArgumentException>()),
      );
      expect(
        () => TailcatClient(
          const TailcatClientConfig(address: TailcatAddress('not an address')),
        ),
        throwsA(isA<TailcatArgumentException>()),
      );
    });

    test('server keys', () async {
      await expectLater(
        TailcatServer.start(
          const TailcatServerConfig(privateKey: TailcatPrivateKey('nope')),
        ),
        throwsA(isA<TailcatArgumentException>()),
      );
      await expectLater(
        TailcatServer.start(
          const TailcatServerConfig(presharedKey: TailcatPresharedKey('nope')),
        ),
        throwsA(isA<TailcatArgumentException>()),
      );
      await expectLater(
        TailcatServer.start(
          const TailcatServerConfig(allowedClients: ['nodekey:zz']),
        ),
        throwsA(isA<TailcatArgumentException>()),
      );
    });

    test('never quotes the secret it rejects', () {
      const secret = 'privkey:0123456789abcdef-not-a-real-key';
      expect(
        () => TailcatClient(
          const TailcatClientConfig(
            address: TailcatAddress('tcsecretsecretsecret'),
            privateKey: TailcatPrivateKey(secret),
          ),
        ),
        throwsA(
          isA<TailcatException>().having(
            (e) => e.toString(),
            'text',
            allOf(isNot(contains(secret)), isNot(contains('tcsecret'))),
          ),
        ),
      );
    });
  }, skip: nativeUnavailable);

  group('a sliced token', () {
    late CancelSlot slot;
    late SlicedToken token;

    setUp(() {
      slot = CancelSlot.allocate();
      token = SlicedToken(slot);
      addTearDown(() {
        token.dispose();
        slot.free();
      });
    });

    // Go's clock on Windows can expire the slice a tick before ours.
    test('takes a timeout just short of the slice as the slice', () {
      final status = token.run((_) {
        sleep(sliceDuration - nativeClockSlack ~/ 2);
        return native.TC_TIMEOUT;
      });
      expect(status, sliceElapsed);
    });

    test('keeps an early timeout the library raised itself', () {
      expect(token.run((_) => native.TC_TIMEOUT), native.TC_TIMEOUT);
    });
  }, skip: nativeUnavailable);
}
