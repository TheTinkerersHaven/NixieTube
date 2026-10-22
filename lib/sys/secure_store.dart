// Where credentials live.
//
// The YouTube cookie, the session token and the Last.fm secrets used
// to sit in a plain-text `auth.properties` next to the app settings.
// They now live in the platform's secret store (libsecret's keyring on
// Linux, the Keychain elsewhere), which keeps them out of the user's
// home directory and away from anything that can read a text file.
//
// The old file is migrated once, on the first start after the change,
// and deleted once its contents are in the store.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A key-value store for secrets.
abstract class SecureStore {
  /// The platform secret store.
  const factory SecureStore.platform() = PlatformSecureStore;

  /// An in-memory store.
  ///
  /// Sandboxes that must not touch the real keyring (tests, throwaway
  /// profiles) use this instead.
  factory SecureStore.memory() = MemorySecureStore;

  /// The value stored under [key], or null when there is none.
  Future<String?> read(String key);

  /// Stores [value] under [key].
  Future<void> write(String key, String value);

  /// Drops the value stored under [key].
  Future<void> delete(String key);

  /// Every stored value, keyed by its key.
  Future<Map<String, String>> readAll();
}

/// The platform secret store.
class PlatformSecureStore implements SecureStore {
  const PlatformSecureStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}

/// A store that keeps everything in memory, for sandboxes.
class MemorySecureStore implements SecureStore {
  MemorySecureStore([Map<String, String>? initial]) : _values = {...?initial};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async => Map.of(_values);
}
