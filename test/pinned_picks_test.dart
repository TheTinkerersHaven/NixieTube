// Tests for the pinned quick picks: pinning, unpinning, the pin cap,
// persistence across state instances and tolerance of stale stored
// data.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/ui/state/pinned_picks_state.dart';

ShelfItem _song(String videoId) =>
    ShelfItem.song(Track(videoId: videoId, title: 'Track $videoId'));

ShelfItem _browse(String browseId) => ShelfItem.browse(
  title: 'Artist $browseId',
  subtitle: 'Artist',
  browseId: browseId,
  thumbnails: const [],
);

PinnedPicksState _state([Map<String, String>? store]) {
  final values = store ?? <String, String>{};
  return PinnedPicksState(
    read: (key, defaultValue) => values[key] ?? defaultValue,
    write: (key, value) => values[key] = value,
  );
}

void main() {
  group('pinned picks', () {
    test('a pin is remembered and reported as pinned', () {
      final state = _state();
      final item = _song('abc');

      expect(state.contains(item), isFalse);

      state.toggle(item);

      expect(state.contains(item), isTrue);
      expect(state.picks, hasLength(1));
    });

    test('toggling a pinned item unpins it', () {
      final state = _state();
      final item = _song('abc');

      state.toggle(item);
      state.toggle(item);

      expect(state.contains(item), isFalse);
      expect(state.picks, isEmpty);
    });

    test('songs and browse items are pinned independently', () {
      final state = _state();
      final song = _song('abc');
      final browse = _browse('UC123');

      state.toggle(song);
      state.toggle(browse);

      expect(state.picks, hasLength(2));
      expect(state.contains(song), isTrue);
      expect(state.contains(browse), isTrue);
      expect(state.contains(_song('abc')), isTrue);
      expect(state.contains(_song('other')), isFalse);
    });

    test('pins beyond the cap are ignored', () {
      final state = _state();

      for (var i = 0; i < PinnedPicksState.cap; i++) {
        state.toggle(_song('v$i'));
      }
      state.toggle(_song('overflow'));

      expect(state.picks, hasLength(PinnedPicksState.cap));
      expect(state.contains(_song('overflow')), isFalse);
    });

    test('skeleton tiles are never pinned', () {
      final state = _state();
      final skeleton = _song('skeleton-1');

      state.toggle(skeleton);

      expect(state.contains(skeleton), isFalse);
      expect(state.picks, isEmpty);
    });

    test('pins survive a new state reading the same store', () {
      final store = <String, String>{};
      final first = _state(store);
      first.toggle(_song('abc'));

      final second = _state(store);
      second.load();

      expect(second.contains(_song('abc')), isTrue);
      expect(second.picks, hasLength(1));
    });

    test('stored pins are restored with their titles', () {
      final store = <String, String>{
        PinnedPicksState.storageKey: jsonEncode([
          PinnedPicksState.pinToJson(_song('abc')),
          PinnedPicksState.pinToJson(_browse('UC123')),
        ]),
      };
      final state = _state(store);

      state.load();

      expect(state.picks, hasLength(2));
      final song = state.picks.whereType<SongItem>().single;
      expect(song.track.videoId, 'abc');
      expect(song.track.title, 'Track abc');
      final browse = state.picks.whereType<BrowseItem>().single;
      expect(browse.browseId, 'UC123');
    });

    test('stale stored data loads as no pins instead of throwing', () {
      final store = <String, String>{
        PinnedPicksState.storageKey: 'not json at all',
      };
      final state = _state(store);

      state.load();

      expect(state.picks, isEmpty);
    });

    test('a stored pin with an unknown shape is skipped', () {
      final store = <String, String>{
        PinnedPicksState.storageKey: jsonEncode([
          {'k': 'x'},
          {'k': 's', 'track': 'not a map'},
          PinnedPicksState.pinToJson(_song('abc')),
        ]),
      };
      final state = _state(store);

      state.load();

      expect(state.picks, hasLength(1));
      expect(state.contains(_song('abc')), isTrue);
    });
  });
}
