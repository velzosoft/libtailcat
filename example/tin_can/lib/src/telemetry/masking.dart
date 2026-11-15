// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

/// Values Tin Can never shows unless asked to.
enum SensitiveKind {
  /// Whoever has it can reach the host.
  address,

  privateKey,

  presharedKey,

  /// A real IP and port, from `TailcatPath.endpoint`.
  endpoint,
}

/// Like `TailcatSecret`, its [toString] never contains the value, so it's
/// safe to interpolate into a log line.
final class Sensitive {
  const Sensitive(this.kind, this.value);

  final SensitiveKind kind;

  final String value;

  @override
  bool operator ==(Object other) =>
      other is Sensitive && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'Sensitive(${kind.name}, <masked>)';
}

/// The values the user has revealed by tapping; everything starts masked.
final class Masking {
  final Set<Sensitive> _revealed = {};
  final StreamController<void> _changes = StreamController.broadcast();

  bool isRevealed(Sensitive value) => _revealed.contains(value);

  void reveal(Sensitive value) {
    if (_revealed.add(value)) _changes.add(null);
  }

  void hide(Sensitive value) {
    if (_revealed.remove(value)) _changes.add(null);
  }

  void toggle(Sensitive value) =>
      isRevealed(value) ? hide(value) : reveal(value);

  void hideAll() {
    if (_revealed.isEmpty) return;
    _revealed.clear();
    _changes.add(null);
  }

  String render(Sensitive value) =>
      isRevealed(value) ? value.value : mask(value);

  Stream<void> get changes => _changes.stream;

  Future<void> close() => _changes.close();

  /// Gives away only the kind and, for keys and addresses, the length.
  static String mask(Sensitive value) => switch (value.kind) {
    SensitiveKind.endpoint => _maskEndpoint(value.value),
    _ => '${'•' * 12} (${value.value.length} chars)',
  };

  static String _maskEndpoint(String endpoint) {
    if (endpoint.startsWith('[')) {
      return endpoint.contains(']:') ? '[••••]:•••••' : '[••••]';
    }
    final colons = ':'.allMatches(endpoint).length;
    if (colons > 1) return '[••••]'; // a bare IPv6 address
    return colons == 1 ? '•••.•••.•••.•••:•••••' : '•••.•••.•••.•••';
  }
}
