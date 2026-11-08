// App-wide logging: one `package:logger` pipeline that writes to the
// console and to a rotating file under the cache directory.
//
// Every module logs through a [TaggedLog], so a shared file line carries
// the area that produced it. Warnings and errors reach the console;
// the file also keeps debug lines (stream resolves, ratings, watchtime).

import 'dart:io';

import 'package:logger/logger.dart';

import 'paths.dart';

/// A log file this big is rotated to `.1` at startup (one archive is
/// kept), so the logs can never grow without bound.
const _maxLogBytes = 1 << 20;

Logger _logger = _create();

/// The app-wide logger. Before [initLogging] runs it only writes to the
/// console, so tests and tooling never touch the user's log file.
Logger get appLog => _logger;

/// Wires file logging. Call once from `main` before any service logs;
/// later calls are no-ops.
void initLogging() {
  if (_fileLogging) return;
  _fileLogging = true;
  try {
    _logger = _create(file: _openLogFile());
  } catch (_) {
    // Logging must never keep the app from starting.
    _logger = _create();
  }
}

bool _fileLogging = false;

/// Appends one line per event; the file is opened in append mode and a
/// failed write is ignored, so logging can never break the caller.
File _openLogFile() {
  final file = File('${logDir().path}/nixietube.log');
  try {
    if (file.existsSync() && file.lengthSync() >= _maxLogBytes) {
      final previous = File('${file.path}.1');
      if (previous.existsSync()) previous.deleteSync();
      file.renameSync(previous.path);
    }
  } catch (_) {}
  return file;
}

Logger _create({File? file}) {
  final outputs = <LogOutput>[_ConsoleSink()];
  if (file != null) outputs.add(_FileSink(file));
  return Logger(
    filter: ProductionFilter(),
    level: Level.debug,
    printer: _LinePrinter(),
    output: MultiOutput(outputs),
  );
}

/// A logger that prefixes every message with [tag], so a shared log file
/// shows which area produced the line.
class TaggedLog {
  const TaggedLog(this.tag);

  final String tag;

  void t(Object? message, {Object? error, StackTrace? stackTrace}) =>
      appLog.t('[$tag] $message', error: error, stackTrace: stackTrace);

  void d(Object? message, {Object? error, StackTrace? stackTrace}) =>
      appLog.d('[$tag] $message', error: error, stackTrace: stackTrace);

  void i(Object? message, {Object? error, StackTrace? stackTrace}) =>
      appLog.i('[$tag] $message', error: error, stackTrace: stackTrace);

  void w(Object? message, {Object? error, StackTrace? stackTrace}) =>
      appLog.w('[$tag] $message', error: error, stackTrace: stackTrace);

  void e(Object? message, {Object? error, StackTrace? stackTrace}) =>
      appLog.e('[$tag] $message', error: error, stackTrace: stackTrace);
}

/// `2026-11-08T09:15:42.123 [INFO] [stream] message`, with the error and
/// stack trace appended when present.
class _LinePrinter extends LogPrinter {
  @override
  List<String> log(LogEvent event) {
    final buffer = StringBuffer()
      ..write(event.time.toIso8601String())
      ..write(' [')
      ..write(event.level.name.toUpperCase().padRight(7))
      ..write('] ')
      ..write(event.message);
    if (event.error != null) buffer.write(' error=${event.error}');
    final trace = event.stackTrace;
    if (trace != null) buffer.write('\n$trace');
    return [buffer.toString()];
  }
}

/// Writes to stdout, leaving debug/trace lines to the file only.
class _ConsoleSink extends LogOutput {
  @override
  void output(OutputEvent event) {
    if (event.level < Level.info) return;
    for (final line in event.lines) {
      stdout.writeln(line);
    }
  }
}

/// Appends to [file], flushing to the OS on every write so a crash or an
/// `exit()` cannot lose the last lines.
class _FileSink extends LogOutput {
  _FileSink(this.file);

  final File file;

  @override
  Future<void> init() async {
    try {
      file.parent.createSync(recursive: true);
    } catch (_) {}
  }

  @override
  void output(OutputEvent event) {
    try {
      file.writeAsStringSync(
        '${event.lines.join('\n')}\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }
}
