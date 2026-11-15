// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';

import 'runtime/errors.dart';

/// A JSON object from the native library, with typed field access.
///
/// A missing or mistyped field throws [TailcatFailureException]. Messages
/// never quote values: some documents hold secrets.
extension type const JsonObject(Map<String, Object?> _fields) {
  /// Decodes [source], which must be a JSON object.
  factory JsonObject.decode(String source, {required String what}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw TailcatFailureException('$what: the library returned invalid JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw TailcatFailureException('$what: expected a JSON object');
    }
    return JsonObject(decoded);
  }

  /// The decoded fields.
  Map<String, Object?> get fields => _fields;

  /// The string at [key].
  String string(String key) => _require<String>(key);

  /// The string at [key], or `null` when it is absent or empty.
  String? optionalString(String key) {
    final value = _fields[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// The integer at [key].
  int integer(String key) => _require<num>(key).toInt();

  /// The number at [key].
  double number(String key) => _require<num>(key).toDouble();

  /// The boolean at [key].
  bool boolean(String key) => _require<bool>(key);

  /// The array of objects at [key]; empty when it is absent or `null`.
  List<Map<String, Object?>> objects(String key) => switch (_fields[key]) {
    null => const [],
    final List<Object?> list => [
      for (final item in list)
        if (item is Map<String, Object?>)
          item
        else
          throw TailcatFailureException(
            '"$key" holds something other than objects',
          ),
    ],
    _ => throw TailcatFailureException('"$key" is not an array'),
  };

  T _require<T extends Object>(String key) {
    final value = _fields[key];
    if (value is T) return value;
    throw TailcatFailureException(
      value == null
          ? 'the library returned no "$key"'
          : '"$key" has an unexpected type',
    );
  }
}
