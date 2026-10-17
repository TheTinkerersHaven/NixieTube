// Audio backend probe tests: the silent WAV must be a well-formed
// stream a backend can open, and the user-facing copy must name the
// fix. The native probe itself is exercised in the app, not here.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/player/audio_backend.dart';

void main() {
  group('silentWavBytes', () {
    test('writes a valid 8-bit mono PCM header', () {
      final bytes = silentWavBytes(seconds: 1);
      final view = ByteData.sublistView(bytes);

      String ascii(int at, int len) =>
          String.fromCharCodes(bytes.sublist(at, at + len));

      expect(ascii(0, 4), 'RIFF');
      expect(ascii(8, 4), 'WAVE');
      expect(ascii(12, 4), 'fmt ');
      expect(ascii(36, 4), 'data');

      // fmt fields: PCM, mono, 8kHz, byte rate, block align, 8 bits.
      expect(view.getUint16(20, Endian.little), 1); // PCM
      expect(view.getUint16(22, Endian.little), 1); // channels
      expect(view.getUint32(24, Endian.little), 8000); // sample rate
      expect(view.getUint32(28, Endian.little), 8000); // byte rate
      expect(view.getUint16(32, Endian.little), 1); // block align
      expect(view.getUint16(34, Endian.little), 8); // bits per sample

      // Sizes agree: 44-byte header plus one byte per sample.
      const dataSize = 8000;
      expect(view.getUint32(4, Endian.little), 36 + dataSize);
      expect(view.getUint32(40, Endian.little), dataSize);
      expect(bytes.length, 44 + dataSize);
    });

    test('payload is digital silence at mid-level', () {
      final bytes = silentWavBytes(seconds: 1);
      final payload = bytes.sublist(44);
      expect(payload.every((b) => b == 0x80), isTrue);
    });

    test('length scales with duration', () {
      expect(silentWavBytes(seconds: 2).length, 44 + 16000);
      expect(silentWavBytes(seconds: 1, sampleRate: 4000).length, 44 + 4000);
    });
  });

  group('guidance copy', () {
    test('missing-hint names the fix and the package', () {
      expect(audioBackendMissingHint, contains('mpv'));
      // Every major distro family is covered by one of these.
      expect(audioBackendMissingHint, contains('pacman'));
      expect(audioBackendMissingHint, contains('apt'));
      expect(audioBackendMissingHint, contains('dnf'));
    });
  });
}
