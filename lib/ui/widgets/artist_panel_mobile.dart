// Mobile artist panel: the content under the (shorter) collapsing
// banner hero — full-width pill action rows, compact top-song rows,
// the bio right after the songs and the rails last, all in the page's
// single scroll view.

import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import 'about_card.dart';
import 'rails.dart';
import 'track_row.dart';

/// How many top songs the phone page previews (one column of five).
const int _topSongsCap = 5;

/// Compact stacked content for the artist page on phones, rendered
/// under the banner hero by [ArtistScreen].
class ArtistPanelMobile extends StatelessWidget {
  const ArtistPanelMobile({super.key, required this.artist});

  final ArtistDetail artist;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    final signedIn = context.select<AppState, bool>((s) => s.account != null);
    final detailItem = context.select<AppState, BrowseItem?>(
      (s) => s.detailItem,
    );
    final subscribed = context.select<AppState, bool>(
      (s) =>
          s.detailItem == null ? false : s.isSubscribed(s.detailItem!.browseId),
    );
    final hasSongs = artist.topSongs.isNotEmpty;
    final hasBio = artist.description.trim().isNotEmpty;
    final showSubscribe = signedIn && detailItem != null;

    final seeAll = artist.songsPlaylistId == null
        ? null
        : () {
            final item = BrowseItem(
              title: 'Top songs',
              subtitle: artist.name,
              browseId: artist.songsPlaylistId!,
              browseParams: artist.songsPlaylistParams,
              thumbnails: artist.thumbnails,
            );
            state.openPlaylistById(
              item.browseId,
              params: item.browseParams,
              item: item,
            );
          };

    final onPlayAll = hasSongs
        ? () => unawaited(state.playArtistSongs(artist, false))
        : null;
    final onShuffle = hasSongs
        ? () => unawaited(state.playArtistSongs(artist, true))
        : null;
    final onMix = hasSongs
        ? () async {
            final res = await state.startArtistMix(artist);
            if (!context.mounted || res.movedOn) return;
            if (!res.loaded) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Playing — but the station failed to load. '
                    'Check your connection.',
                  ),
                ),
              );
            }
          }
        : null;

    final songs = artist.topSongs.take(_topSongsCap).toList();
    final scheme = Theme.of(context).colorScheme;

    // Every action lives in one full-width connected M3E button group:
    // Subscribe (when signed in) leads, filling the primary slot, and
    // the labeled Shuffle / Radio segments follow. Play all lives in the
    // Top songs header instead.
    Widget actionBar() {
      return LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth;
          const spacing = 2.0;
          final count = showSubscribe ? 3 : 2;
          final avail = (maxWidth - spacing * (count - 1)).clamp(
            0.0,
            double.infinity,
          );
          // Subscribe, Shuffle and Radio share the row equally.
          final segmentWidth = ((avail - spacing * 2) / 3).clamp(
            88.0,
            double.infinity,
          );

          final actions = <M3EToggleButtonGroupAction>[
            // Subscribe leads as the group's main action when signed in;
            // signed out, only the listening modes remain.
            if (showSubscribe)
              M3EToggleButtonGroupAction(
                icon: Icon(
                  subscribed ? Icons.check_rounded : Icons.add_rounded,
                ),
                label: Text(
                  subscribed ? 'Subscribed' : 'Subscribe',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
                tooltip: subscribed ? 'Subscribed' : 'Subscribe',
                semanticLabel: subscribed ? 'Subscribed' : 'Subscribe',
                width: segmentWidth,
                decoration: M3EToggleButtonDecoration(
                  backgroundColor: WidgetStateProperty.all(
                    subscribed ? scheme.primaryContainer : scheme.primary,
                  ),
                  foregroundColor: WidgetStateProperty.all(
                    subscribed ? scheme.onPrimaryContainer : scheme.onPrimary,
                  ),
                ),
              ),
            M3EToggleButtonGroupAction(
              icon: const Icon(Icons.shuffle_rounded),
              label: const Text(
                'Shuffle',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
              tooltip: 'Shuffle',
              semanticLabel: 'Shuffle',
              width: segmentWidth,
              enabled: hasSongs,
            ),
            M3EToggleButtonGroupAction(
              icon: const Icon(Icons.radio_rounded),
              label: const Text(
                'Radio',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
              tooltip: 'Play radio',
              semanticLabel: 'Play radio',
              width: segmentWidth,
              enabled: hasSongs,
            ),
          ];

          return M3EToggleButtonGroup(
            type: M3EButtonGroupType.connected,
            size: M3EButtonSize.sm,
            spacing: spacing,
            semanticLabel: 'Artist actions',
            overflow: M3EButtonGroupOverflow.none,
            onSelectedIndexChanged: (i) {
              if (i == null) return;
              switch (i) {
                case 0:
                  if (showSubscribe) {
                    unawaited(state.toggleSubscribe(detailItem.browseId));
                  } else {
                    onShuffle?.call();
                  }
                case 1:
                  if (showSubscribe) {
                    onShuffle?.call();
                  } else if (onMix != null) {
                    unawaited(onMix());
                  }
                case 2:
                  if (showSubscribe && onMix != null) unawaited(onMix());
              }
            },
            actions: actions,
            decoration: toggleButtonGroupDecoration(scheme),
          );
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: spaceSm),
        actionBar(),
        if (hasSongs) ...[
          const SizedBox(height: spaceMd),
          Row(
            children: [
              Expanded(
                child: SectionHeader(title: 'Top songs', onSeeAll: seeAll),
              ),
              const SizedBox(width: spaceSm),
              M3EFilledButton.icon(
                onPressed: onPlayAll,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Play all'),
                size: M3EButtonSize.fromBase(
                  M3EButtonSize.sm,
                  height: 36,
                  iconSize: 20,
                ),
                shape: M3EButtonShape.round,
              ),
            ],
          ),
          for (var i = 0; i < songs.length; i++)
            TrackRow(
              track: songs[i],
              index: i + 1,
              playing: songs[i].videoId == playingId,
              onPlay: () => state.playArtistTopSong(artist, i),
              rateable: true,
              showPlaylists: true,
              showViews: true,
              flush: true,
            ),
        ],
        // The bio reads right after the top songs, before the rails, so
        // it isn't buried under four carousels.
        if (hasBio) ...[
          const SizedBox(height: spaceMd),
          AboutCard(text: artist.description),
        ],
        const SizedBox(height: spaceMd),
        BrowseRail(
          title: 'Albums',
          items: artist.albums,
          onOpen: (item) => state.go(Screen.detail, detail: item),
          fillWidth: true,
        ),
        BrowseRail(
          title: 'Singles & EPs',
          items: artist.singlesAndEps,
          onOpen: (item) => state.go(Screen.detail, detail: item),
          fillWidth: true,
        ),
        BrowseRail(
          title: 'Related playlists',
          items: artist.relatedPlaylists,
          onOpen: (item) => item.isPlaylist
              ? state.openPlaylistById(item.browseId, item: item)
              : state.go(Screen.detail, detail: item),
          fillWidth: true,
        ),
        BrowseRail(
          title: 'Similar artists',
          items: artist.similarArtists,
          circular: true,
          onOpen: (item) => state.go(Screen.detail, detail: item),
          fillWidth: true,
        ),
        const SizedBox(height: playerBarClearance),
      ],
    );
  }
}
