// Credentials live in the platform secret store; the plain-text
// `auth.properties` of older versions is migrated into it once and
// then deleted.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/sys/secure_store.dart';
import 'package:nixietube/sys/sys_config.dart';

void main() {
  group('credential storage', () {
    late Directory dir;
    late String configPath;
    late String authPath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('nt-secure-store');
      configPath = '${dir.path}/config.properties';
      authPath = '${dir.path}/auth.properties';
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('migrates the legacy file into the store and deletes it', () async {
      File(authPath).writeAsStringSync(
        'cookie=SAPISID=abc\n'
        'sapisidHash=1_hash\n'
        'sessionToken=QUZZT1=token\n'
        'lastfm.apiKey=key\n',
      );
      final store = MemorySecureStore();
      final config = SysConfig(configPath: configPath, secure: store);

      await config.loadCredentials();

      // The credentials are in the store...
      expect(await store.read('cookie'), 'SAPISID=abc');
      expect(await store.read('sapisidHash'), '1_hash');
      expect(await store.read('sessionToken'), 'QUZZT1=token');
      expect(await store.read('lastfm.apiKey'), 'key');
      // ...readable through the config...
      expect(config.get('cookie'), 'SAPISID=abc');
      expect(config.lastfmApiKey, 'key');
      // ...and the plain-text file is gone.
      expect(File(authPath).existsSync(), isFalse);
    });

    test('keeps the legacy file when the store refuses the write', () async {
      File(authPath).writeAsStringSync('cookie=SAPISID=abc\n');
      final config = SysConfig(configPath: configPath, secure: _FailingStore());

      await config.loadCredentials();

      // Nothing was lost: the file is still there for the next try.
      expect(File(authPath).existsSync(), isTrue);
    });

    test('never writes credentials to a file', () async {
      final store = MemorySecureStore();
      final config = SysConfig(configPath: configPath, secure: store);

      await config.loadCredentials();
      await config.setCredential('cookie', 'SAPISID=abc');
      config.set('lyrics.source', 'ytmusic');
      await config.flushCredentials();

      expect(await store.read('cookie'), 'SAPISID=abc');
      expect(File(authPath).existsSync(), isFalse);
      // The app settings still live in their plain-text file.
      expect(File(configPath).readAsStringSync(), contains('lyrics.source'));
      expect(File(configPath).readAsStringSync(), isNot(contains('SAPISID')));
    });

    test('ignores other apps items in the shared store', () async {
      final store = MemorySecureStore({
        'someOtherApp': 'not ours',
        'cookie': 'SAPISID=abc',
      });
      final config = SysConfig(configPath: configPath, secure: store);

      await config.loadCredentials();

      expect(config.get('cookie'), 'SAPISID=abc');
      // The foreign item never reaches the settings file.
      config.set('lyrics.source', 'ytmusic');
      expect(File(configPath).readAsStringSync(), isNot(contains('not ours')));
    });

    test('the load asks for each credential by name', () async {
      // Not a bulk read: the Android backend's "read all" only returns
      // items written with the legacy key prefix, so a cookie the app
      // saved itself was invisible on the next launch and every start
      // looked signed out.
      final store = _RecordingStore({
        'cookie': 'SAPISID=abc',
        'lastfm.username': 'bob',
      });
      final config = SysConfig(configPath: configPath, secure: store);

      await config.loadCredentials();

      expect(store.reads, contains('cookie'));
      expect(config.get('cookie'), 'SAPISID=abc');
      expect(config.get('lastfm.username'), 'bob');
    });

    test('a store that fails one key still restores the others', () async {
      final store = _RecordingStore({'cookie': 'SAPISID=abc'})
        ..failing.add('lastfm.secret');
      final config = SysConfig(configPath: configPath, secure: store);

      await config.loadCredentials();

      expect(config.get('cookie'), 'SAPISID=abc');
    });

    test('reads the credentials back on the next start', () async {
      final store = MemorySecureStore();
      final first = SysConfig(configPath: configPath, secure: store);
      await first.loadCredentials();
      await first.setCredential('cookie', 'SAPISID=abc');

      final second = SysConfig(configPath: configPath, secure: store);
      await second.loadCredentials();
      expect(second.get('cookie'), 'SAPISID=abc');
    });

    test('removing a credential drops it from the store', () async {
      final store = MemorySecureStore();
      final config = SysConfig(configPath: configPath, secure: store);
      await config.loadCredentials();
      await config.setCredential('cookie', 'SAPISID=abc');

      config.remove('cookie');
      await config.flushCredentials();

      expect(await store.read('cookie'), isNull);
      expect(config.get('cookie'), isEmpty);
    });
  });
}

/// A store that records the keys it is asked for, and can refuse
/// individual ones.
class _RecordingStore implements SecureStore {
  _RecordingStore([Map<String, String>? initial]) : _values = {...?initial};

  final Map<String, String> _values;

  /// Keys whose read throws, as a locked or missing keyring does.
  final Set<String> failing = {};

  /// Every key read, in order.
  final List<String> reads = [];

  @override
  Future<String?> read(String key) async {
    reads.add(key);
    if (failing.contains(key)) throw StateError('no entry for $key');
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// A store that refuses every write.
class _FailingStore implements SecureStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {
    throw StateError('the keyring is locked');
  }

  @override
  Future<void> delete(String key) async {}
}
