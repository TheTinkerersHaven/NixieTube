// Mobile album and playlist panel: stacked header scrolling with the track list.

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

/// Mobile stacked layout for albums and playlists: cover art above
/// metadata and actions, scrolling as a single unified view with the tracks.
class AlbumPlaylistViewMobile extends StatelessWidget {
  const AlbumPlaylistViewMobile({
    super.key,
    required this.title,
    required this.subtitle,
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
    required this.listLoading,
    required this.removable,
    required this.onRemoveTrack,
    required this.showViews,
  });

  final String title;
  final String subtitle;
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
  final bool listLoading;
  final bool removable;
  final void Function(Track track)? onRemoveTrack;
  final bool showViews;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    final account = context.select<AppState, String?>((s) => s.account);
    final totalSec = tracks.fold(0, (n, t) => n + t.durationSec);
    final scheme = Theme.of(context).colorScheme;

    const sortLabels = ['Default', 'Title', 'Artist', 'Duration'];

    // One centered trigger opening a compact menu: four labels across a
    // 400dp phone would each get ~90dp, so the options live in the menu
    // and the row keeps only the current one.
    Widget sortControl() {
      return Center(
        child: M3EPopupMenuButton<int>(
          tooltip: 'Sort order',
          initialValue: sort,
          itemBuilder: (context) => [
            for (var i = 0; i < sortLabels.length; i++)
              M3EPopupMenuItem<int>(
                value: i,
                child: Text(sortLabels[i]),
              ),
          ],
          onSelected: onSortChanged,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sort_rounded, size: 18),
              const SizedBox(width: 8),
              Text('Sort: ${sortLabels[sort]}'),
            ],
          ),
        ),
      );
    }

    final header = Padding(
      // The track list already insets its rows by [screenPadding]; the
      // header rides inside that padding so the cover and title share
      // the tracks' left edge instead of sitting 20px further in.
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        children: [
          // Centered cover art
          Center(
            child: PlaylistArt(
              art: effectiveArt,
              arts: effectiveArts,
              size: 200,
              tracks: tracks,
            ),
          ),
          const SizedBox(height: 12),
          // Title
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          // Owner
          if (owner != null && owner!.name.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Center(
              child: OwnerRow(owner: owner, fallbackAvatarUrl: ownerAvatarUrl),
            ),
          ],
          // Subtitle
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 4),
          // Stats (song count, duration)
          Text(
            '${tracks.length} songs'
            '${totalSec > 0 ? ' • ${formatDuration(totalSec)}' : ''}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          // Description (compact)
          if (description.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              description.length > 180
                  ? '${description.substring(0, 180)}…'
                  : description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 14),
          // Play and Shuffle buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              M3EFilledButton.icon(
                onPressed: sortedTracks.isEmpty
                    ? null
                    : () => state.playSongs(sortedTracks, 0),
                icon: const Icon(Icons.play_arrow_rounded, size: 28),
                label: const Text('Play'),
              ),
              const SizedBox(width: 10),
              M3EOutlinedButton.icon(
                icon: const Icon(Icons.shuffle_rounded),
                label: const Text('Shuffle'),
                onPressed: sortedTracks.isEmpty
                    ? null
                    : () => state.playShuffled(sortedTracks),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Sort control: one compact row.
          sortControl(),
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
            screenPadding,
            0,
            screenPadding,
            screenPadding + playerBarClearance,
          ),
          itemCount: placeholderTracks.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) return header;
            final t = placeholderTracks[i - 1];
            return TrackRow(
              track: t,
              index: numbered ? i : null,
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
        screenPadding,
        0,
        screenPadding,
        screenPadding + playerBarClearance,
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
          playing: t.videoId == playingId,
          onPlay: () => state.playSongs(sortedTracks, idx),
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
