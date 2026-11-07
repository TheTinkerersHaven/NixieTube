// Detail screen: loading/error states, artist view (banner, pills, top
// songs, rails, bio) and the shared album/playlist panel.

import 'dart:typed_data';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/album_panel.dart';
import '../widgets/loading_placeholders.dart';
import '../widgets/rails.dart';
import '../widgets/track_row.dart';

/// Coarse kind derived from a browse id's prefix, used to pick the
/// loading skeleton and the body layout without scattering `startsWith`
/// checks across the build method.
enum DetailKind { artist, album, playlist, unknown }

DetailKind _detailKind(String? browseId) {
  if (browseId == null || browseId.isEmpty) return DetailKind.unknown;
  if (browseId.startsWith('UC')) return DetailKind.artist;
  if (browseId.startsWith('MPRE')) return DetailKind.album;
  return DetailKind.playlist;
}

/// Album/artist/playlist detail page for [AppState.detailItem].
class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final detail = context.select<AppState, DetailUiState>((s) => s.detail);
    final item = context.select<AppState, BrowseItem?>((s) => s.detailItem);
    final state = context.read<AppState>();
    if (detail.loading) {
      switch (_detailKind(item?.browseId)) {
        case DetailKind.album:
          return const _DetailSkeleton(numbered: true);
        case DetailKind.artist:
          return const _ArtistSkeleton();
        case DetailKind.playlist:
          return const _DetailSkeleton(numbered: false);
        case DetailKind.unknown:
          return const Center(child: M3ELoadingIndicator());
      }
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
      body = AlbumPlaylistView(
        title: album.title.isNotEmpty ? album.title : (item?.title ?? 'Album'),
        subtitle: album.subtitle.isNotEmpty
            ? album.subtitle
            : (item?.subtitle ?? ''),
        description: album.description,
        art: album.artworkOr(item),
        owner: album.artist,
        tracks: album.tracks,
        numbered: true,
        showViews: true,
      );
    } else if (detail.playlist != null) {
      final pl = detail.playlist!;
      body = AlbumPlaylistView(
        title: pl.title.isNotEmpty ? pl.title : (item?.title ?? 'Playlist'),
        subtitle: pl.subtitle.isNotEmpty ? pl.subtitle : (item?.subtitle ?? ''),
        description: '',
        art: pl.artworkOr(item),
        owner: pl.author,
        tracks: pl.tracks,
        numbered: false,
        removable: pl.editable,
        onRemoveTrack: pl.editable && pl.id.isNotEmpty
            ? (t) async {
                final ok = await state.removeTrackFromPlaylist(pl.id, t);
                if (ok) state.reloadDetail();
              }
            : null,
      );
    } else {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(gutter),
          child: Text(
            'No details available.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }
    // Only the album/playlist panels still need the hand-placed back
    // button; the artist view carries its own back button in its app bar.
    if (detail.artist != null) return body;
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

/// Artist detail view: banner, actions, top songs, rails and bio.
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
    final banner = artist.thumbnails.isEmpty ? null : artist.bestArtwork;
    final hasSongs = artist.topSongs.isNotEmpty;
    final hasBio = artist.description.trim().isNotEmpty;

    return SilkyCustomScrollView(
      scrollSpeed: 1.5,
      silkyScrollDuration: const Duration(milliseconds: 700),
      animationCurve: Curves.easeOutQuart,
      slivers: [
        _ArtistAppBar(artist: artist, bannerUrl: banner),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: spaceSm),
                _ActionRow(
                  artist: artist,
                  signedIn: signedIn,
                  subscribed: subscribed,
                ),
                const SizedBox(height: spaceMd),
                if (hasSongs || hasBio) ...[
                  LayoutBuilder(
                    builder: (context, c) {
                      final songs = hasSongs
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _SectionHeader(
                                  title: 'Top songs',
                                  onSeeAll: seeAll,
                                ),
                                const SizedBox(height: spaceSm),
                                _TopSongs(
                                  artist: artist,
                                  playingId: playingId,
                                  state: state,
                                ),
                              ],
                            )
                          : null;

                      if (songs == null) {
                        return _AboutCard(text: artist.description);
                      }
                      if (!hasBio) return songs;

                      // Wide: songs define the row height; the About
                      // panel is pinned to the right and stretches to
                      // that height, fitting as much text as possible.
                      if (c.maxWidth >= 900) {
                        return Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(
                                right: 360 + spaceLg,
                              ),
                              child: songs,
                            ),
                            if (hasBio)
                              Positioned(
                                right: 0,
                                top: 0,
                                bottom: 0,
                                width: 360,
                                child: _AboutCard(
                                  text: artist.description,
                                  fillHeight: true,
                                ),
                              ),
                          ],
                        );
                      }

                      // Narrow: stack the bio under the songs.
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          songs,
                          const SizedBox(height: spaceMd),
                          _AboutCard(text: artist.description),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: spaceMd),
                ],
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
            ),
          ),
        ),
      ],
    );
  }
}

/// Top songs laid out in as many columns as fit, numbered down each
/// column in order.
class _TopSongs extends StatelessWidget {
  const _TopSongs({
    required this.artist,
    required this.playingId,
    required this.state,
  });

  final ArtistDetail artist;
  final String? playingId;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final songs = artist.topSongs;
    return LayoutBuilder(
      builder: (context, c) {
        final widthCols = (c.maxWidth / 560).floor().clamp(1, 3);
        final cols = widthCols;
        final shown = math.min(songs.length, cols * 5).toInt();
        final perCol = (shown / cols).ceil().clamp(1, 5);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var col = 0; col < cols; col++) ...[
              if (col > 0) const SizedBox(width: spaceMd),
              Expanded(
                child: Column(
                  children: [
                    for (
                      var i = col * perCol;
                      i < (col + 1) * perCol && i < songs.length;
                      i++
                    )
                      TrackRow(
                        track: songs[i],
                        index: i + 1,
                        playing: songs[i].videoId == playingId,
                        onPlay: () => state.playArtistTopSong(artist, i),
                        rateable: true,
                        showPlaylists: true,
                        showViews: true,
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Where the title sits once the bar is collapsed (clear of the back button).
const _collapsedTitleInset = 72.0;

/// The swap point: once the hero has this many pixels (or fewer) left to
/// collapse, the big title is fully gone and the bar title jumps in.
/// 0 means "only when the bar is completely collapsed".
const _barTitleAtPx = 40.0;

/// Over how many pixels, above the swap point, the big title fades out.
const _bigTitleFadePx = 100.0;

/// Pinned app bar for the artist page. Expanded, it is the full-bleed
/// hero (banner, scrim, name and subscriber count). Collapsed, it is a
/// normal toolbar with the back button and the artist name.
class _ArtistAppBar extends StatelessWidget {
  const _ArtistAppBar({required this.artist, required this.bannerUrl});

  final ArtistDetail artist;
  final String? bannerUrl;

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      expandedHeight: (MediaQuery.sizeOf(context).height * 0.45).clamp(
        240.0,
        480.0,
      ),
      automaticallyImplyLeading: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      flexibleSpace: _ArtistFlexibleSpace(artist: artist, bannerUrl: bannerUrl),
    );
  }
}

/// Content of [_ArtistAppBar]. Reads how far the bar has collapsed from
/// [FlexibleSpaceBarSettings]: the banner fades out and the back button
/// loses its circular backdrop. The big title scrolls away with the hero;
/// once it gets close to the toolbar, the small bar title jumps in.
class _ArtistFlexibleSpace extends StatelessWidget {
  const _ArtistFlexibleSpace({required this.artist, required this.bannerUrl});

  final ArtistDetail artist;
  final String? bannerUrl;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    final settings = context
        .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    final maxExtent = settings?.maxExtent ?? 0.0;
    final minExtent = settings?.minExtent ?? 0.0;
    final current = settings?.currentExtent ?? maxExtent;
    // 1 = fully expanded, 0 = fully collapsed.
    final t = maxExtent > minExtent
        ? ((current - minExtent) / (maxExtent - minExtent)).clamp(0.0, 1.0)
        : 1.0;
    // The banner stays solid for the first part of the collapse, then
    // fades into the bar's surface colour.
    final bannerOpacity = (t / 0.6).clamp(0.0, 1.0);
    // Banner and scrim keep their full size and are clipped by the
    // shrinking bar, so the image doesn't rescale while scrolling.
    final heroHeight = maxExtent > current ? maxExtent : current;
    // Pixels left before the bar is fully collapsed. The big title scrolls
    // away with the hero and fades just before it would run into the
    // toolbar; at that point the small bar title jumps in.
    final collapsedPx = current - minExtent;
    final bigTitleOpacity = ((collapsedPx - _barTitleAtPx) / _bigTitleFadePx)
        .clamp(0.0, 1.0);
    final showBarTitle = collapsedPx <= _barTitleAtPx + 0.5;
    final barHeight = minExtent > 0 ? minExtent : 56.0;
    // The back button's circular backdrop and white icon follow the
    // banner: solid over the image, gone once the bar is plain.
    final iconColor = Color.lerp(
      theme.colorScheme.onSurface,
      Colors.white,
      bannerOpacity,
    );

    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: heroHeight,
          child: Opacity(
            opacity: bannerOpacity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (bannerUrl != null)
                  _BannerImage(
                    url: bannerUrl!,
                    alignment: const Alignment(0, -0.4),
                  ),
                // Size the scrim to the *visible* bar height so its bottom
                // stop lands exactly on the bar's bottom edge instead of
                // being clipped mid-gradient (which read as a sharp edge).
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: current,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0, 0.35, 1],
                        colors: [
                          Colors.black.withValues(alpha: 0.45),
                          Colors.transparent,
                          theme.colorScheme.surface,
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Big title + subscriber count: part of the hero, so they simply
        // scroll up with it.
        Positioned(
          left: gutter,
          right: gutter,
          bottom: 0,
          child: Opacity(
            opacity: bigTitleOpacity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  artist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: artistTitleStyle(context),
                ),
                if (artist.subscribers.isNotEmpty) ...[
                  const SizedBox(height: spaceXs),
                  Text(
                    artist.subscribers,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // Bar title: hidden until the hero has scrolled away, then slides
        // up from just below the toolbar's edge.
        if (showBarTitle)
          Positioned(
            top: 0,
            left: _collapsedTitleInset,
            right: gutter,
            height: barHeight,
            child: IgnorePointer(
              child: ClipRect(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedSlide(
                    offset: Offset.zero,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: 1,
                      duration: const Duration(milliseconds: 160),
                      child: Text(
                        artist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineMedium,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          top: _lerp(4, 8, t),
          left: 8,
          child: CircleAvatar(
            radius: 24,
            backgroundColor: Colors.black.withValues(
              alpha: 0.28 * bannerOpacity,
            ),
            child: IconButton(
              icon: Icon(Icons.arrow_back_rounded, color: iconColor),
              tooltip: 'Back',
              onPressed: state.goBack,
            ),
          ),
        ),
      ],
    );
  }
}

/// About card used beside (or under) the top songs. Takes its natural
/// height; "Show more" only appears when the text is actually clipped.
class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.text, this.fillHeight = false});

  final String text;
  final bool fillHeight;

  static const _maxLines = 8;

  void _showMore(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SizedBox(
          width: 480,
          child: Padding(
            padding: const EdgeInsets.all(spaceLg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('About', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: spaceMd),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      text,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
                const SizedBox(height: spaceMd),
                Align(
                  alignment: Alignment.centerRight,
                  child: M3ETextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium;
    return Card(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(spaceMd),
        child: LayoutBuilder(
          builder: (context, c) {
            // Full text metrics.
            final fullTp = TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: c.maxWidth);
            final fullLines = fullTp.computeLineMetrics().length;
            final lineHeight = fullLines > 0
                ? fullTp.height / fullLines
                : ((style?.fontSize ?? 14) * (style?.height ?? 1.4));
            fullTp.dispose();

            final availH = c.maxHeight.isFinite ? c.maxHeight : 200.0;
            final titleH =
                (theme.textTheme.titleLarge?.fontSize ?? 22) + spaceSm;
            final linesThatFit = ((availH - titleH - spaceSm) / lineHeight)
                .floor()
                .clamp(1, 1000);
            final overflows = fullLines > linesThatFit;

            final maxLines = fillHeight ? linesThatFit : _maxLines;
            final textWidget = Text(
              text,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: style,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('About', style: theme.textTheme.titleLarge),
                const SizedBox(height: spaceSm),
                if (fillHeight) Expanded(child: textWidget) else textWidget,
                if (overflows) ...[
                  const SizedBox(height: spaceSm),
                  M3ETextButton(
                    onPressed: () => _showMore(context),
                    child: const Text('Show more'),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Section header with consistent spacing and an optional "See all".
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.onSeeAll});

  final String title;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (onSeeAll != null)
          M3ETextButton(onPressed: onSeeAll, child: const Text('See all')),
      ],
    );
  }
}

/// Action row: Play all (filled) with labelled Shuffle and Mix, plus
/// Subscribe when signed in.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.artist,
    required this.signedIn,
    required this.subscribed,
  });

  final ArtistDetail artist;
  final bool signedIn;
  final bool subscribed;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final detailItem = state.detailItem;
    final hasSongs = artist.topSongs.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: spaceXs),
      child: Wrap(
        spacing: spaceSm,
        runSpacing: spaceSm,
        children: [
          M3EFilledButton.icon(
            onPressed: hasSongs
                ? () => state.playArtistSongs(artist, false)
                : null,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play all'),
          ),
          M3EOutlinedButton.icon(
            onPressed: hasSongs
                ? () => state.playArtistSongs(artist, true)
                : null,
            icon: const Icon(Icons.shuffle_rounded),
            label: const Text('Shuffle'),
          ),
          M3EOutlinedButton.icon(
            onPressed: hasSongs
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
                : null,
            icon: const Icon(Icons.radio_rounded),
            label: const Text('Mix'),
          ),
          if (signedIn && detailItem != null)
            M3EOutlinedButton(
              onPressed: () => state.toggleSubscribe(detailItem.browseId),
              child: Text(subscribed ? 'Subscribed' : 'Subscribe'),
            ),
        ],
      ),
    );
  }
}

/// Detail banner: memoizes one PNG render per URL so list scrolls
/// back and forth don't re-decode it.
class _BannerImage extends StatefulWidget {
  const _BannerImage({required this.url, this.alignment = Alignment.center});

  final String url;
  final Alignment alignment;

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
          alignment: widget.alignment,
          gaplessPlayback: true,
        );
      },
    );
  }
}
