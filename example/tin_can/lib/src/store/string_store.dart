// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../line/identity.dart';

abstract interface class KeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// **Example only:** preferences are unencrypted and end up in backups. A real
/// app keeps keys and addresses in the keychain/keystore, for example with
/// `flutter_secure_storage`.
final class PreferencesStore implements KeyValueStore {
  final _preferences = SharedPreferencesAsync();

  @override
  Future<String?> read(String key) => _preferences.getString(key);

  @override
  Future<void> write(String key, String value) =>
      _preferences.setString(key, value);

  @override
  Future<void> delete(String key) => _preferences.remove(key);
}

/// For tests.
final class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

final class StringStore {
  StringStore(this._store);

  static const _stringKey = 'tin_can.string.v1';
  static const _nameKey = 'tin_can.name';

  final KeyValueStore _store;

  /// A stored string that can't be read counts as none.
  Future<StringIdentity?> load() async {
    final text = await _store.read(_stringKey);
    if (text == null) return null;
    try {
      return StringIdentity.fromJson(jsonDecode(text) as Map<String, Object?>);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> save(StringIdentity identity) =>
      _store.write(_stringKey, jsonEncode(identity.toJson()));

  /// Its keys are gone for good.
  Future<void> cut() => _store.delete(_stringKey);

  Future<String> loadName() async => await _store.read(_nameKey) ?? '';

  Future<void> saveName(String name) => _store.write(_nameKey, name);
}
