// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';
import 'package:tin_can/src/telemetry/masking.dart';

void main() {
  const address = Sensitive(SensitiveKind.address, 'tc1secretaddress');
  const endpoint = Sensitive(SensitiveKind.endpoint, '203.0.113.7:41641');

  test('everything starts masked', () {
    final masking = Masking();
    expect(masking.isRevealed(address), isFalse);
    expect(masking.render(address), isNot(contains('secret')));
    expect(masking.render(address), '${'•' * 12} (16 chars)');
  });

  test('reveal, hide and toggle', () {
    final masking = Masking()..reveal(address);
    expect(masking.render(address), 'tc1secretaddress');
    expect(masking.isRevealed(endpoint), isFalse);
    masking.hide(address);
    expect(masking.isRevealed(address), isFalse);
    masking.toggle(address);
    expect(masking.isRevealed(address), isTrue);
    masking.toggle(address);
    expect(masking.isRevealed(address), isFalse);
  });

  test('hideAll masks everything again', () {
    final masking = Masking()
      ..reveal(address)
      ..reveal(endpoint)
      ..hideAll();
    expect(masking.isRevealed(address), isFalse);
    expect(masking.isRevealed(endpoint), isFalse);
  });

  test('values compare by kind and value', () {
    final masking = Masking()
      ..reveal(const Sensitive(SensitiveKind.address, 'x'));
    expect(
      masking.isRevealed(const Sensitive(SensitiveKind.address, 'x')),
      isTrue,
    );
    expect(
      masking.isRevealed(const Sensitive(SensitiveKind.privateKey, 'x')),
      isFalse,
    );
  });

  test('endpoints are masked by shape, not length', () {
    expect(Masking.mask(endpoint), '•••.•••.•••.•••:•••••');
    expect(
      Masking.mask(
        const Sensitive(SensitiveKind.endpoint, '[2001:db8::1]:41641'),
      ),
      '[••••]:•••••',
    );
    expect(
      Masking.mask(const Sensitive(SensitiveKind.endpoint, '2001:db8::1')),
      '[••••]',
    );
    expect(
      Masking.mask(const Sensitive(SensitiveKind.endpoint, '198.51.100.1')),
      '•••.•••.•••.•••',
    );
  });

  test('toString never contains the value', () {
    expect('$address', 'Sensitive(address, <masked>)');
    expect('$endpoint', isNot(contains('203.0')));
  });

  test('changes fire when something is revealed or masked', () async {
    final masking = Masking();
    addTearDown(masking.close);
    var count = 0;
    masking.changes.listen((_) => count++);
    masking
      ..reveal(address)
      ..reveal(address) // already revealed: no change
      ..hide(address)
      ..hideAll(); // nothing revealed: no change
    await pumpEventQueue();
    expect(count, 2);
  });
}
