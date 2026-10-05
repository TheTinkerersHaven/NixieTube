// Shared album/playlist panel: left art column (vertically centered),
// right sortable track list. One view for album detail, playlist detail
// and the open library playlist, mirroring Kotlin `AlbumPanel`.

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import 'artwork_image.dart';
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

  @override
  State<AlbumPlaylistView> createState() => _AlbumPlaylistViewState();
}

class _AlbumPlaylistViewState extends State<AlbumPlaylistView> {
  int _sort = 0;
  String? _lastArtUrl;

  List<Track> get _sorted {
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
    return tracks;
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
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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
                          FilledButton.icon(
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
                child: Builder(builder: (context) {
                  // Measure the widest label (bold, as the
                  // selected state renders it) so every segment
                  // is exactly as wide as the longest one —
                  // the control must not resize when the
                  // selection changes.
                  final style = Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(fontWeight: FontWeight.w600);
                  final width = ['Default', 'Title', 'Artist', 'Duration']
                      .map((s) => _textWidth(s, style))
                      .fold(
                        0.0,
                        (m, w) => w > m ? w : m,
                      );
                  return SegmentedButton<int>(
                    segments: [
                      ButtonSegment(
                        value: 0,
                        label: _FixedLabel('Default', width),
                      ),
                      ButtonSegment(
                        value: 1,
                        label: _FixedLabel('Title', width),
                      ),
                      ButtonSegment(
                        value: 2,
                        label: _FixedLabel('Artist', width),
                      ),
                      ButtonSegment(
                        value: 3,
                        label: _FixedLabel('Duration', width),
                      ),
                    ],
                    selected: {_sort},
                    onSelectionChanged: (s) =>
                        setState(() => _sort = s.first),
                  );
                }),
              ),
              Expanded(
                child: widget.listLoading && tracks.isEmpty
                    ? const Center(child: CircularProgressIndicator())
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
  });

  final String? art;
  final List<String> arts;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (arts.length > 1) {
      final tile = size / 2;
      Widget cell(int index) => ArtworkImage(
        index < arts.length ? arts[index] : null,
        size: tile,
        radius: 0,
        iconSize: tile / 4,
      );
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
    return ArtworkImage(
      arts.isNotEmpty ? arts.first : art,
      size: size,
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
    state.artistAvatar(channelId).then((url) {
      if (!mounted || _channelId != channelId) return;
      if (url != null && url.isNotEmpty) {
        setState(() => _avatar = url);
      }
    });

    state.isAuthorClickable(channelId).then((isArtist) {
      if (!mounted || _channelId != channelId) return;
      setState(() => _clickable = isArtist);
    });
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

/// Sort-segment label pinned to [width] so the
/// SegmentedButton keeps a constant overall width
/// whichever segment is selected.
class _FixedLabel extends StatelessWidget {
  const _FixedLabel(this.text, this.width);

  final String text;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        textAlign: TextAlign.center,
        overflow: TextOverflow.visible,
      ),
    );
  }
}

/// Width of [text] rendered in [style], for sizing
/// segmented-button labels.
double _textWidth(String text, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}
