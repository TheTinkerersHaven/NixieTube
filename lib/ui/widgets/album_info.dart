// Album info dialog: the album's summary (YouTube Music or Last.fm), plus
// year, release type, runtime, track count, artist and genre, with
// MusicBrainz release facts (date, label, country) when the release is
// known. Opened from the album page's ⋮ menu or the card right-click
// menu; same AlertDialog shell the song-info panel uses.

import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart' as fm;
import 'package:m3e_core/m3e_core.dart' show M3ELoadingIndicator;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../core/models/models.dart';
import '../../sys/lastfm.dart';
import '../../sys/musicbrainz.dart';

/// Everything the dialog shows besides the album itself: the Last.fm
/// summary and genre tags, when Last.fm has them.
typedef _LastFmAlbum = ({String wiki, List<String> tags});

/// Ceiling for the Last.fm album lookup. The call normally answers in
/// well under a second; a hung connection must not leave the panel
/// spinning forever.
const _lookupTimeout = Duration(seconds: 8);

/// Label for a [ReleaseKind], falling back to its enum name.
String _kindLabel(ReleaseKind? kind) {
  if (kind == null) return '';
  return kind.label;
}

/// The length of the album's tracks, e.g. `2 hr 34 min` or `38 min`.
String _totalRuntime(List<Track> tracks) {
  var total = 0;
  for (final t in tracks) {
    total += t.durationSec;
  }
  if (total <= 0) return '';
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  if (hours > 0) {
    return minutes > 0 ? '$hours hr $minutes min' : '$hours hr';
  }
  return '${minutes < 1 ? 1 : minutes} min';
}

class AlbumInfoView extends StatefulWidget {
  const AlbumInfoView({
    super.key,
    required this.album,
    this.artist,
    this.theme,
  });

  final AlbumDetail album;

  /// The album's artist, when the album page carried one. Drives the
  /// Last.fm lookup; null skips it.
  final ArtistRef? artist;

  final ThemeData? theme;

  @override
  State<AlbumInfoView> createState() => _AlbumInfoViewState();
}

class _AlbumInfoViewState extends State<AlbumInfoView> {
  Future<_LastFmAlbum>? _future;
  Future<MusicBrainzRelease?>? _mbFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AlbumInfoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldArtist = oldWidget.artist?.name ?? '';
    final newArtist = widget.artist?.name ?? '';
    final oldTitle = oldWidget.album.title;
    final newTitle = widget.album.title;
    if (oldArtist != newArtist || oldTitle != newTitle) _load();
  }

  void _load() {
    final artist = widget.artist?.name.trim() ?? '';
    final album = widget.album.title.trim();
    if (artist.isEmpty || album.isEmpty) {
      _future = null;
      _mbFuture = null;
      return;
    }
    _future = _lastFmFuture(artist, album);
    _mbFuture = _musicBrainzFuture(artist, album);
  }

  /// The Last.fm summary/tags lookup, or null when the service isn't
  /// wired (some tests and the first frame before providers settle).
  Future<_LastFmAlbum>? _lastFmFuture(String artist, String album) {
    final LastFmService? lastfm;
    try {
      lastfm = context.read<LastFmService>();
    } catch (_) {
      return null;
    }
    final future = _start(lastfm, artist, album);
    // Mark the future handled so a failure can't surface as an
    // uncaught error; the FutureBuilder falls back to its empty state.
    unawaited(future.catchError((_) => (wiki: '', tags: <String>[])));
    return future;
  }

  /// MusicBrainz release lookup, or null when the service isn't wired.
  Future<MusicBrainzRelease?>? _musicBrainzFuture(String artist, String album) {
    final MusicBrainzService? musicbrainz;
    try {
      musicbrainz = context.read<MusicBrainzService>();
    } catch (_) {
      return null;
    }
    final future = _startMusicBrainz(
      musicbrainz,
      artist,
      album,
      widget.album.year,
    );
    unawaited(future.catchError((_) => null));
    return future;
  }

  Future<_LastFmAlbum> _start(
    LastFmService lastfm,
    String artist,
    String album,
  ) async {
    // A hung connection must not keep the panel waiting forever: fall
    // back to the facts the album already carries.
    final Map<String, dynamic>? res;
    try {
      res = await lastfm.albumInfo(artist, album).timeout(_lookupTimeout);
    } catch (_) {
      return (wiki: '', tags: <String>[]);
    }
    if (res == null) return (wiki: '', tags: <String>[]);
    // The summary carries wiki markup like "The first album by X...
    // <a href=...>Read more on Last.fm</a>." — strip the links.
    final wiki = _cleanWiki(res['wiki'] is Map ? res['wiki']['summary'] : null);
    final tags = <String>[];
    final rawTags = res['tags'];
    if (rawTags is Map && rawTags['tag'] is List) {
      for (final t in rawTags['tag'] as List) {
        if (t is Map && t['name'] is String) {
          tags.add(t['name'] as String);
        }
      }
    }
    return (wiki: wiki, tags: tags);
  }

  /// MusicBrainz lookup with the same deadline as the Last.fm one, so a
  /// slow service can never hold the panel open.
  Future<MusicBrainzRelease?> _startMusicBrainz(
    MusicBrainzService musicbrainz,
    String artist,
    String album,
    String year,
  ) async {
    try {
      return await musicbrainz
          .lookupRelease(artist, album, year: year)
          .timeout(_lookupTimeout);
    } catch (_) {
      return null;
    }
  }

  /// Strips the Last.fm wiki markup down to readable text. Last.fm
  /// returns the summary as either raw wiki text ("The first album by X,
  /// released … <a href="…">Read more</a>.") or as a `{"#text": …}`
  /// wrapper, so both shapes are unwrapped.
  String _cleanWiki(Object? raw) {
    var text = '';
    if (raw is Map) {
      final inner = raw['#text'] ?? raw['summary'] ?? raw['content'];
      if (inner is String) text = inner;
    } else if (raw is String) {
      text = raw;
    }
    if (text.isEmpty) return '';
    var s = text.replaceAll(RegExp(r'<a [^>]*>.*?</a>', dotAll: true), '');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = s
        .replaceAll(
          RegExp(r'Read more on Last\.(fm|com).*$', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Trim a dangling separator the tag stripper can leave behind.
    if (s.endsWith(',') || s.endsWith(';')) s = s.substring(0, s.length - 1);
    return s;
  }

  Widget _row(
    BuildContext context,
    ThemeData theme,
    String label,
    String value,
  ) => _infoRow(theme, label, value);

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme ?? Theme.of(context);
    final album = widget.album;
    final ytDescription = album.description.trim();

    Widget buildAbout(String text) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'About',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(text, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
        Divider(color: theme.colorScheme.surfaceContainerHigh, height: 1),
      ],
    );

    // ---------- About + facts ----------
    // YouTube Music's own description when the page had one, otherwise
    // the Last.fm summary.
    final future = _future;
    if (future == null) {
      final rows = <Widget>[
        if (ytDescription.isNotEmpty) buildAbout(ytDescription),
      ];
      _appendFacts(album, rows, theme);
      _appendMusicBrainz(rows, theme);
      return _buildBody(theme, rows, false);
    }

    return FutureBuilder<_LastFmAlbum>(
      future: future,
      builder: (context, snapshot) {
        final info = snapshot.data ?? (wiki: '', tags: <String>[]);
        // The rows are rebuilt here, from scratch, on every snapshot:
        // the closure must never share a list with an earlier build, or
        // the facts would be appended once per rebuild.
        final rows = <Widget>[
          // Last.fm summary only fills an empty About section.
          if (ytDescription.isNotEmpty)
            buildAbout(ytDescription)
          else if (snapshot.connectionState != ConnectionState.waiting &&
              info.wiki.isNotEmpty)
            buildAbout(info.wiki),
        ];
        if (snapshot.connectionState != ConnectionState.waiting &&
            info.tags.isNotEmpty) {
          rows.add(_row(context, theme, 'Tags', info.tags.take(12).join(', ')));
        }
        _appendFacts(album, rows, theme);
        _appendMusicBrainz(rows, theme);
        return _buildBody(
          theme,
          rows,
          snapshot.connectionState == ConnectionState.waiting,
        );
      },
    );
  }

  /// Renders the assembled rows. A spinner shows only when the album
  /// carries nothing at all yet and the lookup is still running, so the
  /// dialog is never blank-but-alive; once the facts render the panel is
  /// complete and no overlay is needed.
  Widget _buildBody(ThemeData theme, List<Widget> rows, bool loading) {
    if (rows.isEmpty) {
      if (loading) {
        return Center(
          child: M3ELoadingIndicator(
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            color: theme.colorScheme.onSurfaceVariant,
          ),
        );
      }
      return Center(
        child: Text(
          'No info available.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return _list(theme, rows);
  }

  /// Year, release kind, track count and runtime; artist when the page
  /// carried one.
  void _appendFacts(AlbumDetail album, List<Widget> rows, ThemeData theme) {
    final year = album.year.trim();
    if (year.isNotEmpty) {
      rows.add(_row(context, theme, 'Year', year));
    }
    final kind = _kindLabel(album.kind);
    if (kind.isNotEmpty) {
      rows.add(_row(context, theme, 'Type', kind));
    }
    final count = album.tracks.length;
    if (count > 0) {
      final runtime = _totalRuntime(album.tracks);
      final value = runtime.isEmpty
          ? '$count songs'
          : '$count songs · $runtime';
      rows.add(_row(context, theme, 'Tracks', value));
    }
    final artist = widget.artist?.name.trim() ?? '';
    if (artist.isNotEmpty) {
      rows.add(_row(context, theme, 'Artist', artist));
    }
  }

  /// Adds the MusicBrainz facts (release date, label, country, type) when
  /// the lookup found a release.
  void _appendMusicBrainz(List<Widget> rows, ThemeData theme) {
    final future = _mbFuture;
    if (future == null) return;
    rows.add(
      _MusicBrainzRows(
        future: future,
        theme: theme,
        showType: widget.album.kind == null,
      ),
    );
  }

  Widget _list(ThemeData theme, List<Widget> rows) {
    return fm.SelectableRegion(
      selectionControls: emptyTextSelectionControls,
      child: SilkyListView(
        scrollSpeed: 1.5,
        silkyScrollDuration: const Duration(milliseconds: 700),
        animationCurve: Curves.easeOutQuart,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: rows,
      ),
    );
  }
}

/// One fact row: small label over a selectable value, separated by a rule.
Widget _infoRow(ThemeData theme, String label, String value) {
  final scheme = theme.colorScheme;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            fm.SelectableRegion(
              selectionControls: emptyTextSelectionControls,
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value.isEmpty ? 'Unknown' : value,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
      Divider(color: scheme.surfaceContainerHigh, height: 1),
    ],
  );
}

/// MusicBrainz facts appended once the release lookup lands.
class _MusicBrainzRows extends StatelessWidget {
  const _MusicBrainzRows({
    required this.future,
    required this.theme,
    this.showType = false,
  });

  final Future<MusicBrainzRelease?> future;
  final ThemeData theme;

  /// Whether to show a Type row: only when YouTube Music didn't classify
  /// the album itself.
  final bool showType;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MusicBrainzRelease?>(
      future: future,
      builder: (context, snapshot) {
        final release = snapshot.data;
        if (release == null) return const SizedBox.shrink();
        final type = [
          if (release.primaryType.isNotEmpty) release.primaryType,
          ...release.secondaryTypes,
        ].join(' · ');
        final rows = <Widget>[
          if (release.date.isNotEmpty)
            _infoRow(theme, 'Released', _formatReleaseDate(release.date)),
          if (release.label.isNotEmpty) _infoRow(theme, 'Label', release.label),
          if (release.country.isNotEmpty)
            _infoRow(theme, 'Country', release.country),
          if (showType && type.isNotEmpty) _infoRow(theme, 'Type', type),
        ];
        if (rows.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        );
      },
    );
  }
}

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Formats a MusicBrainz date (`YYYY`, `YYYY-MM` or `YYYY-MM-DD`) for
/// display, leaving anything unexpected as-is.
String _formatReleaseDate(String date) {
  final parts = date.split('-');
  if (parts.length == 3) {
    final day = int.tryParse(parts[2]);
    final month = int.tryParse(parts[1]);
    if (day != null && month != null && month >= 1 && month <= 12) {
      return '$day ${_months[month - 1]} ${parts[0]}';
    }
    return date;
  }
  if (parts.length == 2) {
    final month = int.tryParse(parts[1]);
    if (month != null && month >= 1 && month <= 12) {
      return '${_months[month - 1]} ${parts[0]}';
    }
  }
  return date;
}
