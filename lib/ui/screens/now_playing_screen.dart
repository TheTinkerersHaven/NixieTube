// Full Now Playing view ported from Kotlin `NowPlaying`: tinted backdrop,
// cover, transport controls and Up-next/Lyrics/Info tabs. Shows nothing
// when no track is loaded.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' hide RepeatMode;
import 'package:provider/provider.dart';

import 'package:m3e_core/m3e_core.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/innertube/lyrics.dart' show LyricsSource;
import '../../core/models/models.dart';
import '../../core/player/player_state.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/artwork_image.dart';
import '../widgets/fab_menu_down.dart';
import '../widgets/lyrics_list.dart';
import '../widgets/loading_placeholders.dart';
import '../widgets/palette_backdrop.dart';
import '../widgets/player_bar.dart';
import '../widgets/seek_slider.dart';
import '../widgets/spring_context_menu.dart';
import '../widgets/track_row.dart';
import '../widgets/volume_slider.dart';

/// Full Now Playing view with cover, transport and tabs.
class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final track = context.select<AppState, Track?>(
      (s) => s.playerState.current,
    );
    if (track == null) return const SizedBox.shrink();
    final palette = context.select<AppState, List<Color>>(
      (s) => s.coverPalette,
    );
    final full = context.select<AppState, bool>((s) => s.lyricsFull);
    final signedIn = context.select<AppState, bool>(
      (s) => s.account != null,
    );
    final gdataAvailable = context.select<AppState, bool>(
      (s) => s.gdataAvailable,
    );
    final hasQueue = context.select<AppState, bool>(
      (s) => s.playerState.queue.isNotEmpty,
    );
    final sleepMode = context.select<AppState, SleepTimerMode>(
      (s) => s.playerState.sleepTimerMode,
    );
    final sleepEndsAt = context.select<AppState, int?>(
      (s) => s.playerState.sleepTimerEndsAtMs,
    );
    final backdrop = Theme.of(context).colorScheme.surface;
    if (full) {
      return _FullscreenLyricsView(
        track: track,
        palette: palette,
        backdrop: backdrop,
      );
    }
    return Scaffold(
      backgroundColor: backdrop,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Own layer: the 600ms palette wash animation repaints here
          // without touching the cover and transport above it.
          RepaintBoundary(
            child: PaletteBackdrop(palette: palette),
          ),
          Padding(
            padding: const EdgeInsets.all(screenPadding),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      tooltip: 'Close',
                      onPressed: context.read<AppState>().closeNow,
                    ),
                    Expanded(
                      child: Text(
                        'Now playing',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    // M3E action menu: the three-dot trigger
                    // morphs and springs pill items open below
                    // it (downwards, so the header menu never
                    // flies off the top of the screen),
                    // replacing the old popup menu.
                    M3EFabMenuDown(
                      icon: const Icon(Icons.more_vert_rounded),
                      closeIcon: const Icon(Icons.close_rounded),
                      size: M3EFabSize.small,
                      color: M3EFabColor.surface,
                      position: M3EFabMenuPosition.right,
                      items: [
                        M3EFabMenuItem(
                          icon: const Icon(Icons.link_rounded),
                          label: 'Share link',
                          onPressed: () => _handleNowMenu(
                            context,
                            _NowMenuAction.shareLink,
                            track,
                          ),
                        ),
                        M3EFabMenuItem(
                          icon: const Icon(Icons.open_in_new_rounded),
                          label: 'Open in YouTube',
                          onPressed: () => _handleNowMenu(
                            context,
                            _NowMenuAction.openYoutube,
                            track,
                          ),
                        ),
                        // Playlist add needs the Data API, so it
                        // rides the menu rather than the transport
                        // row (matching the old bottom-bar button).
                        if (signedIn && gdataAvailable)
                          M3EFabMenuItem(
                            icon: const Icon(Icons.playlist_add_rounded),
                            label: 'Add to playlist',
                            onPressed: () =>
                                context.read<AppState>().openPlaylistDialog(
                                  track,
                                ),
                          ),
                        // Queue discard lives here in the title-bar
                        // menu rather than the tab, so it is one
                        // tap away without crowding Up next.
                        if (hasQueue)
                          M3EFabMenuItem(
                            icon:
                                const Icon(Icons.delete_sweep_outlined),
                            label: 'Clear up next',
                            onPressed: () => _handleNowMenu(
                              context,
                              _NowMenuAction.clearUpNext,
                              track,
                            ),
                          ),
                        M3EFabMenuItem(
                          icon: Icon(
                            sleepMode != SleepTimerMode.off
                                ? Icons.bedtime_rounded
                                : Icons.bedtime_outlined,
                          ),
                          label: _sleepMenuLabel(sleepMode, sleepEndsAt),
                          onPressed: () => _handleNowMenu(
                            context,
                            _NowMenuAction.sleepTimer,
                            track,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final rawSize = [
                        constraints.maxWidth * 0.44,
                        (constraints.maxHeight - 320)
                            .clamp(180.0, double.infinity)
                            .toDouble(),
                        360.0,
                      ].reduce((a, b) => a < b ? a : b);
                      // Snap to 32px steps: the size feeds the image
                      // cache key, so a continuous size would re-decode
                      // the cover on every pixel of a window-resize drag.
                      final artSize =
                          ((rawSize / 32).round() * 32).clamp(64, 360).toDouble();
                      return Row(
                        children: [
                          Expanded(
                            // Transport repaints (slider ticks) stay out
                            // of the backdrop wash layer and vice versa.
                            child: RepaintBoundary(
                              child: _TransportColumn(
                                track: track,
                                artSize: artSize,
                              ),
                            ),
                          ),
                          const SizedBox(width: 24),
                          const Expanded(
                            child: RepaintBoundary(child: _TabsColumn()),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Vertical wash following the cover's top/middle/bottom bands.
class _TransportColumn extends StatefulWidget {
  const _TransportColumn({required this.track, required this.artSize});

  final Track track;
  final double artSize;

  @override
  State<_TransportColumn> createState() => _TransportColumnState();
}

class _TransportColumnState extends State<_TransportColumn> {
  RatingStatus? _pendingRating;
  String? _pendingVideoId;

  @override
  void didUpdateWidget(_TransportColumn old) {
    super.didUpdateWidget(old);
    if (old.track.videoId != widget.track.videoId) {
      _pendingRating = null;
      _pendingVideoId = null;
    }
  }

  Future<void> _rate(RatingStatus rating) async {
    if (_pendingRating != null) return;
    final videoId = widget.track.videoId;
    setState(() { _pendingRating = rating; _pendingVideoId = videoId; });
    final state = context.read<AppState>();
    await state.rateCurrentFeedback(context, rating);
    if (mounted && _pendingVideoId == videoId) {
      setState(() { _pendingRating = null; _pendingVideoId = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final track = widget.track;
    final artSize = widget.artSize;
    // Narrow selects: the column must not rebuild on progress ticks —
    // only the progress row below listens to those. Track (value
    // equality) covers title/artists/album/rating/stats merges.
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
    final signedIn = context.select<AppState, bool>((s) => s.account != null);
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(
            // Own layer: the cover paint (placeholder swap, decode)
            // stays out of the ticking labels below.
            child: RepaintBoundary(
              child: ArtworkImage(
                track.displayArtwork,
                size: artSize,
                radius: playerRadius,
                iconSize: artSize / 4,
                // Same square art the lists show: its bytes are
                // already on disk from the list tile, so opening
                // Now Playing never re-downloads the frame.
                squareCoverKey: track.videoId,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            track.title,
            style: Theme.of(context).textTheme.headlineMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          if (track.artists.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < track.artists.length; i++) ...[
                    InkWell(
                      onTap: () {
                        state.closeNow();
                        state.openArtist(track.artists[i], track);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          track.artists[i].name,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    ),
                    if (i != track.artists.length - 1)
                      Text('•', style: Theme.of(context).textTheme.bodyLarge),
                  ],
                ],
              ),
            ),
          if (track.album != null)
            InkWell(
              onTap: () {
                state.closeNow();
                state.openAlbum(track, track.album!);
              },
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  track.album!.name,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          const SizedBox(height: 16),
          if (hasDuration) _TransportProgress(state: state),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.shuffle_rounded),
                tooltip: 'Shuffle',
                color: shuffle ? scheme.primary : scheme.onSurface,
                onPressed: loading ? null : () => state.player.toggleShuffle(),
              ),
              // Sized M3 targets like Kotlin: 60dp buttons, 48dp glyphs.
              IconButton(
                icon: const Icon(Icons.skip_previous_rounded, size: 48),
                tooltip: 'Previous',
                style: IconButton.styleFrom(
                  minimumSize: const Size(60, 60),
                  foregroundColor: scheme.onSurface,
                ),
                onPressed: loading ? null : () => state.player.previous(),
              ),
              if (loading)
                // Own layer: the morphing shapes must not repaint
                // the cover, texts and buttons around them.
                const RepaintBoundary(
                  child: SizedBox(
                    width: 76,
                    height: 76,
                    child: Center(
                      // M3E loading shapes (morphing polygons)
                      // instead of a circular spinner.
                      child: M3ELoadingIndicator(
                        constraints: BoxConstraints.tightFor(
                          width: 60,
                          height: 60,
                        ),
                      ),
                    ),
                  ),
                )
              else
                IconButton.filled(
                  icon: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 42,
                  ),
                  tooltip: 'Play/pause',
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(76, 76),
                  ),
                  onPressed: () => state.player.togglePlayPause(),
                ),
              IconButton(
                icon: const Icon(Icons.skip_next_rounded, size: 48),
                tooltip: 'Next',
                style: IconButton.styleFrom(
                  minimumSize: const Size(60, 60),
                  foregroundColor: scheme.onSurface,
                ),
                onPressed: loading ? null : () => state.player.next(),
              ),
              IconButton(
                icon: Icon(
                  repeatOne ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                ),
                tooltip: 'Repeat',
                color: repeatOff ? scheme.onSurface : scheme.primary,
                onPressed: loading ? null : () => state.player.cycleRepeat(),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.volume_up_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              SizedBox(width: 8),
              SizedBox(width: 140, child: VolumeSlider(state: state)),
              SizedBox(width: 16),
              _SleepTimerButton(state: state),
              if (signedIn) ...[
                IconButton(
                  icon: _pendingRating == RatingStatus.like &&
                          _pendingVideoId == track.videoId
                      ? SizedBox(
                          width: 24,
                          height: 24,
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
                  icon: _pendingRating == RatingStatus.dislike &&
                          _pendingVideoId == track.videoId
                      ? SizedBox(
                          width: 24,
                          height: 24,
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
        ],
      ),
    );
  }
}

/// Seek slider + time labels, rebuilt on progress ticks only, reading the
/// live player snapshot instead of rebuilding the transport column.
///
/// The column itself is static: the slider and the labels own separate
/// listeners (and repaint boundaries), so a tick never rebuilds — or
/// repaints — the artwork, texts and buttons above.
class _TransportProgress extends StatelessWidget {
  const _TransportProgress({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          child: FractionallySizedBox(
            widthFactor: 0.9,
            child: RepaintBoundary(
              child: SeekSlider(state: state, thumbHeight: 48),
            ),
          ),
        ),
        FractionallySizedBox(
          widthFactor: 0.9,
          child: RepaintBoundary(child: _TimeLabels(state: state)),
        ),
      ],
    );
  }
}

/// Time labels with their own progress listener and repaint boundary,
/// so the 2Hz text change re-records only these two labels instead of
/// the whole transport column layer.
class _TimeLabels extends StatelessWidget {
  const _TimeLabels({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: state.progressTick,
      builder: (context, _, _) {
        final s = state.player.state;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              formatClock(s.positionMs),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              formatClock(s.durationMs),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}

class _TabsColumn extends StatelessWidget {
  const _TabsColumn();

  @override
  Widget build(BuildContext context) {
    final ready = context.select<AppState, bool>((s) => s.nowReady);
    final open = context.select<AppState, bool>((s) => s.nowOpen);
    // Tabs stay out until the overlay slide completes so the
    // transition's first frames only carry transport + artwork. Gating
    // on the open flag too keeps the warm (offstage) tree from building
    // tab lists for a view nobody sees yet — they stage in after the
    // slide instead. No fade: Fading a big subtree forces an offscreen
    // compositing layer for the whole animation; the staged appearance
    // reads cleanly on its own (TabBarView already virtualizes the
    // non-visible pages, so only the Up next rows mount here).
    final show = ready && open;
    return show ? const _TabsContent() : const SizedBox.shrink();
  }
}

class _TabsContent extends StatelessWidget {
  const _TabsContent();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Up next'),
              Tab(text: 'Lyrics'),
              Tab(text: 'Info'),
            ],
          ),
          // A little air under the tab strip so the
          // first row of content doesn't crowd it.
          const SizedBox(height: 8),
          Expanded(
            child: TabBarView(
              children: [_UpNextTab(), _LyricsTab(), _InfoTab()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Actions in the Now Playing title-row overflow menu.
enum _NowMenuAction { shareLink, openYoutube, clearUpNext, sleepTimer }

/// Actions in a queue row's right-click menu.
enum _QueueRowAction { playNext, addToPlaylist, copyLink, remove }

/// Runs a title-row menu action for the current [track].
Future<void> _handleNowMenu(
  BuildContext context,
  _NowMenuAction action,
  Track track,
) async {
  final state = context.read<AppState>();
  switch (action) {
    case _NowMenuAction.shareLink:
      // The short `youtu.be` link is the canonical shareable form.
      await Clipboard.setData(
        ClipboardData(text: 'https://youtu.be/${track.videoId}'),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard.')),
        );
      }
    case _NowMenuAction.openYoutube:
      await state.openUrl('https://www.youtube.com/watch?v=${track.videoId}');
    case _NowMenuAction.clearUpNext:
      if (context.mounted) _confirmClearQueue(context, state);
    case _NowMenuAction.sleepTimer:
      if (context.mounted) _showSleepTimerSheet(context);
  }
}

/// Menu label for the sleep timer entry: remaining time while a
/// duration timer is armed, the mode otherwise. Computed when the
/// menu opens, so no ticking timers are involved.
String _sleepMenuLabel(SleepTimerMode mode, int? endsAtMs) {
  switch (mode) {
    case SleepTimerMode.duration:
      if (endsAtMs == null) return 'Sleep timer';
      var left = (endsAtMs - DateTime.now().millisecondsSinceEpoch) ~/ 1000;
      if (left < 0) left = 0;
      final m = left ~/ 60;
      final s = left % 60;
      return 'Sleep timer ($m:${s.toString().padLeft(2, '0')} left)';
    case SleepTimerMode.endOfTrack:
      return 'Sleep timer (end of track)';
    case SleepTimerMode.endOfQueue:
      return 'Sleep timer (end of queue)';
    case SleepTimerMode.off:
      return 'Sleep timer';
  }
}

/// Compact icon + label row for a popup menu item.
class _UpNextTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    // Field selects: the queue list identity only changes on real
    // queue edits (append/metadata/rating restamps), never on ticks.
    final queue = context.select<AppState, List<Track>>(
      (s) => s.playerState.queue,
    );
    final index = context.select<AppState, int>((s) => s.playerState.index);
    final autoplay = context.select<AppState, bool>(
      (s) => s.playerState.autoplay,
    );
    final currentId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    // Glassy chips: translucent fills and hairline borders read on any
    // cover tint, where solid surfaces or accent fills look pasted on.
    final scheme = Theme.of(context).colorScheme;
    final chipFill = Colors.black.withValues(alpha: 0.35);
    final chipEdge = BorderSide(color: Colors.white.withValues(alpha: 0.16));
    // Stable reorder keys independent of position: duplicate video ids
    // in one queue get an occurrence suffix so every key stays unique.
    final seenCounts = <String, int>{};
    final occurrences = List<int>.filled(queue.length, 0);
    for (var i = 0; i < queue.length; i++) {
      final id = queue[i].videoId;
      occurrences[i] = seenCounts[id] ?? 0;
      seenCounts[id] = occurrences[i] + 1;
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          // The chip body is a `Material` that defaults to the opaque
          // canvasColor; scoping a transparent canvas lets the translucent
          // fills and hairline borders show the cover tint through.
          child: Theme(
            data: Theme.of(context)
                .copyWith(canvasColor: Colors.transparent),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  FilterChip(
                    selected: autoplay,
                    label: Text(
                      'Autoplay',
                      style: TextStyle(color: scheme.onSurface),
                    ),
                    backgroundColor: chipFill,
                    selectedColor:
                        scheme.primary.withValues(alpha: 0.28),
                    checkmarkColor: scheme.onSurface,
                    side: chipEdge,
                    onSelected: (_) =>
                        state.player.toggleAutoplay(),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: Icon(
                      Icons.sensors_rounded,
                      size: 18,
                      color: scheme.onSurface,
                    ),
                    label: Text(
                      'Radio',
                      style: TextStyle(color: scheme.onSurface),
                    ),
                    backgroundColor: chipFill,
                    side: chipEdge,
                    onPressed: currentId == null
                        ? null
                        : () async {
                            final current =
                                state.player.state.current;
                            if (current == null) return;
                            final res =
                                await state.startRadio(current);
                            if (!context.mounted) return;
                            // User moved on mid-fetch: stay silent.
                            if (state.player.state.current
                                    ?.videoId !=
                                current.videoId) {
                              return;
                            }
                            ScaffoldMessenger.of(context)
                                .showSnackBar(
                              SnackBar(
                                content: Text(
                                  !res.loaded
                                      ? 'Could not load the station — check '
                                          'your connection.'
                                      : res.queued > 0
                                          ? 'Radio: ${res.queued} station '
                                              'tracks queued.'
                                          : 'Station already in queue.',
                                ),
                              ),
                            );
                          },
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: queue.isEmpty
              ? Center(
                  child: Text(
                    'Queue is empty — play something to get started.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: queue.length,
                  onReorderItem: (oldIndex, newIndex) =>
                      state.player.moveQueue(oldIndex, newIndex),
                  itemBuilder: (context, i) {
                    final t = queue[i];
                    // Swipe to remove (with Undo); dragging stays on
                    // the handle so the two gestures never fight.
                    return Dismissible(
                      key: ValueKey('${t.videoId}#${occurrences[i]}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        color: scheme.errorContainer,
                        child: Icon(
                          Icons.delete_outline_rounded,
                          color: scheme.onErrorContainer,
                        ),
                      ),
                      onDismissed: (_) =>
                          _removeQueueTrack(context, state, i, t),
                      child: GestureDetector(
                        // Desktop right-click menu; swipe and the
                        // drag handle keep working alongside it.
                        onSecondaryTapDown: (details) =>
                            _showQueueRowMenu(
                          context,
                          state,
                          details.globalPosition,
                          i,
                          t,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TrackRow(
                                track: t,
                                playing: i == index,
                                onPlay: () => state.player.playAt(i),
                                rateable: true,
                                // The row hosts its own right-click menu;
                                // the row-local one stays off.
                                contextMenu: false,
                              ),
                            ),
                            ReorderableDragStartListener(
                              index: i,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 16,
                                ),
                                child: Icon(
                                  Icons.drag_handle_rounded,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Confirms before discarding everything but the current song.
Future<void> _confirmClearQueue(BuildContext context, AppState state) async {
  final clear = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Clear up next?'),
      content: const Text(
        'This removes every other song from the queue. '
        'The current song keeps playing.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Clear'),
        ),
      ],
    ),
  );
  if (clear == true) state.player.clearQueue();
}

/// Removes the queue entry at [index] with an Undo snackbar.
/// Shared by swipe-to-dismiss and the right-click menu.
void _removeQueueTrack(
  BuildContext context,
  AppState state,
  int index,
  Track track,
) {
  state.player.removeAt(index);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text('Removed from queue'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => state.player.insertAt(index, track),
      ),
    ),
  );
}

/// Right-click menu for one queue row.
Future<void> _showQueueRowMenu(
  BuildContext context,
  AppState state,
  Offset globalPosition,
  int index,
  Track track,
) async {
  final currentIndex = state.player.state.index;
  final selected = await showSpringMenu<_QueueRowAction>(
    context: context,
    position: globalPosition,
    items: [
      SpringMenuItem(
        icon: const Icon(Icons.playlist_play_rounded),
        label: 'Play next',
        value: _QueueRowAction.playNext,
        enabled: index != currentIndex,
      ),
      const SpringMenuItem(
        icon: Icon(Icons.playlist_add_rounded),
        label: 'Add to playlist',
        value: _QueueRowAction.addToPlaylist,
      ),
      const SpringMenuItem(
        icon: Icon(Icons.link_rounded),
        label: 'Copy link',
        value: _QueueRowAction.copyLink,
      ),
      const SpringMenuItem(
        icon: Icon(Icons.delete_outline_rounded),
        label: 'Remove from queue',
        value: _QueueRowAction.remove,
      ),
    ],
  );
  if (!context.mounted) return;
  switch (selected) {
    case _QueueRowAction.playNext:
      // Jump the song to right behind the current one.
      final cur = state.player.state.index;
      if (index != cur) {
        state.player.moveQueue(index, index < cur ? cur : cur + 1);
      }
    case _QueueRowAction.addToPlaylist:
      state.openPlaylistDialog(track);
    case _QueueRowAction.copyLink:
      await Clipboard.setData(
        ClipboardData(text: 'https://youtu.be/${track.videoId}'),
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link copied to clipboard.')),
      );
    case _QueueRowAction.remove:
      _removeQueueTrack(context, state, index, track);
    case null:
      break;
  }
}

class _LyricsTab extends StatefulWidget {
  @override
  State<_LyricsTab> createState() => _LyricsTabState();
}

class _LyricsTabState extends State<_LyricsTab> {
  final ScrollController _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final source = context.select<AppState, LyricsSource>(
      (s) => s.lyricsSource,
    );
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        // Provider switch centered under the tabs, fullscreen trailing
        // at the right: equal flexes on both sides center the group
        // exactly, and the shared Row aligns it with the icon.
        Row(
          children: [
            const Spacer(),
            M3EToggleButtonGroup(
              type: M3EButtonGroupType.connected,
              size: M3EButtonSize.sm,
              semanticLabel: 'Lyrics source',
              selectedIndex: LyricsSource.values.indexOf(source),
              onSelectedIndexChanged: (i) {
                // Selection-required: tapping the active source keeps it.
                if (i == null) return;
                state.setLyricsSource(LyricsSource.values[i]);
              },
              actions: [
                for (final s in LyricsSource.values)
                  M3EToggleButtonGroupAction(label: Text(s.label)),
              ],
              decoration: toggleButtonGroupDecoration(scheme),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  icon: const Icon(Icons.fullscreen_rounded),
                  tooltip: 'Fullscreen lyrics',
                  // Always enabled: lyrics may still be fetching, and the
                  // fullscreen view follows them live when they land.
                  onPressed: state.expandLyrics,
                ),
              ),
            ),
          ],
        ),
        Expanded(
          child: _LyricsBody(ctrl: _ctrl, large: false),
        ),
      ],
    );
  }
}

/// Lyrics content shared by the tab and the fullscreen view:
/// shimmering placeholder lines while fetching (same rows as
/// the loaded list, so content reveals in place), the synced
/// list when loaded, a static note when nothing was found.
class _LyricsBody extends StatelessWidget {
  const _LyricsBody({required this.ctrl, required this.large});

  final ScrollController ctrl;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final lyrics = context.select<AppState, List<LyricLine>>((s) => s.lyrics);
    final loading = context.select<AppState, bool>((s) => s.lyricsLoading);
    final state = context.read<AppState>();
    if (lyrics.isEmpty && loading) {
      return Skeletonizer(
        enabled: true,
        enableSwitchAnimation: true,
        child: LyricsList(
          ctrl: ctrl,
          lyrics: placeholderLyrics,
          positionMs: 0,
          state: state,
          large: large,
        ),
      );
    }
    if (lyrics.isEmpty) {
      return Center(
        child: Text(
          'No lyrics found',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    // Active-line highlight + auto-scroll follow progress
    // ticks, not full rebuilds.
    return ValueListenableBuilder<int>(
      valueListenable: state.progressTick,
      builder: (context, _, _) {
        final positionMs = state.player.state.positionMs;
        return LyricsList(
          ctrl: ctrl,
          lyrics: lyrics,
          positionMs: positionMs,
          state: state,
          large: large,
        );
      },
    );
  }
}

/// Full-screen lyrics: big auto-scrolling lines with the mini player
/// bar at the bottom. Entered from the Lyrics tab, exited via the
/// collapse button (or Esc); closing Now Playing resets it.
class _FullscreenLyricsView extends StatefulWidget {
  const _FullscreenLyricsView({
    required this.track,
    required this.palette,
    required this.backdrop,
  });

  final Track track;
  final List<Color> palette;
  final Color backdrop;

  @override
  State<_FullscreenLyricsView> createState() => _FullscreenLyricsViewState();
}

class _FullscreenLyricsViewState extends State<_FullscreenLyricsView> {
  final ScrollController _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: widget.backdrop,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: PaletteBackdrop(palette: widget.palette),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              screenPadding,
              screenPadding,
              screenPadding,
              0,
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.fullscreen_exit_rounded),
                      tooltip: 'Exit fullscreen lyrics',
                      onPressed: state.collapseLyrics,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            widget.track.artistNames(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _LyricsBody(ctrl: _ctrl, large: true),
                ),
                const PlayerBar(tappable: false),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final track = context.select<AppState, Track?>(
      (s) => s.playerState.current,
    );
    // Duration latches 0 → actual once the engine reports; the select
    // keeps ticks out of this tab.
    final durationMs = context.select<AppState, int>(
      (s) => s.playerState.durationMs,
    );
    if (track == null) return const SizedBox.shrink();
    final shownMs = durationMs > 0
        ? durationMs
        : (track.durationSec > 0 ? track.durationSec * 1000 : 0);
    Widget row(String label, String value, {VoidCallback? onTap}) {
      final scheme = Theme.of(context).colorScheme;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  Text(
                    value.isEmpty ? 'Unknown' : value,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: onTap != null ? scheme.primary : scheme.onSurface,
                      decoration: onTap != null
                          ? TextDecoration.underline
                          : TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(color: scheme.surfaceContainerHigh, height: 1),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        row('Title', track.title),
        if (track.artists.isEmpty)
          row('Artists', '')
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Artists',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 0; i < track.artists.length; i++) ...[
                            InkWell(
                              onTap: () {
                                state.closeNow();
                                state.openArtist(track.artists[i], track);
                              },
                              child: Text(
                                track.artists[i].name,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                      decoration: TextDecoration.underline,
                                    ),
                              ),
                            ),
                            if (i != track.artists.length - 1)
                              Text(
                                ', ',
                                style: Theme.of(context).textTheme.bodyLarge,
                              ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Divider(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                height: 1,
              ),
            ],
          ),
        if (track.album != null)
          row(
            'Album${track.album!.kind != null ? ' (${track.album!.kind!.label})' : ''}',
            track.album!.name,
            onTap: track.album!.browseId == null
                ? null
                : () {
                    state.closeNow();
                    state.openAlbum(track, track.album!);
                  },
          )
        else
          row('Album', ''),
        row('Year', track.album?.year ?? ''),
        row('Duration', shownMs > 0 ? formatClock(shownMs) : ''),
        if (track.views.trim().isNotEmpty) row('Views', track.views),
        row('Likes', _fmtCount(track.likeCount)),
      ],
    );
  }
}



String _fmtCount(int n) {
  if (n < 0) return '';
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final v = n / 1000;
    return v >= 100 ? '${v.round()}K' : '${v.toStringAsFixed(1)}K';
  }
  final m = n / 1000000;
  return m >= 100 ? '${m.round()}M' : '${m.toStringAsFixed(1)}M';
}

/// Sleep timer option picked from the sheet.
enum _SleepChoice { off, m15, m30, m45, m60, endOfTrack, endOfQueue }

/// Clock button opening the sleep timer sheet. Static indicator
/// only (active color) — the live remaining time lives in the header
/// menu label, so no ticking timers exist anywhere in this UI.
class _SleepTimerButton extends StatelessWidget {
  const _SleepTimerButton({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, SleepTimerMode>(
      (s) => s.playerState.sleepTimerMode,
    );
    final scheme = Theme.of(context).colorScheme;
    final active = mode != SleepTimerMode.off;
    return IconButton(
      icon: Icon(
        active ? Icons.bedtime_rounded : Icons.bedtime_outlined,
      ),
      tooltip: active ? 'Sleep timer on' : 'Sleep timer',
      color: active ? scheme.primary : scheme.onSurface,
      onPressed: () => _showSleepTimerSheet(context),
    );
  }
}

/// Sleep timer option sheet. Returns the choice; the caller applies
/// it so the dialog stays free of player wiring.
Future<void> _showSleepTimerSheet(BuildContext context) async {
  final mode = context.read<AppState>().playerState.sleepTimerMode;
  String label(_SleepChoice c) => switch (c) {
        _SleepChoice.off => 'Cancel timer',
        _SleepChoice.m15 => 'In 15 minutes',
        _SleepChoice.m30 => 'In 30 minutes',
        _SleepChoice.m45 => 'In 45 minutes',
        _SleepChoice.m60 => 'In 1 hour',
        _SleepChoice.endOfTrack => 'End of track',
        _SleepChoice.endOfQueue => 'End of queue',
      };
  final choices = [
    if (mode != SleepTimerMode.off) _SleepChoice.off,
    _SleepChoice.m15,
    _SleepChoice.m30,
    _SleepChoice.m45,
    _SleepChoice.m60,
    _SleepChoice.endOfTrack,
    _SleepChoice.endOfQueue,
  ];
  final choice = await showDialog<_SleepChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Sleep timer'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in choices)
            M3ETextButton(
              onPressed: () => Navigator.of(context).pop(c),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(label(c)),
              ),
            ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final player = context.read<AppState>().player;
  switch (choice) {
    case _SleepChoice.off:
      player.cancelSleepTimer();
    case _SleepChoice.m15:
      player.setSleepTimerDuration(const Duration(minutes: 15));
    case _SleepChoice.m30:
      player.setSleepTimerDuration(const Duration(minutes: 30));
    case _SleepChoice.m45:
      player.setSleepTimerDuration(const Duration(minutes: 45));
    case _SleepChoice.m60:
      player.setSleepTimerDuration(const Duration(hours: 1));
    case _SleepChoice.endOfTrack:
      player.setSleepTimerEndOfTrack();
    case _SleepChoice.endOfQueue:
      player.setSleepTimerEndOfQueue();
  }
}
