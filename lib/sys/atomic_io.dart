// Atomic file writes: write a sibling temp file, flush it, then rename it
// over the target. A crash or kill mid-write then leaves the previous file
// intact instead of a truncated one — the settings file and every cache
// used to risk exactly that, since they wrote straight over the target.

import 'dart:io';

/// Writes [contents] to [path] atomically.
///
/// The temp file is a sibling, so the rename stays inside one filesystem
/// and is therefore atomic. A leftover temp from an earlier crash is
/// simply overwritten. Failures clean the temp up and rethrow, so callers
/// keep their existing best-effort try/catch.
void writeAtomicSync(String path, String contents) {
  final tmp = File('$path.tmp');
  tmp.parent.createSync(recursive: true);
  try {
    tmp.writeAsStringSync(contents, flush: true);
    tmp.renameSync(path);
  } catch (_) {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
    rethrow;
  }
}

/// [writeAtomicSync] for callers that are already async.
Future<void> writeAtomic(String path, String contents) async {
  final tmp = File('$path.tmp');
  tmp.parent.createSync(recursive: true);
  try {
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(path);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}
