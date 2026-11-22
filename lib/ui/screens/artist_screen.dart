// Artist detail page: collapsing banner, action row, top songs, rails
// and bio. Rendered by DetailScreen once a UC* browse id is opened.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/loading_placeholders.dart';
import '../widgets/rails.dart';
import '../widgets/track_row.dart';

/// Artist detail view: banner, actions, top songs, rails and bio.
class ArtistScreen extends StatelessWidget {
  const ArtistScreen({required this.artist, super.key});

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
            padding: EdgeInsets.symmetric(
              horizontal: isCompactLayout(context) ? screenPadding : gutter,
            ),
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
                if (isWideLayout(context))
                  // Wide: the songs and the bio share a row, the bio pinned
                  // to the right and stretched to the songs' height so it
                  // fits as much text as it can.
                  LayoutBuilder(
                    builder: (context, c) {
                      if (!hasSongs) {
                        return hasBio
                            ? _AboutCard(text: artist.description)
                            : const SizedBox.shrink();
                      }
                      final songs = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SectionHeader(title: 'Top songs', onSeeAll: seeAll),
                          const SizedBox(height: spaceSm),
                          _TopSongs(
                            artist: artist,
                            playingId: playingId,
                            state: state,
                          ),
                        ],
                      );
                      if (!hasBio) return songs;
                      return Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(
                              right: 360 + spaceLg,
                            ),
                            child: songs,
                          ),
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
                    },
                  )
                // Narrow: the bio reads last, so it moves under the rails.
                else if (hasSongs) ...[
                  _SectionHeader(title: 'Top songs', onSeeAll: seeAll),
                  const SizedBox(height: spaceSm),
                  _TopSongs(
                    artist: artist,
                    playingId: playingId,
                    state: state,
                  ),
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
                // Narrow layout: the bio reads after everything else, so
                // it lands under the rails instead of beside the songs.
                if (!isWideLayout(context) && hasBio) ...[
                  const SizedBox(height: spaceMd),
                  _AboutCard(text: artist.description),
                ],
                const SizedBox(height: playerBarClearance),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Skeleton artist view: the same layout as the loaded view with
/// placeholder content, so banner, buttons, songs, rails and bio
/// reveal in place.
class ArtistScreenSkeleton extends StatelessWidget {
  const ArtistScreenSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const Skeletonizer(
      enabled: true,
      enableSwitchAnimation: true,
      child: ArtistScreen(artist: placeholderArtist),
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
    final surface = theme.colorScheme.surface;
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
    // Scale gradient stops against [heroHeight] so the scrim covers the
    // entire banner with solid [surface] well past [current], avoiding any
    // subpixel anti-aliased edge at the bar's bottom boundary while scrolling.
    final scrimScale =
        heroHeight > 0 ? (current / heroHeight).clamp(0.0, 1.0) : 1.0;
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

    final compact = isCompactLayout(context);
    final effectiveGutter = compact ? screenPadding : gutter;
    // The flexible space spans the status bar (SliverAppBar's primary
    // inset does not apply to it), so the controls are pushed below it.
    final topPadding = MediaQuery.viewPaddingOf(context).top;
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
                // Fill the full [heroHeight] and scale stops by [scrimScale]
                // so the bottom stop still lands on the visible bar edge
                // without creating a fractional-pixel rect edge over the
                // banner.
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: compact
                          ? LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: [
                                for (final s in const [
                                  0.0,
                                  0.14,
                                  0.28,
                                  0.32,
                                  0.41,
                                  0.50,
                                  0.59,
                                  0.68,
                                  0.77,
                                  0.86,
                                  1.0,
                                ])
                                  s * scrimScale,
                              ],
                              colors: [
                                Colors.black.withValues(alpha: 0.52),
                                Colors.black.withValues(alpha: 0.22),
                                Colors.black.withValues(alpha: 0.0),
                                surface.withValues(alpha: 0.0),
                                surface.withValues(alpha: 0.08),
                                surface.withValues(alpha: 0.26),
                                surface.withValues(alpha: 0.50),
                                surface.withValues(alpha: 0.74),
                                surface.withValues(alpha: 0.92),
                                surface,
                                surface,
                              ],
                            )
                          : LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: [
                                for (final s in const [
                                  0.0,
                                  0.16,
                                  0.34,
                                  0.38,
                                  0.47,
                                  0.56,
                                  0.65,
                                  0.74,
                                  0.83,
                                  0.92,
                                  1.0,
                                ])
                                  s * scrimScale,
                              ],
                              colors: [
                                Colors.black.withValues(alpha: 0.45),
                                Colors.black.withValues(alpha: 0.18),
                                Colors.black.withValues(alpha: 0.0),
                                surface.withValues(alpha: 0.0),
                                surface.withValues(alpha: 0.08),
                                surface.withValues(alpha: 0.26),
                                surface.withValues(alpha: 0.50),
                                surface.withValues(alpha: 0.74),
                                surface.withValues(alpha: 0.92),
                                surface,
                                surface,
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
          left: effectiveGutter,
          right: effectiveGutter,
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
            top: topPadding,
            left: _collapsedTitleInset,
            right: effectiveGutter,
            height: barHeight - topPadding,
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
          top: topPadding + _lerp(4, 8, t),
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

/// Action row: Play all (filled) with Shuffle, Mix, and Subscribe when signed
/// in. On compact mobile screens with all four actions visible, Shuffle and
/// Mix collapse to outlined icon buttons so everything stays on one line.
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
    final showSubscribe = signedIn && detailItem != null;
    final compactRow = isCompactLayout(context) && showSubscribe;

    final onPlayAll = hasSongs
        ? () => state.playArtistSongs(artist, false)
        : null;
    final onShuffle = hasSongs
        ? () => state.playArtistSongs(artist, true)
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

    if (compactRow) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: spaceXs),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            children: [
              M3EFilledButton.icon(
                onPressed: onPlayAll,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Play'),
              ),
              const SizedBox(width: spaceSm),
              IconButton.outlined(
                onPressed: onShuffle,
                tooltip: 'Shuffle',
                icon: const Icon(Icons.shuffle_rounded),
              ),
              const SizedBox(width: spaceSm),
              IconButton.outlined(
                onPressed: onMix,
                tooltip: 'Mix',
                icon: const Icon(Icons.radio_rounded),
              ),
              const SizedBox(width: spaceSm),
              M3EOutlinedButton(
                onPressed: () => state.toggleSubscribe(detailItem.browseId),
                child: Text(subscribed ? 'Subscribed' : 'Subscribe'),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: spaceXs),
      child: Wrap(
        spacing: spaceSm,
        runSpacing: spaceSm,
        children: [
          M3EFilledButton.icon(
            onPressed: onPlayAll,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play all'),
          ),
          M3EOutlinedButton.icon(
            onPressed: onShuffle,
            icon: const Icon(Icons.shuffle_rounded),
            label: const Text('Shuffle'),
          ),
          M3EOutlinedButton.icon(
            onPressed: onMix,
            icon: const Icon(Icons.radio_rounded),
            label: const Text('Mix'),
          ),
          if (showSubscribe)
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