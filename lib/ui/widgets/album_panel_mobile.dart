// Mobile album and playlist panel: hero glass card, action row and
// tracklist header scrolling as one unified view with the tracks.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../format.dart';
import '../theme.dart';
import 'album_panel.dart';
import 'loading_placeholders.dart';
import 'track_row.dart';

/// Horizontal outer margin shared by the hero card, the action row,
/// the tracklist header and the track rows.
const double _headerMargin = 16;

/// Mobile stacked layout for albums and playlists, scrolling as a single
/// unified view with the tracks.
class AlbumPlaylistViewMobile extends StatelessWidget {
  const AlbumPlaylistViewMobile({
    super.key,
    required this.title,
    required this.description,
    required this.effectiveArt,
    required this.effectiveArts,
    required this.owner,
    required this.ownerAvatarUrl,
    required this.tracks,
    required this.sortedTracks,
    required this.sort,
    required this.onSortChanged,
    required this.numbered,
    required this.isAlbum,
    required this.listLoading,
    required this.removable,
    required this.onRemoveTrack,
    required this.showViews,
  });

  final String title;
  final String description;
  final String? effectiveArt;
  final List<String> effectiveArts;
  final ArtistRef? owner;
  final String? ownerAvatarUrl;
  final List<Track> tracks;
  final List<Track> sortedTracks;
  final int sort;
  final ValueChanged<int> onSortChanged;
  final bool numbered;
  final bool isAlbum;
  final bool listLoading;
  final bool removable;
  final void Function(Track track)? onRemoveTrack;
  final bool showViews;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    final account = context.select<AppState, String?>((s) => s.account);
    final totalSec = tracks.fold(0, (n, t) => n + t.durationSec);

    const sortLabels = ['Default', 'Title', 'Artist', 'Duration'];

    // Compact "Sort: <mode>" pill chip. Four labels across a 400dp
    // phone would each get ~90dp, so the options live in the menu and
    // the chip keeps only the current one.
    Widget sortChip() {
      return SizedBox(
        height: 32,
        child: M3EPopupMenuButton<int>(
          tooltip: 'Sort order',
          initialValue: sort,
          itemBuilder: (context) => [
            for (var i = 0; i < sortLabels.length; i++)
              M3EPopupMenuItem<int>(value: i, child: Text(sortLabels[i])),
          ],
          onSelected: onSortChanged,
          // A compact pill trigger: tight 32dp box, snug horizontal
          // padding (the button's own touch-target minimum would
          // otherwise keep it taller).
          triggerDecoration: const M3EButtonDecoration(
            minimumSize: Size(0, 32),
            padding: EdgeInsets.symmetric(horizontal: 12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Explicit tonal foreground: an unstyled label would take
              // the dark theme's onSurface (white) and vanish on light
              // seeds like peach.
              Icon(
                Icons.sort_rounded,
                size: 16,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 6),
              Text(
                'Sort: ${sortLabels[sort]}',
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: scheme.onSecondaryContainer),
              ),
            ],
          ),
        ),
      );
    }

    final stats =
        '${isAlbum ? 'Album' : 'Playlist'} • ${tracks.length} songs'
        '${totalSec > 0 ? ' • ${formatDuration(totalSec)}' : ''}';
    final countLabel = '${tracks.length} songs';

    final header = Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The hero: one glass card with the padded, rounded cover on
          // the left and the name/artist/meta stacked to its right.
          _AlbumHeaderCard(
            title: title,
            owner: owner,
            ownerAvatarUrl: ownerAvatarUrl,
            stats: stats,
            art: effectiveArt,
            arts: effectiveArts,
            tracks: tracks,
          ),
          const SizedBox(height: 12),
          // Play and Shuffle: two equal-width stadium pills.
          Row(
            children: [
              Expanded(
                child: M3EFilledButton.icon(
                  onPressed: sortedTracks.isEmpty
                      ? null
                      : () =>
                            state.playSongs(sortedTracks, 0, sourceName: title),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play'),
                  size: M3EButtonSize.fromBase(
                    M3EButtonSize.sm,
                    height: 44,
                    iconSize: 24,
                  ),
                  shape: M3EButtonShape.round,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: M3EFilledButton.tonalIcon(
                  onPressed: sortedTracks.isEmpty
                      ? null
                      : () =>
                            state.playShuffled(sortedTracks, sourceName: title),
                  icon: const Icon(Icons.shuffle_rounded),
                  label: const Text('Shuffle'),
                  size: M3EButtonSize.fromBase(
                    M3EButtonSize.sm,
                    height: 44,
                    iconSize: 24,
                  ),
                  shape: M3EButtonShape.round,
                  // Plain tonal: the theme's secondaryContainer +
                  // onSecondaryContainer pair keeps the button clearly
                  // tappable on every seed (a translucent wash read as
                  // disabled gray on light seeds like peach).
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Tracklist header: song count left, sort chip right.
          SizedBox(
            height: 36,
            child: Row(
              children: [
                Text(
                  countLabel,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
                const Spacer(),
                sortChip(),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );

    if (listLoading && sortedTracks.isEmpty) {
      return Skeletonizer(
        enabled: true,
        enableSwitchAnimation: true,
        child: SilkyListView.builder(
          padding: EdgeInsets.fromLTRB(
            _headerMargin,
            0,
            _headerMargin,
            _headerMargin + playerBarClearance,
          ),
          itemCount: placeholderTracks.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) return header;
            final t = placeholderTracks[i - 1];
            return TrackRow(
              track: t,
              index: numbered ? i : null,
              albumRows: isAlbum,
              onPlay: () {},
              rateable: account != null,
              showPlaylists: true,
              removable: removable,
            );
          },
        ),
      );
    }

    return SilkyListView.builder(
      padding: EdgeInsets.fromLTRB(
        _headerMargin,
        0,
        _headerMargin,
        _headerMargin + playerBarClearance,
      ),
      itemCount: sortedTracks.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return header;
        final t = sortedTracks[i - 1];
        var idx = sortedTracks.indexWhere((e) => e.videoId == t.videoId);
        if (idx < 0) idx = 0;
        return TrackRow(
          track: t,
          index: numbered ? i : null,
          albumRows: isAlbum,
          playing: t.videoId == playingId,
          onPlay: () => state.playSongs(sortedTracks, idx, sourceName: title),
          rateable: account != null,
          showPlaylists: true,
          showViews: showViews,
          removable: removable,
          onRemove: onRemoveTrack == null ? null : () => onRemoveTrack!(t),
        );
      },
    );
  }
}

/// Hero glass card for phones: a 20dp-radius translucent white card
/// (same glass as the Now Playing up-next/lyrics/info bar) with a
/// hairline border, a 120dp rounded cover padded in on the left, and
/// the album name, artist row and meta line stacked — vertically
/// centered, 6dp apart — to its right.
class _AlbumHeaderCard extends StatelessWidget {
  const _AlbumHeaderCard({
    required this.title,
    required this.owner,
    required this.ownerAvatarUrl,
    required this.stats,
    required this.art,
    required this.arts,
    required this.tracks,
  });

  final String title;
  final ArtistRef? owner;
  final String? ownerAvatarUrl;
  final String stats;
  final String? art;
  final List<String> arts;
  final List<Track> tracks;

  static const double _radius = 20;
  static const double _padding = 16;
  static const double _artSize = 120;
  static const double _artRadius = 12;
  static const double _gap = 16;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(_radius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      padding: const EdgeInsets.all(_padding),
      child: Row(
        children: [
          SizedBox(
            width: _artSize,
            height: _artSize,
            child: PlaylistArt(
              art: art,
              arts: arts,
              size: _artSize,
              tracks: tracks,
              radius: _artRadius,
            ),
          ),
          const SizedBox(width: _gap),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    height: 1.15,
                    color: scheme.onSurface,
                  ),
                ),
                if (owner != null && owner!.name.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  OwnerRow(
                    owner: owner,
                    fallbackAvatarUrl: ownerAvatarUrl,
                    avatarSize: 22,
                    textStyle: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500),
                    padding: EdgeInsets.zero,
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  stats,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
