// Applies an update onto a real file: the payload must be a real ELF
// (an AppImage), and a failed download must never replace a working
// binary. The AppImage path and download are injected through the
// Updater's test seams, since tests do not run from an AppImage.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/sys/updater.dart';

const _info = UpdateInfo(
  version: '9.9.9',
  downloadUrl: 'https://example.com/NixieTube-x86_64.AppImage',
  body: '',
);

List<int> _elf(int size) {
  final bytes = List<int>.filled(size, 0x42);
  bytes[0] = 0x7f;
  bytes[1] = 0x45; // E
  bytes[2] = 0x4c; // L
  bytes[3] = 0x46; // F
  return bytes;
}

Future<void> Function(String, String) _serve(List<int> bytes) =>
    (url, path) async {
      await File(path).writeAsBytes(bytes, flush: true);
    };

void main() {
  late Directory dir;
  late File appImage;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nt-updater');
    appImage = File('${dir.path}/NixieTube-x86_64.AppImage')
      ..writeAsStringSync('old binary');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('replaces the AppImage with a valid downloaded ELF', () async {
    final payload = _elf(1024 * 1024 + 1);
    final updater = Updater(
      appImagePath: appImage.path,
      download: _serve(payload),
    );

    final result = await updater.applyUpdate(_info);

    expect(result, appImage.path);
    expect(appImage.readAsBytesSync(), payload);
    expect(File('${appImage.path}.new').existsSync(), isFalse);
  });

  test('refuses a payload that is not an ELF', () async {
    final updater = Updater(
      appImagePath: appImage.path,
      download: _serve(List<int>.filled(2 * 1024 * 1024, 0x41)),
    );

    final result = await updater.applyUpdate(_info);

    expect(result, isNull);
    expect(appImage.readAsStringSync(), 'old binary');
    expect(File('${appImage.path}.new').existsSync(), isFalse);
  });

  test('refuses a tiny payload', () async {
    final updater = Updater(
      appImagePath: appImage.path,
      download: _serve(_elf(1024)),
    );

    final result = await updater.applyUpdate(_info);

    expect(result, isNull);
    expect(appImage.readAsStringSync(), 'old binary');
  });

  test('returns null when not running from an AppImage', () async {
    final updater = Updater(download: _serve(_elf(1024 * 1024 + 1)));

    final result = await updater.applyUpdate(_info);

    expect(result, isNull);
  });
}
