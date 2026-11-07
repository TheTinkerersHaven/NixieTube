// Pinned quick picks for the NixieTube app.
//
// YTM pins live only in the official clients, so pins are stored
// locally as snapshots and rendered ahead of the rotating pools. The
// owning AppState notifies its listeners after every change.

import 'dart:convert';

import '../../core/models/models.dart';

/// The pinned quick picks and their persistence.
class PinnedPicksState {
  /// Creates a pinned-picks state that reads and writes through
  /// [read] and [write].
  PinnedPicksState({required this.read, required this.write});

  /// Reads the persisted pin list.
  final String Function(String key, String defaultValue) read;

  /// Writes the persisted pin list.
  final void Function(String key, String value) write;

  /// The settings key the pin list lives under.
  static const storageKey = 'home.pinnedPicks';

  /// The most pins that are kept.
  static const cap = 12;

  /// The pinned picks, most recent pin last.
  List<ShelfItem> _picks = [];

  /// The pinned picks, most recent pin last.
  List<ShelfItem> get picks => _picks;

  /// The identity of [item] among the picks, or null when it has none.
  static String? keyOf(ShelfItem item) {
    if (item is SongItem) {
      return item.track.videoId.isEmpty ? null : 's:${item.track.videoId}';
    }
    if (item is BrowseItem) {
      return item.browseId.isEmpty ? null : 'b:${item.browseId}';
    }
    return null;
  }

  /// True when [item] (by video/browse id) is in the pinned list.
  bool contains(ShelfItem item) {
    final id = keyOf(item);
    return id != null && _picks.any((pick) => keyOf(pick) == id);
  }

  /// Pins or unpins a quick-pick tile. Skeleton tiles and over-cap
  /// pins are ignored. Reassigns (never mutates) so selects detect
  /// the change and the grid rebuilds.
  void toggle(ShelfItem item) {
    final id = keyOf(item);
    if (id == null || id.startsWith('s:skeleton-')) return;
    if (_picks.any((pick) => keyOf(pick) == id)) {
      _picks = [
        for (final pick in _picks)
          if (keyOf(pick) != id) pick,
      ];
    } else {
      if (_picks.length >= cap) return;
      _picks = [..._picks, item];
    }
    _save();
  }

  /// Snapshot encoding for one pin (static so it stays unit-testable
  /// without a PinnedPicksState instance).
  static Map<String, dynamic> pinToJson(ShelfItem item) {
    if (item is SongItem) return {'k': 's', 'track': item.track.toJson()};
    final browse = item as BrowseItem;
    return {
      'k': 'b',
      'title': browse.title,
      'subtitle': browse.subtitle,
      'browseId': browse.browseId,
      'thumbnails': [for (final t in browse.thumbnails) t.toJson()],
    };
  }

  /// Decodes one pin snapshot; null on any schema drift (a stale pin
  /// must never break startup).
  static ShelfItem? pinFromJson(dynamic e) {
    if (e is! Map) return null;
    try {
      if (e['k'] == 's') {
        final track = e['track'];
        if (track is! Map) return null;
        return ShelfItem.song(
          Track.fromJson(track.map((k, v) => MapEntry(k.toString(), v))),
        );
      }
      if (e['k'] == 'b') {
        final browseId = e['browseId']?.toString() ?? '';
        if (browseId.isEmpty) return null;
        final thumbs = e['thumbnails'];
        return ShelfItem.browse(
          title: e['title']?.toString() ?? '',
          subtitle: e['subtitle']?.toString() ?? '',
          browseId: browseId,
          thumbnails: [
            if (thumbs is List)
              for (final t in thumbs)
                if (t is Map)
                  Thumbnail.fromJson(
                    t.map((k, v) => MapEntry(k.toString(), v)),
                  ),
          ],
        );
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Loads the persisted pins.
  void load() {
    try {
      final raw = read(storageKey, '');
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _picks = decoded
          .map(pinFromJson)
          .whereType<ShelfItem>()
          .take(cap)
          .toList();
    } catch (_) {}
  }

  void _save() {
    try {
      write(storageKey, jsonEncode([for (final p in _picks) pinToJson(p)]));
    } catch (_) {}
  }
}
