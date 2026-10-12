// Tests for the tray menu refresh identity: the native menu must
// rebuild on track/play changes but never on progress ticks. Pure
// logic only — no plugin calls.

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/sys/tray_service.dart';

Track _track(String id) => Track(
      videoId: id,
      title: 'Title $id',
      artists: [ArtistRef('Artist $id')],
      durationSec: 200,
    );

void main() {
  test('play/pause label follows playback', () {
    expect(trayPlayPauseLabel(true), 'Pause');
    expect(trayPlayPauseLabel(false), 'Play');
  });

  test('tooltip names the track or falls back to the app', () {
    expect(trayTooltipFor(null), 'NixieTube');
    expect(
      trayTooltipFor(_track('v1')),
      'Title v1 — Artist v1',
    );
    expect(
      trayTooltipFor(
        const Track(videoId: 'v2', title: 'Untitled', durationSec: 1),
      ),
      'Untitled',
    );
  });

  test('menu key moves on track/play/title changes only', () {
    final base = PlayerState(
      current: _track('v1'),
      playing: true,
      queue: [_track('v1')],
      index: 0,
      durationMs: 200000,
    );
    final tick = base.copyWith(positionMs: 120000);
    expect(TrayMenuKey.of(tick), TrayMenuKey.of(base));

    final paused = base.copyWith(playing: false);
    expect(TrayMenuKey.of(paused), isNot(TrayMenuKey.of(base)));

    final next = base.copyWith(
      queue: [_track('v1'), _track('v2')],
      index: 1,
      current: () => _track('v2'),
    );
    expect(TrayMenuKey.of(next), isNot(TrayMenuKey.of(base)));

    final renamed = base.copyWith(
      current: () => Track(
        videoId: 'v1',
        title: 'Retitled',
        artists: [ArtistRef('Artist v1')],
        durationSec: 200,
      ),
    );
    expect(TrayMenuKey.of(renamed), isNot(TrayMenuKey.of(base)));
  });
}
