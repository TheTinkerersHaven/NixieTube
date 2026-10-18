// Audio backend probe: detects a missing/unusable native audio
// library (libmpv on Linux) before the user tries to play anything.
//
// Without this, a missing backend only fails on the first play: the
// native layer prints to the console and the open hangs until the
// 20s play timeout — indistinguishable from a freeze. Probing at
// startup lets the app refuse playback instantly with instructions.
//
// The probe plays a locally generated silent WAV through a throwaway
// player: no network, no assets, and it exercises exactly the same
// native initialization path a real stream would.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart' as ja;

/// Outcome of [probeAudioBackend].
enum AudioBackendStatus {
  /// Native backend opened the silent file: playback can proceed.
  ok,

  /// Backend is present but could not be used (library missing, no
  /// device, refusal to open) — treat as broken for the user.
  unavailable,

  /// Neither ok nor unavailable (probe itself failed, e.g. sandboxed
  /// filesystem). Shown as "could not verify".
  unknown,
}

/// Result of [probeAudioBackend]: the status plus the user-facing
/// explanation to show when playback is refused.
class AudioBackendProbe {
  const AudioBackendProbe(this.status, this.message);
  final AudioBackendStatus status;

  /// Null when [status] is ok.
  final String? message;
}

/// Distro-agnostic install hint. Arch names `mpv`, Debian/Ubuntu
/// `libmpv1` + `mpv`, Fedora `mpv-libs`; pointing at the mpv package
/// covers all of them since the native build uses libmpv.
const audioBackendMissingHint =
    'The audio engine (mpv) is missing or could not be loaded. '
    'Install mpv for your distribution — e.g. "sudo pacman -S mpv", '
    '"sudo apt install mpv" or "sudo dnf install mpv" — then restart '
    'NixieTube.';

/// Builds a valid PCM WAV of digital silence. 8-bit unsigned samples
/// sit at mid-level (0x80), 8kHz mono keeps it tiny while still being
/// a well-formed stream a backend can open.
Uint8List silentWavBytes({int seconds = 1, int sampleRate = 8000}) {
  final samples = sampleRate * seconds;
  final dataSize = samples; // 1 byte per sample
  final bytes = ByteData(44 + dataSize);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little); // PCM chunk size
  bytes.setUint16(20, 1, Endian.little); // format: PCM
  bytes.setUint16(22, 1, Endian.little); // channels
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate, Endian.little); // byte rate
  bytes.setUint16(32, 1, Endian.little); // block align
  bytes.setUint16(34, 8, Endian.little); // bits per sample
  ascii(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < samples; i++) {
    bytes.setUint8(44 + i, 0x80);
  }
  return bytes.buffer.asUint8List();
}

/// Writes a silent WAV to a temp file and plays it through a
/// throwaway player, never for longer than [timeout]. Any throw or
/// timeout maps to [AudioBackendStatus.unavailable]/`unknown`.
Future<AudioBackendProbe> probeAudioBackend({
  Duration timeout = const Duration(seconds: 8),
}) async {
  final player = ja.AudioPlayer();
  File? wav;
  try {
    final dir = await Directory.systemTemp.createTemp('nixietube-audio-probe');
    wav = File('${dir.path}/silence.wav');
    await wav.writeAsBytes(silentWavBytes(), flush: true);
    await player.setUrl(Uri.file(wav.path).toString()).timeout(timeout);
    return const AudioBackendProbe(AudioBackendStatus.ok, null);
  } on TimeoutException {
    return const AudioBackendProbe(
      AudioBackendStatus.unknown,
      'The audio engine did not respond, so playback could not be '
      'verified. Play something and watch for errors; if it fails, '
      'reinstall mpv and restart.',
    );
  } catch (_) {
    return const AudioBackendProbe(
      AudioBackendStatus.unavailable,
      audioBackendMissingHint,
    );
  } finally {
    try {
      await player.dispose().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      if (wav != null) await wav.parent.delete(recursive: true);
    } catch (_) {}
  }
}
