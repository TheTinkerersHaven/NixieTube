import 'dart:async' show unawaited;

import 'package:flutter/material.dart' as fm;
import 'package:m3e_core/m3e_core.dart' show M3ELoadingIndicator;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:silky_scroll/silky_scroll.dart';
import '../../sys/lastfm.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import 'seek_slider.dart' show formatClock;

class SongInfoView extends StatelessWidget {
  const SongInfoView({super.key, required this.track, this.theme});

  final Track track;
  final ThemeData? theme;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    // Duration latches 0 -> actual once the engine reports, but only for
    // the track that is actually playing; other tracks fall back to their
    // own duration.
    final durationMs = context.select<AppState, int>(
      (s) => s.playerState.current?.videoId == track.videoId
          ? s.playerState.durationMs
          : 0,
    );
    final shownMs = durationMs > 0
        ? durationMs
        : (track.durationSec > 0 ? track.durationSec * 1000 : 0);
    final underlineLinks = context.select<AppState, bool>(
      (s) => s.config.underlineLinks,
    );
    final linkDecoration = underlineLinks
        ? TextDecoration.underline
        : TextDecoration.none;
    final theme = this.theme ?? Theme.of(context);
    Widget row(String label, String value, {VoidCallback? onTap}) {
      final scheme = theme.colorScheme;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectionContainer.disabled(
                  child: Text(
                    label,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                if (onTap != null)
                  GestureDetector(
                    onTap: onTap,
                    child: Text(
                      value.isEmpty ? 'Unknown' : value,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: scheme.primary,
                        decoration: linkDecoration,
                      ),
                    ),
                  )
                else
                  Text(
                    value.isEmpty ? 'Unknown' : value,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurface,
                      decoration: TextDecoration.none,
                    ),
                  ),
              ],
            ),
          ),
          Divider(color: scheme.surfaceContainerHigh, height: 1),
        ],
      );
    }

    return fm.SelectableRegion(
      selectionControls: emptyTextSelectionControls,
      child: SilkyListView(
        scrollSpeed: 1.5,
        silkyScrollDuration: const Duration(milliseconds: 700),
        animationCurve: Curves.easeOutQuart,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          row('Title', track.title),
          if (track.artists.isEmpty)
            row('Artists', '')
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectionContainer.disabled(
                        child: Text(
                          'Artists',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (var i = 0; i < track.artists.length; i++) ...[
                              GestureDetector(
                                onTap: () {
                                  state.closeNow();
                                  unawaited(
                                    state.openArtist(track.artists[i], track),
                                  );
                                },
                                child: Text(
                                  track.artists[i].name,
                                  style: theme.textTheme.bodyLarge
                                      ?.copyWith(
                                        color: theme
                                            .colorScheme
                                            .primary,
                                        decoration: linkDecoration,
                                      ),
                                ),
                              ),
                              if (i != track.artists.length - 1)
                                Text(
                                  ', ',
                                  style: theme.textTheme.bodyLarge,
                                ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                  color: theme.colorScheme.surfaceContainerHigh,
                  height: 1,
                ),
              ],
            ),
          if (track.album != null)
            row(
              track.album!.kind?.label ?? 'Album',
              track.album!.name,
              onTap: track.album!.browseId == null
                  ? null
                  : () {
                      state.closeNow();
                      unawaited(state.openAlbum(track, track.album!));
                    },
            )
          else
            row('Album', ''),
          row('Year', track.album?.year ?? ''),
          row('Duration', shownMs > 0 ? formatClock(shownMs) : ''),
          row('Likes', compactCount(track.likeCount)),
          _LastFmInfo(
            track: track,
            key: ValueKey(track.videoId),
            theme: theme,
            row: row,
          ),
        ],
      ),
    );
  }
}



/// One track's assembled song-info payload: the Last.fm track metadata
/// (null when nothing matched confidently), the artist tag list, and the
/// YTM play count label (empty when none could be determined).
typedef _InfoResult = (Map<String, dynamic>?, List<String>, String);

/// Fetches in flight or settled, keyed by videoId. The info surfaces are
/// disposed on every tab switch and rebuilt when the user comes back;
/// without this store each flip would refetch the same metadata.
final Map<String, Future<_InfoResult>> _lastFmFetches =
    <String, Future<_InfoResult>>{};

/// Upper bound on the song-info fetch cache (oldest-first eviction).
const _lastFmFetchCacheMax = 128;

class _LastFmInfo extends StatefulWidget {
  const _LastFmInfo({
    super.key,
    required this.track,
    required this.theme,
    required this.row,
  });

  final Track track;

  /// Theme captured by [SongInfoView] so rows style identically to the
  /// rest of the list even inside the song-info dialog.
  final ThemeData theme;

  /// The same label/value row builder the static rows use, so Last.fm
  /// rows share the padding, divider and selection treatment.
  final Widget Function(String label, String value) row;

  @override
  State<_LastFmInfo> createState() => _LastFmInfoState();
}

class _LastFmInfoState extends State<_LastFmInfo> {
  Future<_InfoResult>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Fetches one track's info: Last.fm track/artist metadata and — when
  /// the track arrived without a views string (queue rows never carry
  /// one) — the YTM play count from the player endpoint.
  Future<_InfoResult> _start(LastFmService lastfm, AppState state) async {
    final artist = lastfmArtistName(widget.track);
    final trackF = lastfm.trackInfo(
      artist,
      widget.track.title,
      durationSec: widget.track.durationSec,
    );
    final artistF = lastfm.artistTags(artist);
    final views = playsLabel(widget.track.views);
    // List rows carry "1.2M plays"-style strings; queue rows have nothing,
    // so the canonical count is fetched once and cached in [AppState].
    final playsF = views.isNotEmpty
        ? Future<String>.value(views)
        : state
            .fetchYtmPlayCount(widget.track.videoId)
            .then((n) => n > 0 ? compactCount(n) : '');
    final r = await Future.wait<Object?>([trackF, artistF, playsF]);
    return (
      r[0] as Map<String, dynamic>?,
      r[1] as List<String>,
      r[2] as String,
    );
  }

  void _load() {
    try {
      final lastfm = context.read<LastFmService>();
      final state = context.read<AppState>();
      final key = widget.track.videoId;
      if (key.isEmpty) {
        _future = _start(lastfm, state);
      } else {
        final cached = _lastFmFetches[key];
        if (cached != null) {
          _future = cached;
        } else {
          final fut = _start(lastfm, state);
          // Bounded memory: remember the ~most recently fetched tracks;
          // the oldest entry is dropped past the cap.
          if (_lastFmFetches.length >= _lastFmFetchCacheMax) {
            // Fire-and-forget eviction; .ignore() marks the dropped
            // future as handled, so a settling entry can't error unwatched.
            _lastFmFetches.remove(_lastFmFetches.keys.first)?.ignore();
          }
          _lastFmFetches[key] = fut;
          _future = fut;
          unawaited(fut.catchError((_) => (null, <String>[], '')));
        }
      }
    } catch (_) {
      _future = null;
    }
  }

  /// Formats a Last.fm counter (played 30,503,879 times) like other
  /// compact counts in this list; falls back to the raw text.
  String _fmtCount(Object? v) {
    final n = v is num ? v.toInt() : int.tryParse('$v');
    if (n != null && n >= 0) return compactCount(n);
    final s = ('${v ?? ''}').trim();
    return s;
  }

  /// Strips helper tags and the "Read more on Last.fm" tail Last.fm
  /// appends to formatted summaries.
  String? _cleanSummary(Object? wiki) {
    if (wiki is! Map) return null;
    final raw = wiki['summary'];
    var s = (raw is String ? raw : '${raw ?? ''}')
        .replaceAll(RegExp('<[^>]*>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'Read more on Last\.(fm|com).*$', caseSensitive: false), '')
        .trim();
    if (s.isEmpty) return null;
    // Trim a trailing dangling separator.
    return s.endsWith(',') || s.endsWith(';')
        ? s.substring(0, s.length - 1)
        : s;
  }

  @override
  Widget build(BuildContext context) {
    final future = _future;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<_InfoResult>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // Centered M3E morphing shapes, no text; the rows below
          // appear in place once the lookups settle.
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: M3ELoadingIndicator(
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                color: widget.theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final (trackData, artistTags, ytmPlays) = snapshot.data ??
            (null, const <String>[], '');
        const dash = '—';
        final trackTags = <String>[];
        final toptags = trackData?['toptags'];
        if (toptags is Map) {
          final tag = toptags['tag'];
          if (tag is List) {
            for (final t in tag.take(6)) {
              if (t is Map && t['name'] is String) {
                trackTags.add(t['name'] as String);
              }
            }
          } else if (tag is Map && tag['name'] is String) {
            trackTags.add(tag['name'] as String);
          }
        }
        String playRow(Object? v) =>
            playCountValue(v) > 0 ? _fmtCount(v) : dash;
        final rows = <Widget>[
          widget.row('Song tags',
              trackTags.isEmpty ? dash : trackTags.join(', ')),
          widget.row(
              'Artist tags', artistTags.isEmpty ? dash : artistTags.join(', ')),
          widget.row('YTM plays', ytmPlays.isEmpty ? dash : ytmPlays),
          widget.row(
            'Last.fm plays',
            trackData == null ? dash : playRow(trackData['playcount']),
          ),
          widget.row(
            'Listeners',
            trackData == null ? dash : playRow(trackData['listeners']),
          ),
        ];
        if (trackData != null) {
          // YouTube uploads without album metadata get Last.fm's album.
          if (widget.track.album == null) {
            final album = trackData['album'];
            final albumName =
                album is Map ? ('${album['title'] ?? ''}').trim() : '';
            if (albumName.isNotEmpty) {
              rows.add(widget.row('Album (Last.fm)', albumName));
            }
          }
          final summary = _cleanSummary(trackData['wiki']);
          if (summary != null) rows.add(widget.row('About', summary));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        );
      },
    );
  }
}

/// Parses a Last.fm counter value; returns 0 when absent or malformed.
int playCountValue(Object? v) =>
    v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

/// Compact K/M rendering shared with `Likes` in [SongInfoView]'s rows;
/// top-level so both call sites stay consistent (and reachable in tests).
String compactCount(int n) {
  if (n < 0) return '';
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final v = n / 1000;
    return v >= 100 ? '${v.round()}K' : '${v.toStringAsFixed(1)}K';
  }
  final m = n / 1000000;
  return m >= 100 ? '${m.round()}M' : '${m.toStringAsFixed(1)}M';
}

/// YTM list rows carry the count as a localized display string ("653M
/// `plays`", "1,234,567 `views`"). When the string looks like a numeric
/// lead token plus one wordless unit token, the unit is dropped;
/// anything else ("No views") is kept verbatim.
String playsLabel(String views) {
  final parts = views.trim().split(RegExp(r'\s+'));
  if (parts.length > 1 &&
      RegExp(r'\d').hasMatch(parts.first) &&
      !RegExp(r'\d').hasMatch(parts.last)) {
    parts.removeLast();
  }
  return parts.join(' ');
}
