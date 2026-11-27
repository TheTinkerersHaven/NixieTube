// Artist detail page: collapsing banner, action row, top songs, rails
// and bio. Rendered by DetailScreen once a UC* browse id is opened.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/about_card.dart';
import '../widgets/artist_panel_mobile.dart';
import '../widgets/loading_placeholders.dart';
import '../widgets/rails.dart';
import '../widgets/track_row.dart';

/// Shared horizontal page gutter across the hero, collapsed bar, and body.
double _horizontalGutter(bool compact) => compact ? screenPadding : gutter;

/// Artist detail view: banner, actions, top songs, rails and bio.
/// Phones keep the collapsing banner hero and get the compact content
/// panel below it; wider windows keep the full layout.
class ArtistScreen extends StatelessWidget {
  const ArtistScreen({required this.artist, super.key});

  final ArtistDetail artist;

  @override
  Widget build(BuildContext context) {
    final compact = isCompactLayout(context);
    final horizontalGutter = _horizontalGutter(compact);
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
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
            padding: EdgeInsets.symmetric(horizontal: horizontalGutter),
            // Phones get the compact panel under the hero: playback actions,
            // compact song rows, the bio up high, rails last.
            child: compact
                ? ArtistPanelMobile(artist: artist)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: spaceSm),
                      _ActionRow(artist: artist),
                      const SizedBox(height: spaceLg),
                      if (isWideLayout(context))
                        // Wide: the songs and the bio share a row, the bio pinned
                        // to the right and stretched to the songs' height so it
                        // fits as much text as it can.
                        LayoutBuilder(
                          builder: (context, c) {
                            if (!hasSongs) {
                              return hasBio
                                  ? AboutCard(text: artist.description)
                                  : const SizedBox.shrink();
                            }
                            final songs = Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SectionHeader(
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
                                  child: AboutCard(
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
                        SectionHeader(title: 'Top songs', onSeeAll: seeAll),
                        const SizedBox(height: spaceSm),
                        _TopSongs(
                          artist: artist,
                          playingId: playingId,
                          state: state,
                        ),
                      ],
                      if (hasSongs || (isWideLayout(context) && hasBio))
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
                      // Narrow layout: the bio reads after everything else, so
                      // it lands under the rails instead of beside the songs.
                      if (!isWideLayout(context) && hasBio) ...[
                        const SizedBox(height: spaceMd),
                        AboutCard(text: artist.description),
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

/// The swap point: once the hero has this many pixels (or fewer) left to
/// collapse, the big title is fully gone and the bar title slides in.
const _barTitleAtPx = 44.0;

/// Over how many pixels, above the swap point, the big title fades out.
const _bigTitleFadePx = 96.0;

/// Pinned app bar for the artist page. Expanded, it is the full-bleed
/// hero (banner, scrim, name, subscriber count, and subscribe pill).
/// Collapsed, it is a clean toolbar with the back button and artist name.
class _ArtistAppBar extends StatelessWidget {
  const _ArtistAppBar({required this.artist, required this.bannerUrl});

  final ArtistDetail artist;
  final String? bannerUrl;

  @override
  Widget build(BuildContext context) {
    final compact = isCompactLayout(context);
    final height = MediaQuery.sizeOf(context).height;
    return SliverAppBar(
      pinned: true,
      expandedHeight: compact
          ? (height * 0.38).clamp(260.0, 360.0)
          : (height * 0.46).clamp(280.0, 500.0),
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
/// loses its circular backdrop. The hero identity row (artist name,
/// subscriber count, and channel subscribe pill) scrolls away with the hero;
/// once it nears the toolbar, the compact bar title slides in.
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
    final signedIn = context.select<AppState, bool>((s) => s.account != null);
    final detailItem = context.select<AppState, BrowseItem?>(
      (s) => s.detailItem,
    );
    final subscribed = context.select<AppState, bool>(
      (s) =>
          s.detailItem == null ? false : s.isSubscribed(s.detailItem!.browseId),
    );
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
    final bannerOpacity = (t / 0.65).clamp(0.0, 1.0);
    // Banner and scrim keep their full size and are clipped by the
    // shrinking bar, so the image doesn't rescale while scrolling.
    final heroHeight = maxExtent > current ? maxExtent : current;
    // Scale gradient stops against [heroHeight] so the scrim covers the
    // entire banner with solid [surface] well past [current], avoiding any
    // subpixel anti-aliased edge at the bar's bottom boundary while scrolling.
    final scrimScale = heroHeight > 0
        ? (current / heroHeight).clamp(0.0, 1.0)
        : 1.0;
    // Pixels left before the bar is fully collapsed. The hero identity row
    // scrolls away with the banner and fades just before it would run into
    // the toolbar; at that point the small bar title slides in.
    final collapsedPx = current - minExtent;
    final bigTitleOpacity = ((collapsedPx - _barTitleAtPx) / _bigTitleFadePx)
        .clamp(0.0, 1.0);
    final barTitleProgress = (1.0 - (collapsedPx / _barTitleAtPx)).clamp(
      0.0,
      1.0,
    );
    final barHeight = minExtent > 0 ? minExtent : 56.0;
    // The back button's circular backdrop and white icon follow the
    // banner: solid over the image, gone once the bar is plain.
    final iconColor = Color.lerp(
      theme.colorScheme.onSurface,
      Colors.white,
      bannerOpacity,
    );

    final compact = isCompactLayout(context);
    final horizontalGutter = _horizontalGutter(compact);
    // Align the 24dp back icon inside the 48dp CircleAvatar with the page's
    // left gutter keyline, and place the collapsed title one spaceSm past it.
    final backButtonLeft = math.max(4.0, horizontalGutter - 12.0);
    final collapsedTitleLeft = backButtonLeft + 48.0 + spaceSm;
    // The flexible space spans the status bar (SliverAppBar's primary
    // inset does not apply to it), so the controls are pushed below it.
    final topPadding = MediaQuery.viewPaddingOf(context).top;
    final showSubscribe = signedIn && detailItem != null;

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
                    alignment: const Alignment(0, -0.25),
                  ),
                // Fill the full [heroHeight] and scale stops by [scrimScale]
                // so the bottom stop still lands on the visible bar edge
                // without creating a fractional-pixel rect edge over the
                // banner, while keeping the center of the portrait clear.
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [
                          for (final s in const [
                            0.0,
                            0.14,
                            0.28,
                            0.42,
                            0.52,
                            0.62,
                            0.72,
                            0.82,
                            0.92,
                            1.0,
                          ])
                            s * scrimScale,
                        ],
                        colors: [
                          Colors.black.withValues(alpha: 0.44),
                          Colors.black.withValues(alpha: 0.16),
                          Colors.black.withValues(alpha: 0.0),
                          surface.withValues(alpha: 0.0),
                          surface.withValues(alpha: 0.10),
                          surface.withValues(alpha: 0.32),
                          surface.withValues(alpha: 0.60),
                          surface.withValues(alpha: 0.86),
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
        // Hero identity row: artist name + subscriber count anchored on the
        // left, paired with the channel Subscribe pill on the right.
        Positioned(
          left: horizontalGutter,
          right: horizontalGutter,
          bottom: spaceMd,
          child: IgnorePointer(
            ignoring: bigTitleOpacity < 0.25,
            child: Opacity(
              opacity: bigTitleOpacity,
              child: _HeroIdentityRow(
                artist: artist,
                compact: compact,
                subscribed: subscribed,
                onToggleSubscribe: !compact && showSubscribe
                    ? () => state.toggleSubscribe(detailItem.browseId)
                    : null,
              ),
            ),
          ),
        ),
        // Bar title: hidden until the hero has scrolled away, then slides
        // into place smoothly with the final collapse distance.
        if (barTitleProgress > 0)
          Positioned(
            top: topPadding,
            left: collapsedTitleLeft,
            right: horizontalGutter,
            height: barHeight - topPadding,
            child: IgnorePointer(
              child: ClipRect(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionalTranslation(
                    translation: Offset(0, 0.25 * (1.0 - barTitleProgress)),
                    child: Opacity(
                      opacity: barTitleProgress,
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
          left: backButtonLeft,
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

/// Bottom-anchored hero identity row pairing the artist's title and subscriber
/// count with their channel subscription pill.
class _HeroIdentityRow extends StatelessWidget {
  const _HeroIdentityRow({
    required this.artist,
    required this.compact,
    required this.subscribed,
    required this.onToggleSubscribe,
  });

  final ArtistDetail artist;
  final bool compact;
  final bool subscribed;
  final VoidCallback? onToggleSubscribe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Phones drop the subscribe pill, so the title stands alone under the
    // banner and reads better centred; wider layouts keep the name on the
    // gutter keyline next to the pill.
    final centred = compact && onToggleSubscribe == null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: centred
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Text(
                artist.name,
                maxLines: compact ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                textAlign: centred ? TextAlign.center : null,
                style: artistTitleStyle(context),
              ),
              if (artist.subscribers.isNotEmpty) ...[
                const SizedBox(height: spaceXs),
                Text(
                  artist.subscribers,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: centred ? TextAlign.center : null,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (onToggleSubscribe != null) ...[
          const SizedBox(width: spaceMd),
          _SubscribePill(subscribed: subscribed, onPressed: onToggleSubscribe!),
        ],
      ],
    );
  }
}

/// Compact stadium pill for channel subscription state inside the hero.
class _SubscribePill extends StatelessWidget {
  const _SubscribePill({required this.subscribed, required this.onPressed});

  final bool subscribed;
  final VoidCallback onPressed;

  static const double _height = 38.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = const StadiumBorder();

    if (subscribed) {
      return FilledButton.tonalIcon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.secondaryContainer,
          foregroundColor: scheme.onSecondaryContainer,
          minimumSize: const Size(0, _height),
          maximumSize: const Size(double.infinity, _height),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: shape,
        ),
        icon: const Icon(Icons.check_rounded, size: 18),
        label: const Text(
          'Subscribed',
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: scheme.surface.withValues(alpha: 0.55),
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outlineVariant),
        minimumSize: const Size(0, _height),
        maximumSize: const Size(double.infinity, _height),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: shape,
      ),
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text(
        'Subscribe',
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Playback action bar for wider layouts:
/// - Because channel subscription lives in the hero identity row, this strip
///   stays focused purely on listening modes (`Play all`, `Shuffle`, `Mix`).
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.artist});

  final ArtistDetail artist;

  Widget _label(String text) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = context.read<AppState>();
    final hasSongs = artist.topSongs.isNotEmpty;

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

    const height = 44.0;
    return Wrap(
      spacing: spaceSm,
      runSpacing: spaceSm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: onPlayAll,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            minimumSize: const Size(0, height),
            maximumSize: const Size(double.infinity, height),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: const StadiumBorder(),
          ),
          icon: const Icon(Icons.play_arrow_rounded, size: 22),
          label: _label('Play all'),
        ),
        FilledButton.tonalIcon(
          onPressed: onShuffle,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.secondaryContainer,
            foregroundColor: scheme.onSecondaryContainer,
            minimumSize: const Size(0, height),
            maximumSize: const Size(double.infinity, height),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: const StadiumBorder(),
          ),
          icon: const Icon(Icons.shuffle_rounded, size: 20),
          label: _label('Shuffle'),
        ),
        FilledButton.tonalIcon(
          onPressed: onMix,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.secondaryContainer,
            foregroundColor: scheme.onSecondaryContainer,
            minimumSize: const Size(0, height),
            maximumSize: const Size(double.infinity, height),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: const StadiumBorder(),
          ),
          icon: const Icon(Icons.radio_rounded, size: 20),
          label: _label('Mix'),
        ),
      ],
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
