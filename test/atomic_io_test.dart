// Atomic file writes: content only ever appears complete, so a crash
// mid-write cannot truncate a cache or the settings file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/sys/atomic_io.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('nt-atomic'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('writeAtomicSync replaces the file and leaves no temp behind', () {
    final path = '${dir.path}/file.json';

    writeAtomicSync(path, 'first');
    writeAtomicSync(path, 'second');

    expect(File(path).readAsStringSync(), 'second');
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('writeAtomic replaces the file and leaves no temp behind', () async {
    final path = '${dir.path}/file.json';

    await writeAtomic(path, 'first');
    await writeAtomic(path, 'second');

    expect(File(path).readAsStringSync(), 'second');
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('a stale temp from an interrupted write is simply replaced', () {
    final path = '${dir.path}/file.json';
    File('$path.tmp').writeAsStringSync('half-writ');

    writeAtomicSync(path, 'complete');

    expect(File(path).readAsStringSync(), 'complete');
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('missing parent directories are created', () async {
    final path = '${dir.path}/nested/deeper/file.json';

    await writeAtomic(path, 'ok');

    expect(File(path).readAsStringSync(), 'ok');
  });
}
