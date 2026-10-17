// Detail screen ported from Kotlin `Detail.kt` + `AlbumPanel.kt`:
// loading/error states, artist view (banner, pills, top songs, rails,
// bio) and the shared album/playlist panel.

import 'dart:typed_data';

import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/album_panel.dart';
import '../widgets/loading_placeholders.dart';
import '../widgets/rails.dart';
import '../widgets/track_row.dart';

/// Album/artist/playlist detail page for [AppState.detailItem].
class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final detail = context.select<AppState, DetailUiState>((s) => s.detail);
    final item = context.select<AppState, BrowseItem?>((s) => s.detailItem);
    final state = context.read<AppState>();
    if (detail.loading) {
      // Album and playlist songs shimmer as skeleton rows while
      // the songs load (same panel as the loaded view, so they
      // reveal in place). The type is known from the browse id
      // prefix; anything else keeps the spinner.
      final id = item?.browseId ?? '';
      if (id.startsWith('MPRE')) {
        return const _DetailSkeleton(numbered: true);
      }
      if (item != null && !id.startsWith('UC')) {
        return const _DetailSkeleton(numbered: false);
      }
      if (id.startsWith('UC')) {
        return const _ArtistSkeleton();
      }
      return const Center(child: M3ELoadingIndicator());
    }
    if (detail.error != null) {
      return Center(
        child: ErrorBox(
          message: detail.error!,
          onRetry: () {
            if (item != null) state.go(Screen.detail, detail: item);
          },
        ),
      );
    }
    Widget body;
    if (detail.artist != null) {
      body = _ArtistDetailView(artist: detail.artist!);
    } else if (detail.album != null) {
      final album = detail.album!;
      final fallbackArt = (item != null && item.thumbnails.isNotEmpty)
          ? item.thumbnails.reduce((a, b) => a.width >= b.width ? a : b).url
          : null;
      // Album browse art first — fall back to the first track's cover,
      // matching the playlist enrichment pattern.
      String? albumArt = album.thumbnails.isNotEmpty
          ? album.thumbnails.reduce((a, b) => a.width >= b.width ? a : b).url
          : (album.tracks
                    .map((t) => t.displayArtwork)
                    .whereType<String>()
                    .where((u) => u.isNotEmpty)
                    .firstOrNull ??
                fallbackArt);
      body = AlbumPlaylistView(
        title: album.title.isNotEmpty ? album.title : (item?.title ?? 'Album'),
        subtitle: album.subtitle.isNotEmpty
            ? album.subtitle
            : (item?.subtitle ?? ''),
        description: album.description,
        art: albumArt,
        arts: const [],
        owner: album.artist,
        tracks: album.tracks,
        numbered: true,
        showViews: true,
      );
    } else if (detail.playlist != null) {
      final pl = detail.playlist!;
      final fallbackArt = (item != null && item.thumbnails.isNotEmpty)
          ? item.thumbnails.reduce((a, b) => a.width >= b.width ? a : b).url
          : null;
      final plArt = pl.thumbnails.isNotEmpty
          ? pl.thumbnails.reduce((a, b) => a.width >= b.width ? a : b).url
          : fallbackArt;
      body = AlbumPlaylistView(
        title: pl.title.isNotEmpty ? pl.title : (item?.title ?? 'Playlist'),
        subtitle: pl.subtitle.isNotEmpty ? pl.subtitle : (item?.subtitle ?? ''),
        description: '',
        art: plArt,
        arts: const [],
        owner: pl.author,
        tracks: pl.tracks,
        numbered: false,
      );
    } else {
      body = const SizedBox.shrink();
    }
    return Stack(
      children: [
        body,
        Positioned(
          left: 8,
          top: 8,
          child: CircleAvatar(
            radius: 24,
            backgroundColor: Colors.black.withValues(alpha: 0.28),
            child: IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
              tooltip: 'Back',
              onPressed: state.goBack,
            ),
          ),
        ),
      ],
    );
  }
}

/// Skeleton album/playlist detail: the same panel as the loaded
/// view with placeholder songs, so rows reveal in place.
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton({required this.numbered});

  final bool numbered;

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      enabled: true,
      enableSwitchAnimation: true,
      child: AlbumPlaylistView(
        title: 'Loading songs',
        subtitle: '',
        description: '',
        art: null,
        owner: null,
        tracks: placeholderTracks,
        numbered: numbered,
      ),
    );
  }
}

/// Skeleton artist view: the same layout as the loaded view with
/// placeholder content, so banner, buttons, songs, rails and bio
/// reveal in place.
class _ArtistSkeleton extends StatelessWidget {
  const _ArtistSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Skeletonizer(
      enabled: true,
      enableSwitchAnimation: true,
      child: _ArtistDetailView(artist: placeholderArtist),
    );
  }
}

/// Shared album/playlist panel: left art column, right sortable track list.
class _ArtistDetailView extends StatelessWidget {
  const _ArtistDetailView({required this.artist});

  final ArtistDetail artist;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    final signedIn = context.select<AppState, bool>((s) => s.account != null);
    final subscribed = context.select<AppState, bool>(
      (s) =>
          s.detailItem == null ? false : s.isSubscribed(s.detailItem!.browseId),
    );
    final banner = artist.thumbnails.isEmpty
        ? null
        : artist.thumbnails.reduce((a, b) => a.width >= b.width ? a : b).url;
    return ListView(
      // Deep enough that the banner survives scrolling through the
      // top songs instead of unmounting and reloading on return.
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      padding: const EdgeInsets.fromLTRB(
        screenPadding,
        screenPadding,
        screenPadding,
        screenPadding + playerBarClearance,
      ),
      children: [
        if (banner != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(cardRadius),
            child: AspectRatio(
              aspectRatio: 2.57,
              child: _BannerImage(url: banner),
            ),
          ),
        const SizedBox(height: 8),
        Text(artist.name, style: Theme.of(context).textTheme.headlineMedium),
        if (artist.subscribers.isNotEmpty)
          Text(
            artist.subscribers,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            M3EFilledButton.icon(
              onPressed: artist.topSongs.isEmpty
                  ? null
                  : () => state.playArtistSongs(artist, false),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Shuffle'),
            ),
            M3EOutlinedButton.icon(
              onPressed: artist.topSongs.isEmpty
                  ? null
                  : () async {
                      final seed = artist.topSongs.first;
                      final res = await state.startArtistRadio(artist);
                      if (!context.mounted) return;
                      // User moved on mid-fetch: stay silent.
                      if (state.player.state.current?.videoId != seed.videoId) {
                        return;
                      }
                      // Success restarts playback visibly; only a dead
                      // mix needs words.
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
                    },
              icon: const Icon(Icons.radio_rounded),
              label: const Text('Mix'),
            ),
            if (signedIn && state.detailItem != null)
              M3EOutlinedButton(
                onPressed: () =>
                    state.toggleSubscribe(state.detailItem!.browseId),
                child: Text(subscribed ? 'Subscribed' : 'Subscribe'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (artist.topSongs.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'Top songs',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (artist.songsPlaylistId != null)
                M3ETextButton(
                  onPressed: () => state.go(
                    Screen.detail,
                    detail: BrowseItem(
                      title: 'Top songs',
                      subtitle: artist.name,
                      browseId: artist.songsPlaylistId!,
                      browseParams: artist.songsPlaylistParams,
                      thumbnails: artist.thumbnails,
                    ),
                  ),
                  child: const Text('See all'),
                ),
            ],
          ),
          for (var i = 0; i < artist.topSongs.length; i++)
            TrackRow(
              track: artist.topSongs[i],
              index: i + 1,
              playing: artist.topSongs[i].videoId == playingId,
              onPlay: () => state.playArtistTopSong(artist, i),
              rateable: true,
              showPlaylists: true,
              showViews: true,
            ),
          const SizedBox(height: 16),
        ],
        BrowseRail(
          title: 'Albums',
          items: artist.albums,
          onOpen: (item) => state.go(Screen.detail, detail: item),
        ),
        BrowseRail(
          title: 'Singles & EPs',
          items: artist.singlesAndEps,
          onOpen: (item) => state.go(Screen.detail, detail: item),
        ),
        BrowseRail(
          title: 'Related playlists',
          items: artist.relatedPlaylists,
          onOpen: (item) => state.go(Screen.detail, detail: item),
        ),
        BrowseRail(
          title: 'Similar artists',
          items: artist.similarArtists,
          circular: true,
          onOpen: (item) => state.go(Screen.detail, detail: item),
        ),
        if (artist.description.trim().isNotEmpty) ...[
          Text('About', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            artist.description.length > 600
                ? '${artist.description.substring(0, 600)}…'
                : artist.description,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 32),
        ],
      ],
    );
  }
}

/// Detail banner: memoizes one PNG render per URL so list scrolls
/// back and forth don't re-decode it.
class _BannerImage extends StatefulWidget {
  const _BannerImage({required this.url});

  final String url;

  @override
  State<_BannerImage> createState() => _BannerImageState();
}

class _BannerImageState extends State<_BannerImage> {
  Future<Uint8List>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Finished bytes are memoized in the store, so remounts after a
    // scroll unmount resolve (near-)instantly instead of re-decoding.
    _future ??= context.read<AppState>().art.bannerPng(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          // An enabled ancestor loading scope (the artist skeleton)
          // also means "art on its way" for the placeholder's empty
          // URL: bone shimmer instead of a flat box, mirroring
          // ArtworkImage, so the hero never pops in later.
          final ancestorLoading =
              context
                  .dependOnInheritedWidgetOfExactType<SkeletonizerScope>()
                  ?.enabled ??
              false;
          if (!widget.url.trim().isNotEmpty && !ancestorLoading) {
            return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
            );
          }
          const bone = SizedBox.expand(child: Bone());
          // An active ancestor scope paints the shimmer itself;
          // otherwise the bone brings its own scope.
          if (ancestorLoading) return bone;
          return const Skeletonizer(enabled: true, child: bone);
        }
        // Banner decodes at display width, not the 1920px source.
        return Image.memory(
          bytes,
          cacheWidth: 1280,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        );
      },
    );
  }
}
