// The Lyrics tab's providers are independent: the LRCLIB tab only ever
// shows LRCLIB lines and the YT Music tab only YT Music lines, a miss
// shows the empty note, and only an LRCLIB miss moves the tab to
// YT Music — without changing the saved preference.

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/innertube/lyrics.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/ui/app_state.dart';

import 'fakes.dart';

const _track = Track(
  videoId: 'v1',
  title: 'One',
  artists: [ArtistRef('Uno')],
  durationSec: 200,
);

List<LyricLine> _lines(String text) => [LyricLine(timeMs: -1, text: text)];

/// Pumps until the tab's lyrics have settled. An LRCLIB miss chains into
/// the YT Music lookup, so this waits past a single fetch.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Stops playback inside the test body: its progress timer is still
/// pending when the widget tree goes away, and the pending-timer check
/// runs before `addTearDown`.
Future<void> _stop(WidgetTester tester, AppState state) async {
  state.player.dispose();
  await tester.pump();
}

void main() {
  testWidgets('each provider shows only its own lyrics', (tester) async {
    var lrclibCalls = 0;
    var ytmCalls = 0;
    final state = await bootAppState(
      tester,
      tube: FakeTube(),
      lrclibLyrics: (track) async {
        lrclibCalls++;
        return (lines: _lines('lrc line'), album: null);
      },
      ytmLyrics: (track) async {
        ytmCalls++;
        return _lines('ytm line');
      },
    );

    state.player.playTracks([_track]);
    await _settle(tester);
    expect(state.lyricsSource, LyricsSource.lrclib);
    expect(state.lyrics.single.text, 'lrc line');
    expect(lrclibCalls, 1);
    // The other provider is not fetched just because the tab is open.
    expect(ytmCalls, 0);

    state.setLyricsSource(LyricsSource.ytmusic);
    await _settle(tester);
    expect(state.lyricsSource, LyricsSource.ytmusic);
    expect(state.lyrics.single.text, 'ytm line');
    expect(state.config.lyricsSource, 'ytmusic');

    state.setLyricsSource(LyricsSource.lrclib);
    await _settle(tester);
    expect(state.lyricsSource, LyricsSource.lrclib);
    expect(state.lyrics.single.text, 'lrc line');
    // Each provider's result is cached on its own: no refetch on switch.
    expect(lrclibCalls, 1);
    expect(ytmCalls, 1);
    await _stop(tester, state);
  });

  testWidgets('an LRCLIB miss moves the tab to YT Music', (tester) async {
    final state = await bootAppState(
      tester,
      tube: FakeTube(),
      lrclibLyrics: (track) async => (lines: const <LyricLine>[], album: null),
      ytmLyrics: (track) async => _lines('ytm line'),
    );

    state.player.playTracks([_track]);
    await _settle(tester);

    expect(state.lyricsSource, LyricsSource.ytmusic);
    expect(state.lyrics.single.text, 'ytm line');
    // The saved preference is untouched, so the next track tries LRCLIB.
    expect(state.config.lyricsSource, 'lrclib');
    expect(state.lyricsLoading, isFalse);
    await _stop(tester, state);
  });

  testWidgets('a YT Music miss never borrows LRCLIB lyrics', (tester) async {
    final state = await bootAppState(
      tester,
      tube: FakeTube(),
      lrclibLyrics: (track) async => (lines: _lines('lrc line'), album: null),
      ytmLyrics: (track) async => const <LyricLine>[],
    );

    // Saved preference: the following track starts on YT Music.
    state.setLyricsSource(LyricsSource.ytmusic);
    state.player.playTracks([_track]);
    await _settle(tester);

    expect(state.lyricsSource, LyricsSource.ytmusic);
    expect(state.lyrics, isEmpty);
    expect(state.lyricsLoading, isFalse);
    await _stop(tester, state);
  });

  testWidgets('an explicit LRCLIB choice keeps its empty state', (
    tester,
  ) async {
    final state = await bootAppState(
      tester,
      tube: FakeTube(),
      lrclibLyrics: (track) async => (lines: const <LyricLine>[], album: null),
      ytmLyrics: (track) async => _lines('ytm line'),
    );

    state.player.playTracks([_track]);
    await _settle(tester);
    expect(state.lyricsSource, LyricsSource.ytmusic);

    // Going back to LRCLIB on purpose shows its own empty state instead
    // of bouncing to YT Music again.
    state.setLyricsSource(LyricsSource.lrclib);
    await _settle(tester);
    expect(state.lyricsSource, LyricsSource.lrclib);
    expect(state.lyrics, isEmpty);
    expect(state.lyricsLoading, isFalse);
    await _stop(tester, state);
  });
}
