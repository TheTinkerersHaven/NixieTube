// Shared album/playlist panel: left art column (vertically centered),
// right sortable track list. One view for album detail, playlist detail
// and the open library playlist.

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import 'artwork_image.dart';
import 'album_panel_desktop.dart';
import 'album_panel_mobile.dart';

/// Album-style header reused for albums, playlists and the open library
/// playlist: art column + owner row with creator avatar.
class AlbumPlaylistView extends StatefulWidget {
  const AlbumPlaylistView({
    super.key,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.art,
    this.arts = const [],
    required this.owner,
    this.ownerAvatarUrl,
    required this.tracks,
    required this.numbered,
    this.isAlbum = false,
    this.topPadding = 64,
    this.listLoading = false,
    this.removable = false,
    this.onRemoveTrack,
    this.showViews = false,
  });

  final String title;
  final String subtitle;
  final String description;
  final String? art;

  /// Collage sources; more than one renders a 2x2 grid
  /// `PlaylistArt`, a single entry falls back to [art].
  final List<String> arts;

  /// Creator credit; see [_OwnerRow] for avatar/click rules.
  final ArtistRef? owner;

  /// Avatar fallback when the owner has no channel (e.g. own account).
  final String? ownerAvatarUrl;
  final List<Track> tracks;
  final bool numbered;

  /// True on album pages: the mobile header labels the card "Album"
  /// and the track rows drop the repeated cover and album name.
  final bool isAlbum;
  final double topPadding;

  /// Show a spinner when [tracks] is empty and still loading.
  final bool listLoading;

  /// When true each row shows a remove action (user-editable playlists).
  final bool removable;

  /// Invoked to remove a track; only used when [removable] is true.
  final void Function(Track track)? onRemoveTrack;

  /// Shows each row's play count when the backend provided one.
  final bool showViews;

  @override
  State<AlbumPlaylistView> createState() => _AlbumPlaylistViewState();
}

class _AlbumPlaylistViewState extends State<AlbumPlaylistView> {
  int _sort = 0;
  String? _lastArtUrl;

  // Memoized sort: re-sorts only when the sort mode or the source list
  // identity changes, so rebuilds (playing-id, account, parent) don't
  // re-copy and re-sort the queue on every frame.
  int _cachedSort = -1;
  List<Track>? _cachedSource;
  List<Track>? _cachedSorted;

  List<Track> get _sorted {
    if (_cachedSort == _sort && identical(_cachedSource, widget.tracks)) {
      return _cachedSorted!;
    }
    _cachedSort = _sort;
    _cachedSource = widget.tracks;
    final tracks = List<Track>.of(widget.tracks);
    switch (_sort) {
      case 1:
        tracks.sort((a, b) => a.title.compareTo(b.title));
      case 2:
        tracks.sort((a, b) => a.artistNames().compareTo(b.artistNames()));
      case 3:
        // Longest first, mirroring the reference client.
        tracks.sort((a, b) => b.durationSec.compareTo(a.durationSec));
    }
    return _cachedSorted = tracks;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppState>();
    // Trigger palette computation when the artwork URL changes.
    final trackCovers = widget.tracks
        .map((t) => t.displayArtwork)
        .whereType<String>()
        .where((u) => u.isNotEmpty)
        .toSet()
        .toList();
    final artUrl =
        widget.art ?? (trackCovers.isNotEmpty ? trackCovers.first : null);
    if (artUrl != _lastArtUrl) {
      _lastArtUrl = artUrl;
      unawaited(state.ensurePalette(artUrl));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _sorted;

    final trackCovers = widget.tracks
        .map((t) => t.displayArtwork)
        .whereType<String>()
        .where((u) => u.isNotEmpty)
        .toSet()
        .toList();
    final effectiveArt =
        widget.art ?? (trackCovers.isNotEmpty ? trackCovers.first : null);
    final effectiveArts = widget.arts.isNotEmpty
        ? widget.arts
        : (widget.art == null && trackCovers.length >= 4
              ? trackCovers.take(4).toList()
              : const <String>[]);

    final compact = isCompactLayout(context);
    if (compact) {
      return AlbumPlaylistViewMobile(
        title: widget.title,
        description: widget.description,
        effectiveArt: effectiveArt,
        effectiveArts: effectiveArts,
        owner: widget.owner,
        ownerAvatarUrl: widget.ownerAvatarUrl,
        tracks: widget.tracks,
        sortedTracks: tracks,
        sort: _sort,
        onSortChanged: (i) => setState(() => _sort = i),
        numbered: widget.numbered,
        isAlbum: widget.isAlbum,
        listLoading: widget.listLoading,
        removable: widget.removable,
        onRemoveTrack: widget.onRemoveTrack,
        showViews: widget.showViews,
      );
    }

    return AlbumPlaylistViewDesktop(
      title: widget.title,
      subtitle: widget.subtitle,
      description: widget.description,
      effectiveArt: effectiveArt,
      effectiveArts: effectiveArts,
      owner: widget.owner,
      ownerAvatarUrl: widget.ownerAvatarUrl,
      tracks: widget.tracks,
      sortedTracks: tracks,
      sort: _sort,
      onSortChanged: (i) => setState(() => _sort = i),
      numbered: widget.numbered,
      topPadding: widget.topPadding,
      listLoading: widget.listLoading,
      removable: widget.removable,
      onRemoveTrack: widget.onRemoveTrack,
      showViews: widget.showViews,
    );
  }
}

/// Playlist artwork: 2x2 collage when several arts are given, single
/// artwork otherwise.
class PlaylistArt extends StatelessWidget {
  const PlaylistArt({
    super.key,
    required this.art,
    required this.arts,
    required this.size,
    this.tracks = const [],
    this.radius,
  });

  final String? art;
  final List<String> arts;
  final double size;

  /// Corner radius; defaults to [cardRadius]. Pass 0 when an outer
  /// clip already rounds the corners (e.g. a header card).
  final double? radius;

  /// Tracks behind the collage sources, when known. Cells reuse the
  /// track tile (square-cover resolution with album-art fallback) so
  /// small collage sources resolve to sharp art instead of grain;
  /// unmatched sources render plainly as before.
  final List<Track> tracks;

  Widget _cell(String? url, double tile, {double? radius, double? iconSize}) {
    Track? track;
    if (url != null) {
      for (final t in tracks) {
        if (t.displayArtwork == url) {
          track = t;
          break;
        }
      }
    }
    final r = radius ?? 0;
    final i = iconSize ?? tile / 4;
    if (track != null) {
      return ArtworkImage(
        track.displayArtwork,
        size: tile,
        radius: r,
        iconSize: i,
        squareCoverKey: track.videoId,
      );
    }
    return ArtworkImage(url, size: tile, radius: r, iconSize: i);
  }

  @override
  Widget build(BuildContext context) {
    final r = radius ?? cardRadius;
    if (arts.length > 1) {
      final tile = size / 2;
      Widget cell(int index) =>
          _cell(index < arts.length ? arts[index] : null, tile);
      return ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: SizedBox(
          width: size,
          height: size,
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: cell(0)),
                    Expanded(child: cell(1)),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: cell(2)),
                    Expanded(child: cell(3)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return _cell(
      arts.isNotEmpty ? arts.first : art,
      size,
      radius: r,
      iconSize: 64,
    );
  }
}

/// Creator row: channel avatar + name, clickable only for verified artist
/// pages. Plain names, own channel and non-channel credits (compilations)
/// render as static text.
class OwnerRow extends StatefulWidget {
  const OwnerRow({
    super.key,
    required this.owner,
    required this.fallbackAvatarUrl,
    this.avatarSize = 24,
    this.textStyle,
    this.padding,
  });

  final ArtistRef? owner;
  final String? fallbackAvatarUrl;

  /// Avatar diameter; the letter fallback scales with it.
  final double avatarSize;

  /// Base style for the name; the clickable/color rules still apply
  /// on top via `copyWith`.
  final TextStyle? textStyle;

  /// Outer padding; defaults to a small hit-area padding.
  final EdgeInsetsGeometry? padding;

  @override
  State<OwnerRow> createState() => _OwnerRowState();
}

class _OwnerRowState extends State<OwnerRow> {
  String? _avatar;
  bool _clickable = false;
  String? _resolvedId;

  String? get _channelId {
    final id = widget.owner?.browseId;
    return (id != null && id.startsWith('UC')) ? id : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(OwnerRow old) {
    super.didUpdateWidget(old);
    if (old.owner?.browseId != widget.owner?.browseId ||
        old.fallbackAvatarUrl != widget.fallbackAvatarUrl) {
      _load();
    }
  }

  void _load() {
    final channelId = _channelId;
    if (channelId == null) {
      setState(() {
        _avatar = widget.fallbackAvatarUrl;
        _clickable = false;
        _resolvedId = null;
      });
      return;
    }
    if (_resolvedId == channelId) return;
    _resolvedId = channelId;
    _avatar = widget.fallbackAvatarUrl;
    _clickable = false;

    final state = context.read<AppState>();
    unawaited(
      state.artistAvatar(channelId).then((url) {
        if (!mounted || _channelId != channelId) return;
        if (url != null && url.isNotEmpty) {
          setState(() => _avatar = url);
        }
      }),
    );

    unawaited(
      state.isAuthorClickable(channelId).then((isArtist) {
        if (!mounted || _channelId != channelId) return;
        setState(() => _clickable = isArtist);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final owner = widget.owner;
    if (owner == null || owner.name.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final avatarSize = widget.avatarSize;
    final avatarUrl =
        _avatar ??
        ((widget.fallbackAvatarUrl != null &&
                widget.fallbackAvatarUrl!.isNotEmpty)
            ? widget.fallbackAvatarUrl
            : null);
    final avatar = avatarUrl != null && avatarUrl.isNotEmpty
        ? ArtworkImage(
            avatarUrl,
            size: avatarSize,
            circular: true,
            iconSize: avatarSize / 2,
          )
        : Container(
            width: avatarSize,
            height: avatarSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.surfaceContainerHigh,
            ),
            alignment: Alignment.center,
            child: Text(
              owner.name.substring(0, 1).toUpperCase(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontSize: avatarSize / 2,
              ),
            ),
          );
    final baseStyle =
        widget.textStyle ?? Theme.of(context).textTheme.bodyMedium;
    final row = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        avatar,
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            owner.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _clickable
                ? baseStyle?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w500,
                  )
                : baseStyle?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
    final padding =
        widget.padding ??
        (_clickable
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
            : const EdgeInsets.symmetric(vertical: 4));
    if (!_clickable) {
      return Padding(padding: padding, child: row);
    }
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => context.read<AppState>().openArtist(owner),
      child: Padding(padding: padding, child: row),
    );
  }
}
