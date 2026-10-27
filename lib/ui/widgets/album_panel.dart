// Shared album/playlist panel: left art column (vertically centered),
// right sortable track list. One view for album detail, playlist detail
// and the open library playlist, mirroring Kotlin `AlbumPanel`.

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/models/models.dart';

import 'package:m3e_core/m3e_core.dart';

import '../app_state.dart';
import '../theme.dart';
import 'artwork_image.dart';
import 'loading_placeholders.dart';
import 'track_row.dart';

String _fmtDur(int sec) =>
    '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';

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

  /// Collage sources; more than one renders a 2x2 grid like Kotlin
  /// `PlaylistArt`, a single entry falls back to [art].
  final List<String> arts;

  /// Creator credit; see [_OwnerRow] for avatar/click rules.
  final ArtistRef? owner;

  /// Avatar fallback when the owner has no channel (e.g. own account).
  final String? ownerAvatarUrl;
  final List<Track> tracks;
  final bool numbered;
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
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    final account = context.select<AppState, String?>((s) => s.account);
    final tracks = _sorted;
    final totalSec = widget.tracks.fold(0, (n, t) => n + t.durationSec);

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

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 320,
          height: double.infinity,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: screenPadding,
                  vertical: 16,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight > 32
                        ? constraints.maxHeight - 32
                        : 0,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _PlaylistArt(
                        art: effectiveArt,
                        arts: effectiveArts,
                        size: 280,
                        tracks: widget.tracks,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.title,
                        style: Theme.of(context).textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                      if (widget.owner != null &&
                          widget.owner!.name.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _OwnerRow(
                          owner: widget.owner,
                          fallbackAvatarUrl: widget.ownerAvatarUrl,
                        ),
                      ],
                      if (widget.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.subtitle,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        '${widget.tracks.length} songs'
                        '${totalSec > 0 ? ' • ${_fmtDur(totalSec)}' : ''}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (widget.description.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          widget.description.length > 280
                              ? '${widget.description.substring(0, 280)}…'
                              : widget.description,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          M3EFilledButton.icon(
                            onPressed: tracks.isEmpty
                                ? null
                                : () => state.playSongs(tracks, 0),
                            icon: const Icon(
                              Icons.play_arrow_rounded,
                              size: 32,
                            ),
                            label: const Text('Play'),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.shuffle_rounded),
                            tooltip: 'Shuffle',
                            onPressed: tracks.isEmpty
                                ? null
                                : () => state.playShuffled(tracks),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  screenPadding,
                  widget.topPadding,
                  screenPadding,
                  0,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: Builder(
                    builder: (context) {
                      final scheme = Theme.of(context).colorScheme;
                      return M3EToggleButtonGroup(
                        type: M3EButtonGroupType.connected,
                        size: M3EButtonSize.sm,
                        semanticLabel: 'Sort order',
                        selectedIndex: _sort,
                        onSelectedIndexChanged: (i) {
                          // Selection-required: tapping the active sort
                          // keeps it.
                          if (i == null) return;
                          setState(() => _sort = i);
                        },
                        actions: const [
                          M3EToggleButtonGroupAction(
                            label: Text(
                              'Default',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          M3EToggleButtonGroupAction(
                            label: Text(
                              'Title',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          M3EToggleButtonGroupAction(
                            label: Text(
                              'Artist',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          M3EToggleButtonGroupAction(
                            label: Text(
                              'Duration',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                        decoration: toggleButtonGroupDecoration(scheme),
                      );
                    },
                  ),
                ),
              ),
              Expanded(
                child: widget.listLoading && tracks.isEmpty
                    // Songs on their way: skeleton rows in the same
                    // list, so they reveal in place.
                    ? Skeletonizer(
                        enabled: true,
                        enableSwitchAnimation: true,
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(
                            screenPadding,
                            0,
                            screenPadding,
                            screenPadding + playerBarClearance,
                          ),
                          itemCount: placeholderTracks.length,
                          itemBuilder: (context, i) {
                            final t = placeholderTracks[i];
                            return TrackRow(
                              track: t,
                              index: widget.numbered ? i + 1 : null,
                              onPlay: () {},
                              rateable: account != null,
                              showPlaylists: true,
                              removable: widget.removable,
                            );
                          },
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          screenPadding,
                          0,
                          screenPadding,
                          screenPadding + playerBarClearance,
                        ),
                        itemCount: tracks.length,
                        itemBuilder: (context, i) {
                          final t = tracks[i];
                          var idx = tracks.indexWhere(
                            (e) => e.videoId == t.videoId,
                          );
                          if (idx < 0) idx = 0;
                          return TrackRow(
                            track: t,
                            index: widget.numbered ? i + 1 : null,
                            playing: t.videoId == playingId,
                            onPlay: () => state.playSongs(tracks, idx),
                            rateable: account != null,
                            showPlaylists: true,
                            showViews: widget.showViews,
                            removable: widget.removable,
                            onRemove: widget.onRemoveTrack == null
                                ? null
                                : () => widget.onRemoveTrack!(t),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Playlist artwork: 2x2 collage when several arts are given, single
/// artwork otherwise. Port of Kotlin `PlaylistArt`.
class _PlaylistArt extends StatelessWidget {
  const _PlaylistArt({
    required this.art,
    required this.arts,
    required this.size,
    this.tracks = const [],
  });

  final String? art;
  final List<String> arts;
  final double size;

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
    if (arts.length > 1) {
      final tile = size / 2;
      Widget cell(int index) =>
          _cell(index < arts.length ? arts[index] : null, tile);
      return ClipRRect(
        borderRadius: BorderRadius.circular(cardRadius),
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
      radius: cardRadius,
      iconSize: 64,
    );
  }
}

/// Creator row: channel avatar + name, clickable only for verified artist
/// pages. Plain names, own channel and non-channel credits (compilations)
/// render as static text, mirroring Kotlin's author handling.
class _OwnerRow extends StatefulWidget {
  const _OwnerRow({required this.owner, required this.fallbackAvatarUrl});

  final ArtistRef? owner;
  final String? fallbackAvatarUrl;

  @override
  State<_OwnerRow> createState() => _OwnerRowState();
}

class _OwnerRowState extends State<_OwnerRow> {
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
  void didUpdateWidget(_OwnerRow old) {
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
    final avatarUrl =
        _avatar ??
        ((widget.fallbackAvatarUrl != null &&
                widget.fallbackAvatarUrl!.isNotEmpty)
            ? widget.fallbackAvatarUrl
            : null);
    final avatar = avatarUrl != null && avatarUrl.isNotEmpty
        ? ArtworkImage(avatarUrl, size: 24, circular: true, iconSize: 12)
        : Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.surfaceContainerHigh,
            ),
            alignment: Alignment.center,
            child: Text(
              owner.name.substring(0, 1).toUpperCase(),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          );
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
                ? Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w500,
                  )
                : Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
    if (!_clickable) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: row,
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => context.read<AppState>().openArtist(owner),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: row,
      ),
    );
  }
}
