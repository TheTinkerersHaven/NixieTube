// Mobile Now Playing view: full-screen experience with large cover art,
// prominent transport controls, and swipe-up / sheet access to queue and lyrics.

import 'dart:async';

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
  RatingStatus? _pendingRating;
  String? _pendingVideoId;

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
                const Expanded(
                  child: RepaintBoundary(
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        // Keep the tabs and their rows off the sheet's
                        // rounded edges and the gesture pill.
                        padding: EdgeInsets.symmetric(
                          horizontal: screenPadding,
                        ),
                        child: TabsColumn(),
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

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 300) {
          state.closeNow();
        }
      },
      child: Column(
        children: [
          // Top bar
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
                tooltip: 'Close',
                onPressed: state.closeNow,
              ),
              Expanded(
                child: Text(
                  'Now playing',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              M3EPopupMenuButton<NowMenuAction>(
                tooltip: 'More actions',
                style: const M3EMenuStyle(maxWidth: 320),
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (action) =>
                    unawaited(handleNowMenu(context, action, track)),
                itemBuilder: (context) => [
                  const M3EPopupMenuItem<NowMenuAction>(
                    value: NowMenuAction.shareLink,
                    child: Row(
                      children: [
                        Icon(Icons.link_rounded),
                        SizedBox(width: 12),
                        Text('Share link'),
                      ],
                    ),
                  ),
                  const M3EPopupMenuItem<NowMenuAction>(
                    value: NowMenuAction.openYoutube,
                    child: Row(
                      children: [
                        Icon(Icons.open_in_new_rounded),
                        SizedBox(width: 12),
                        Text('Open in YouTube'),
                      ],
                    ),
                  ),
                  if (widget.signedIn && widget.libraryAvailable)
                    M3EPopupMenuItem<NowMenuAction>(
                      onTap: () => state.openPlaylistDialog(track),
                      child: const Row(
                        children: [
                          Icon(Icons.playlist_add_rounded),
                          SizedBox(width: 12),
                          Text('Add to playlist'),
                        ],
                      ),
                    ),
                  if (widget.hasQueue)
                    const M3EPopupMenuItem<NowMenuAction>(
                      value: NowMenuAction.clearUpNext,
                      child: Row(
                        children: [
                          Icon(Icons.delete_sweep_outlined),
                          SizedBox(width: 12),
                          Text('Clear up next'),
                        ],
                      ),
                    ),
                  M3EPopupMenuItem<NowMenuAction>(
                    value: NowMenuAction.sleepTimer,
                    child: Row(
                      children: [
                        Icon(
                          widget.sleepMode != SleepTimerMode.off
                              ? Icons.bedtime_rounded
                              : Icons.bedtime_outlined,
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            sleepMenuLabel(
                              widget.sleepMode,
                              widget.sleepEndsAt,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Main player content: artwork, title, seek bar, transport
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final artSize = (constraints.maxWidth * 0.76).clamp(
                  160.0,
                  320.0,
                );
                return SingleChildScrollView(
                  // The screen already pads the view by [screenPadding];
                  // adding more here only shrinks the phone content.
                  padding: EdgeInsets.zero,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      // The content keeps its own tight rhythm: free
                      // vertical space sits above and below the block
                      // instead of opening gaps between the cover,
                      // title, seek bar and controls.
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Large Artwork
                        Center(
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
                        const SizedBox(height: 12),
                        // Title and Like / Dislike Row
                        Row(
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
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 4),
                                  Text.rich(
                                    TextSpan(
                                      children: [
                                        if (track.explicit)
                                          WidgetSpan(
                                            alignment:
                                                PlaceholderAlignment.middle,
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                right: 4,
                                              ),
                                              child: Icon(
                                                Icons.explicit,
                                                size: 14,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        TextSpan(text: track.artistNames()),
                                      ],
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            if (widget.signedIn) ...[
                              IconButton(
                                icon:
                                    _pendingRating == RatingStatus.like &&
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
                                icon:
                                    _pendingRating == RatingStatus.dislike &&
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
                        const SizedBox(height: 8),
                        // Seek Progress
                        if (hasDuration) TransportProgress(state: state),
                        const SizedBox(height: 8),
                        // Playback Controls Row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.shuffle_rounded),
                              tooltip: 'Shuffle',
                              color: shuffle
                                  ? scheme.primary
                                  : scheme.onSurface,
                              onPressed: loading
                                  ? null
                                  : () => state.player.toggleShuffle(),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.skip_previous_rounded,
                                size: 38,
                              ),
                              tooltip: 'Previous',
                              onPressed: loading
                                  ? null
                                  : () => state.player.previous(),
                            ),
                            if (loading)
                              const SizedBox(
                                width: 68,
                                height: 68,
                                child: Center(
                                  child: M3ELoadingIndicator(
                                    constraints: BoxConstraints.tightFor(
                                      width: 48,
                                      height: 48,
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
                                  size: 38,
                                ),
                                tooltip: 'Play/pause',
                                style: IconButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: Colors.black,
                                  minimumSize: const Size(68, 68),
                                ),
                                onPressed: () => state.player.togglePlayPause(),
                              ),
                            IconButton(
                              icon: const Icon(
                                Icons.skip_next_rounded,
                                size: 38,
                              ),
                              tooltip: 'Next',
                              onPressed: loading
                                  ? null
                                  : () => state.player.next(),
                            ),
                            IconButton(
                              icon: Icon(
                                repeatOne
                                    ? Icons.repeat_one_rounded
                                    : Icons.repeat_rounded,
                              ),
                              tooltip: 'Repeat',
                              color: repeatOff
                                  ? scheme.onSurface
                                  : scheme.primary,
                              onPressed: loading
                                  ? null
                                  : () => state.player.cycleRepeat(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Bottom access to Queue & Lyrics
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            M3EOutlinedButton.icon(
                              onPressed: () =>
                                  _openSheet(context, initialTab: 0),
                              icon: const Icon(
                                Icons.queue_music_rounded,
                                size: 18,
                              ),
                              label: const Text('Up next'),
                            ),
                            const SizedBox(width: 12),
                            M3EOutlinedButton.icon(
                              onPressed: () =>
                                  _openSheet(context, initialTab: 1),
                              icon: const Icon(Icons.lyrics_rounded, size: 18),
                              label: const Text('Lyrics'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
