// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/telemetry/event_log.dart';
import 'package:tin_can/src/telemetry/masking.dart';

void main() {
  final now = DateTime(2026, 11, 15, 9, 5, 7, 42);
  DateTime clock() => now;
  const address = Sensitive(SensitiveKind.address, 'tc1secretaddress');
  const endpoint = Sensitive(SensitiveKind.endpoint, '203.0.113.7:41641');

  test('renders time, category and text', () {
    final log = EventLog(clock: clock)..info('server', 'started in 412 ms');
    expect(
      log.events.single.render(Masking()),
      '09:05:07.042 server  started in 412 ms',
    );
  });

  test('keeps only the last events', () {
    final log = EventLog(capacity: 3, clock: clock);
    for (var i = 0; i < 5; i++) {
      log.info('n', '$i');
    }
    expect(log.events.map((e) => e.parts.single), ['2', '3', '4']);
  });

  test('a copied log stays masked unless the values were revealed', () {
    final masking = Masking();
    final log = EventLog(clock: clock)
      ..add('pair', ['invite ', address, ' parsed'])
      ..add('path', ['direct via ', endpoint]);

    final masked = log.copyText(masking);
    expect(masked, isNot(contains('tc1secretaddress')));
    expect(masked, isNot(contains('203.0.113.7')));
    expect(masked.split('\n'), [
      '09:05:07.042 pair  invite ${Masking.mask(address)} parsed',
      '09:05:07.042 path  direct via •••.•••.•••.•••:•••••',
    ]);

    masking.reveal(endpoint);
    final partly = log.copyText(masking);
    expect(partly, contains('direct via 203.0.113.7:41641'));
    expect(partly, isNot(contains('tc1secretaddress')));
  });

  test('rejects parts that are neither text nor Sensitive', () {
    final log = EventLog(clock: clock);
    expect(() => log.add('x', ['ok', 42]), throwsArgumentError);
    expect(log.events, isEmpty);
  });

  test('announces new events', () async {
    final log = EventLog(clock: clock);
    addTearDown(log.close);
    final next = log.onEvent.first;
    log.info('ws', 'upgraded');
    expect((await next).category, 'ws');
  });

  test('clear forgets the events', () {
    final log = EventLog(clock: clock)
      ..info('a', 'b')
      ..clear();
    expect(log.events, isEmpty);
    expect(log.copyText(Masking()), '');
  });
}
