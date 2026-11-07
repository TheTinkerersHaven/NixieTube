// Shared formatting helpers for the UI layer.
//
// Small, pure functions used by several widgets: durations and counts
// must read the same everywhere.

/// Formats a millisecond count as `m:ss`.
String formatClock(int milliseconds) {
  if (milliseconds <= 0) return '0:00';
  final seconds = milliseconds ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// Formats [seconds] as `m:ss`, or `h:mm:ss` for long tracks.
/// Negative or unknown durations render as `0:00`.
String formatDuration(int seconds) {
  if (seconds <= 0) return '0:00';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final secs = seconds % 60;
  final ss = secs.toString().padLeft(2, '0');
  if (hours == 0) return '$minutes:$ss';
  final mm = minutes.toString().padLeft(2, '0');
  return '$hours:$mm:$ss';
}

/// Compact K/M rendering of [count]; negative counts render as empty.
/// Shared by the likes and plays rows so both read the same.
String compactCount(int count) {
  if (count < 0) return '';
  if (count < 1000) return '$count';
  if (count < 1000000) {
    final thousands = count / 1000;
    return thousands >= 100
        ? '${thousands.round()}K'
        : '${thousands.toStringAsFixed(1)}K';
  }
  final millions = count / 1000000;
  return millions >= 100
      ? '${millions.round()}M'
      : '${millions.toStringAsFixed(1)}M';
}
