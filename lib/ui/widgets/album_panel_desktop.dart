// Desktop album and playlist panel: 320px fixed left art and metadata column,
// and right sortable track list.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../format.dart';
import '../theme.dart';
import 'album_panel.dart';
import 'loading_placeholders.dart';
import 'track_row.dart';

/// Desktop 2-column layout for albums and playlists.
class AlbumPlaylistViewDesktop extends StatelessWidget {
  const AlbumPlaylistViewDesktop({
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
    required this.topPadding,
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
  final double topPadding;
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
                      PlaylistArt(
                        art: effectiveArt,
                        arts: effectiveArts,
                        size: 280,
                        tracks: tracks,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                      if (owner != null && owner!.name.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        OwnerRow(
                          owner: owner,
                          fallbackAvatarUrl: ownerAvatarUrl,
                        ),
                      ],
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
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
                        '${tracks.length} songs'
                        '${totalSec > 0 ? ' • ${formatDuration(totalSec)}' : ''}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (description.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          description.length > 280
                              ? '${description.substring(0, 280)}…'
                              : description,
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
                            onPressed: sortedTracks.isEmpty
                                ? null
                                : () => state.playSongs(sortedTracks, 0),
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
                            onPressed: sortedTracks.isEmpty
                                ? null
                                : () => state.playShuffled(sortedTracks),
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
                  topPadding,
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
                        selectedIndex: sort,
                        onSelectedIndexChanged: (i) {
                          if (i == null) return;
                          onSortChanged(i);
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
                child: listLoading && sortedTracks.isEmpty
                    ? Skeletonizer(
                        enabled: true,
                        enableSwitchAnimation: true,
                        child: ListView.builder(
                          padding: EdgeInsets.fromLTRB(
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
                              index: numbered ? i + 1 : null,
                              onPlay: () {},
                              rateable: account != null,
                              showPlaylists: true,
                              removable: removable,
                            );
                          },
                        ),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.fromLTRB(
                          screenPadding,
                          0,
                          screenPadding,
                          screenPadding + playerBarClearance,
                        ),
                        itemCount: sortedTracks.length,
                        itemBuilder: (context, i) {
                          final t = sortedTracks[i];
                          var idx = sortedTracks.indexWhere(
                            (e) => e.videoId == t.videoId,
                          );
                          if (idx < 0) idx = 0;
                          return TrackRow(
                            track: t,
                            index: numbered ? i + 1 : null,
                            playing: t.videoId == playingId,
                            onPlay: () => state.playSongs(sortedTracks, idx),
                            rateable: account != null,
                            showPlaylists: true,
                            showViews: showViews,
                            removable: removable,
                            onRemove: onRemoveTrack == null
                                ? null
                                : () => onRemoveTrack!(t),
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
