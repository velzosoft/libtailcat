// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// A capability (address or key) that must not end up in logs.
///
/// [toString] is redacted; [reveal] is the only way to get the text out.
abstract base class TailcatSecret {
  /// Wraps the text encoding [value]; [label] is the name [toString] shows.
  const TailcatSecret(String value, String label)
    : _value = value,
      _label = label;

  final String _value;
  final String _label;

  /// The secret text.
  String reveal() => _value;

  @override
  bool operator ==(Object other) =>
      other is TailcatSecret &&
      other.runtimeType == runtimeType &&
      other._value == _value;

  @override
  int get hashCode => Object.hash(runtimeType, _value);

  @override
  String toString() => '$_label(<redacted>)';
}
