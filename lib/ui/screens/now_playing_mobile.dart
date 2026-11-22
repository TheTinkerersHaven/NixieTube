// Mobile Now Playing view: full-screen experience with large cover art,
// prominent transport controls, and swipe-up / sheet access to queue and lyrics.

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart' hide RepeatMode;
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../../core/player/player_state.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/artwork_image.dart';
import 'now_playing_screen.dart';

/// Mobile full-screen view for Now Playing.
class NowPlayingMobile extends StatefulWidget {
  const NowPlayingMobile({
    super.key,
    required this.track,
    required this.signedIn,
    required this.libraryAvailable,
    required this.hasQueue,
    required this.sleepMode,
    required this.sleepEndsAt,
  });

  final Track track;
  final bool signedIn;
  final bool libraryAvailable;
  final bool hasQueue;
  final SleepTimerMode sleepMode;
  final int? sleepEndsAt;

  @override
  State<NowPlayingMobile> createState() => _NowPlayingMobileState();
}

class _NowPlayingMobileState extends State<NowPlayingMobile> {
  final M3EMenuController _menuController = M3EMenuController();
  RatingStatus? _pendingRating;
  String? _pendingVideoId;

  @override
  void initState() {
    super.initState();
    // Fullscreen lyrics was opened from this sheet and has just been
    // left: bring the sheet back on the Lyrics tab.
    final state = context.read<AppState>();
    if (state.consumeLyricsSheetPending()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openSheet(context, initialTab: 1);
      });
    }
  }

  @override
  void didUpdateWidget(NowPlayingMobile old) {
    super.didUpdateWidget(old);
    if (old.track.videoId != widget.track.videoId) {
      _pendingRating = null;
      _pendingVideoId = null;
    }
  }

  Future<void> _rate(RatingStatus rating) async {
    if (_pendingRating != null) return;
    final videoId = widget.track.videoId;
    setState(() {
      _pendingRating = rating;
      _pendingVideoId = videoId;
    });
    final state = context.read<AppState>();
    await state.rateCurrentFeedback(context, rating);
    if (mounted && _pendingVideoId == videoId) {
      setState(() {
        _pendingRating = null;
        _pendingVideoId = null;
      });
    }
  }

  void _openArtist(AppState state, ArtistRef artist) {
    state.closeNow();
    unawaited(state.openArtist(artist, widget.track));
  }

  void _openAlbum(AppState state) {
    final album = widget.track.album;
    if (album == null) return;
    state.closeNow();
    unawaited(state.openAlbum(widget.track, album));
  }

  void _openSheet(BuildContext context, {int initialTab = 0}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(ExpressiveCorners.largeIncreased),
        ),
      ),
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 8),
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: RepaintBoundary(
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        // Keep the tabs and their rows off the sheet's
                        // rounded edges and the gesture pill.
                        padding: EdgeInsets.symmetric(
                          horizontal: screenPadding,
                        ),
                        child: TabsColumn(
                          initialTab: initialTab,
                          // Tapping an artist or album in the Info tab
                          // must close the sheet, or the page opens
                          // behind it.
                          onNavigate: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final track = widget.track;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final playing = context.select<AppState, bool>(
      (s) => s.playerState.playing,
    );
    final loading = context.select<AppState, bool>(
      (s) => s.playerState.loading,
    );
    final shuffle = context.select<AppState, bool>(
      (s) => s.playerState.shuffle,
    );
    final repeatOne = context.select<AppState, bool>(
      (s) => s.playerState.repeat == RepeatMode.one,
    );
    final repeatOff = context.select<AppState, bool>(
      (s) => s.playerState.repeat == RepeatMode.off,
    );
    final hasDuration = context.select<AppState, bool>(
      (s) => s.playerState.durationMs > 0,
    );

    final albumName = track.album?.name;
    final showAlbum = albumName != null && albumName != track.title;
    final actionPillBg = Colors.white.withValues(alpha: 0.10);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v > 300) {
          state.closeNow();
        } else if (v < -300) {
          _openSheet(context, initialTab: 0);
        }
      },
      child: Column(
        children: [
          // Top bar: dismiss on left, optional album context in center,
          // balanced overflow IconButton on right.
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
                tooltip: 'Close',
                onPressed: state.closeNow,
              ),
              Expanded(
                child: showAlbum
                    ? Center(
                        child: InkWell(
                          onTap: () => _openAlbum(state),
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            child: Text(
                              albumName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: text.titleSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              M3EMenuAnchor(
                controller: _menuController,
                style: const M3EMenuStyle(maxWidth: 320),
                menuChildren: _buildMenuItems(context, state, track),
                builder: (context, controller, _) => IconButton(
                  icon: const Icon(Icons.more_vert_rounded),
                  tooltip: 'More actions',
                  onPressed: () =>
                      controller.isOpen ? controller.close() : controller.open(),
                ),
              ),
            ],
          ),
          // Main player content: cover pinned at top, unified control deck
          // centered in the middle space, and sheet triggers at the bottom.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const sideInset = 8.0;
                final maxArtByWidth = constraints.maxWidth - (sideInset * 2);
                final maxArtByHeight =
                    (constraints.maxHeight - 316.0).clamp(160.0, 380.0);
                final artSize = math.min(maxArtByWidth, maxArtByHeight);

                final artwork = Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Center(
                    child: RepaintBoundary(
                      child: ArtworkImage(
                        track.displayArtwork,
                        size: artSize,
                        radius: playerRadius,
                        iconSize: artSize / 4,
                        squareCoverKey: track.videoId,
                      ),
                    ),
                  ),
                );

                final controlDeck = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Title and Like / Dislike Row
                    Padding(
                      padding: const EdgeInsets.only(
                        left: sideInset,
                        right: 2,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  track.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    height: 1.15,
                                    fontVariations: const [
                                      FontVariation('ROND', 50),
                                      FontVariation('wdth', 105),
                                    ],
                                  ),
                                ),
                                if (track.artists.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Wrap(
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      if (track.explicit)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 4,
                                          ),
                                          child: Icon(
                                            Icons.explicit,
                                            size: 15,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                      for (var i = 0;
                                          i < track.artists.length;
                                          i++) ...[
                                        InkWell(
                                          onTap: () => _openArtist(
                                            state,
                                            track.artists[i],
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          child: Text(
                                            track.artists[i].name,
                                            style: text.bodyMedium?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                        if (i != track.artists.length - 1)
                                          Text(
                                            ' • ',
                                            style: text.bodyMedium?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                      ],
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (widget.signedIn) ...[
                            const SizedBox(width: 4),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: _pendingRating == RatingStatus.like &&
                                      _pendingVideoId == track.videoId
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: M3ELoadingIndicator(),
                                    )
                                  : Icon(
                                      track.rating == RatingStatus.like
                                          ? Icons.thumb_up_rounded
                                          : Icons.thumb_up_outlined,
                                    ),
                              tooltip: track.rating == RatingStatus.like
                                  ? 'Remove like'
                                  : 'Like',
                              color: track.rating == RatingStatus.like
                                  ? scheme.primary
                                  : scheme.onSurface,
                              onPressed: _pendingRating != null
                                  ? null
                                  : () => _rate(
                                        track.rating == RatingStatus.like
                                            ? RatingStatus.indifferent
                                            : RatingStatus.like,
                                      ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: _pendingRating == RatingStatus.dislike &&
                                      _pendingVideoId == track.videoId
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: M3ELoadingIndicator(),
                                    )
                                  : Icon(
                                      track.rating == RatingStatus.dislike
                                          ? Icons.thumb_down_rounded
                                          : Icons.thumb_down_outlined,
                                    ),
                              tooltip: track.rating == RatingStatus.dislike
                                  ? 'Remove dislike'
                                  : 'Dislike',
                              color: track.rating == RatingStatus.dislike
                                  ? scheme.primary
                                  : scheme.onSurface,
                              onPressed: _pendingRating != null
                                  ? null
                                  : () => _rate(
                                        track.rating == RatingStatus.dislike
                                            ? RatingStatus.indifferent
                                            : RatingStatus.dislike,
                                      ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    // Seek Progress aligned with cover edges
                    if (hasDuration)
                      TransportProgress(
                        state: state,
                        widthFactor: 1.0,
                        thumbHeight: 34,
                        labelHorizontalPadding: sideInset,
                      ),
                    const SizedBox(height: 12),
                    // Playback Controls Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.shuffle_rounded),
                          tooltip: 'Shuffle',
                          color: shuffle
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          onPressed: loading
                              ? null
                              : () => state.player.toggleShuffle(),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.skip_previous_rounded,
                            size: 40,
                          ),
                          tooltip: 'Previous',
                          style: IconButton.styleFrom(
                            minimumSize: const Size(56, 56),
                            foregroundColor: scheme.onSurface,
                          ),
                          onPressed:
                              loading ? null : () => state.player.previous(),
                        ),
                        if (loading)
                          const SizedBox(
                            width: 72,
                            height: 72,
                            child: Center(
                              child: M3ELoadingIndicator(
                                constraints: BoxConstraints.tightFor(
                                  width: 52,
                                  height: 52,
                                ),
                              ),
                            ),
                          )
                        else
                          IconButton.filled(
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 40,
                            ),
                            tooltip: 'Play/pause',
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: Colors.black,
                              minimumSize: const Size(72, 72),
                            ),
                            onPressed: () => state.player.togglePlayPause(),
                          ),
                        IconButton(
                          icon: const Icon(
                            Icons.skip_next_rounded,
                            size: 40,
                          ),
                          tooltip: 'Next',
                          style: IconButton.styleFrom(
                            minimumSize: const Size(56, 56),
                            foregroundColor: scheme.onSurface,
                          ),
                          onPressed: loading ? null : () => state.player.next(),
                        ),
                        IconButton(
                          icon: Icon(
                            repeatOne
                                ? Icons.repeat_one_rounded
                                : Icons.repeat_rounded,
                          ),
                          tooltip: 'Repeat',
                          color: repeatOff
                              ? scheme.onSurfaceVariant
                              : scheme.primary,
                          onPressed:
                              loading ? null : () => state.player.cycleRepeat(),
                        ),
                      ],
                    ),
                  ],
                );

                final bottomActions = Padding(
                  padding: const EdgeInsets.only(
                    left: sideInset,
                    right: sideInset,
                    bottom: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () => _openSheet(context, initialTab: 0),
                          style: FilledButton.styleFrom(
                            backgroundColor: actionPillBg,
                            foregroundColor: scheme.onSurface,
                            minimumSize: const Size.fromHeight(44),
                          ),
                          icon: const Icon(Icons.queue_music_rounded, size: 18),
                          label: const Text('Up next'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () => _openSheet(context, initialTab: 1),
                          style: FilledButton.styleFrom(
                            backgroundColor: actionPillBg,
                            foregroundColor: scheme.onSurface,
                            minimumSize: const Size.fromHeight(44),
                          ),
                          icon: const Icon(Icons.lyrics_rounded, size: 18),
                          label: const Text('Lyrics'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filledTonal(
                        onPressed: () => _openSheet(context, initialTab: 2),
                        tooltip: 'Song info',
                        style: IconButton.styleFrom(
                          backgroundColor: actionPillBg,
                          foregroundColor: scheme.onSurface,
                          minimumSize: const Size(44, 44),
                        ),
                        icon: const Icon(Icons.info_outline_rounded, size: 20),
                      ),
                    ],
                  ),
                );

                final minContentHeight = artSize + 316.0;
                if (constraints.maxHeight >= minContentHeight) {
                  return SizedBox(
                    height: constraints.maxHeight,
                    child: Column(
                      children: [
                        artwork,
                        const Spacer(),
                        controlDeck,
                        const Spacer(),
                        bottomActions,
                      ],
                    ),
                  );
                }

                return SingleChildScrollView(
                  // The screen already pads the view by [screenPadding];
                  // adding more here only shrinks the phone content.
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      artwork,
                      const SizedBox(height: 16),
                      controlDeck,
                      const SizedBox(height: 20),
                      bottomActions,
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildMenuItems(
    BuildContext context,
    AppState state,
    Track track,
  ) {
    return [
      M3EMenuItemButton(
        leadingIcon: const Icon(Icons.link_rounded),
        onPressed: () =>
            unawaited(handleNowMenu(context, NowMenuAction.shareLink, track)),
        child: const Text('Share link'),
      ),
      M3EMenuItemButton(
        leadingIcon: const Icon(Icons.open_in_new_rounded),
        onPressed: () => unawaited(
          handleNowMenu(context, NowMenuAction.openYoutube, track),
        ),
        child: const Text('Open in YouTube'),
      ),
      if (widget.signedIn && widget.libraryAvailable)
        M3EMenuItemButton(
          leadingIcon: const Icon(Icons.playlist_add_rounded),
          onPressed: () => unawaited(state.openPlaylistDialog(track)),
          child: const Text('Add to playlist'),
        ),
      if (widget.hasQueue)
        M3EMenuItemButton(
          leadingIcon: const Icon(Icons.delete_sweep_outlined),
          onPressed: () => unawaited(
            handleNowMenu(context, NowMenuAction.clearUpNext, track),
          ),
          child: const Text('Clear up next'),
        ),
      M3EMenuItemButton(
        leadingIcon: Icon(
          widget.sleepMode != SleepTimerMode.off
              ? Icons.bedtime_rounded
              : Icons.bedtime_outlined,
        ),
        onPressed: () =>
            unawaited(handleNowMenu(context, NowMenuAction.sleepTimer, track)),
        child: Text(
          sleepMenuLabel(widget.sleepMode, widget.sleepEndsAt),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ];
  }
}