// Full Now Playing view ported from Kotlin `NowPlaying`: tinted backdrop,
// cover, transport controls and Up-next/Lyrics/Info tabs. Shows nothing
// when no track is loaded.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' hide RepeatMode;
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../../core/player/player_state.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/artwork_image.dart';
import '../widgets/gapped_rounded_track_shape.dart';
import '../widgets/lyrics_list.dart';
import '../widgets/palette_backdrop.dart';
import '../widgets/player_bar.dart';
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
                    PopupMenuButton<_NowMenuAction>(
                      icon: const Icon(Icons.more_vert_rounded),
                      tooltip: 'Options',
                      onSelected: (action) =>
                          _handleNowMenu(context, action, track),
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: _NowMenuAction.shareLink,
                          child: _NowMenuRow(
                            icon: Icons.link_rounded,
                            label: 'Share link',
                          ),
                        ),
                        PopupMenuItem(
                          value: _NowMenuAction.openYoutube,
                          child: _NowMenuRow(
                            icon: Icons.open_in_new_rounded,
                            label: 'Open in YouTube',
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
class _TransportColumn extends StatelessWidget {
  const _TransportColumn({required this.track, required this.artSize});

  final Track track;
  final double artSize;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
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
    final gdataAvailable = context.select<AppState, bool>(
      (s) => s.gdataAvailable,
    );
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
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            track.title,
            style: Theme.of(context).textTheme.headlineSmall,
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
                onPressed: () => state.player.toggleShuffle(),
              ),
              // Sized M3 targets like Kotlin: 60dp buttons, 48dp glyphs.
              IconButton(
                icon: const Icon(Icons.skip_previous_rounded, size: 48),
                tooltip: 'Previous',
                style: IconButton.styleFrom(
                  minimumSize: const Size(60, 60),
                  foregroundColor: scheme.onSurface,
                ),
                onPressed: () => state.player.previous(),
              ),
              if (loading)
                // Own layer: the every-frame spinner animation must not
                // repaint the cover, texts and buttons around it.
                const RepaintBoundary(
                  child: SizedBox(
                    width: 76,
                    height: 76,
                    child: Center(
                      child: SizedBox(
                        width: 60,
                        height: 60,
                        child: CircularProgressIndicator(strokeWidth: 5),
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
                onPressed: () => state.player.next(),
              ),
              IconButton(
                icon: Icon(
                  repeatOne ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                ),
                tooltip: 'Repeat',
                color: repeatOff ? scheme.onSurface : scheme.primary,
                onPressed: () => state.player.cycleRepeat(),
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
              if (signedIn) ...[
                IconButton(
                  icon: const Icon(Icons.thumb_up_rounded),
                  tooltip: track.rating == RatingStatus.like
                      ? 'Remove like'
                      : 'Like',
                  color: track.rating == RatingStatus.like
                      ? scheme.primary
                      : scheme.onSurface,
                  onPressed: () => state.rateCurrentFeedback(
                    context,
                    track.rating == RatingStatus.like
                        ? RatingStatus.indifferent
                        : RatingStatus.like,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.thumb_down_rounded),
                  tooltip: track.rating == RatingStatus.dislike
                      ? 'Remove dislike'
                      : 'Dislike',
                  color: track.rating == RatingStatus.dislike
                      ? scheme.primary
                      : scheme.onSurface,
                  onPressed: () => state.rateCurrentFeedback(
                    context,
                    track.rating == RatingStatus.dislike
                        ? RatingStatus.indifferent
                        : RatingStatus.dislike,
                  ),
                ),
                if (gdataAvailable)
                  IconButton(
                    icon: const Icon(Icons.playlist_add_rounded),
                    tooltip: 'Add to playlist',
                    onPressed: () => state.openPlaylistDialog(track),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Volume slider: shared [VolumeSlider] (custom track, shrinking bar
/// thumb) with local drag state and throttled engine updates. Volume-only
/// player updates bump volumeTick instead of notifying, so dragging never
/// rebuilds the app (see isVolumeOnlyUpdate).

/// Seek slider with local drag state so the thumb follows the finger;
/// the seek fires on release so playback never stutters mid-drag.
class _SeekSlider extends StatefulWidget {
  const _SeekSlider({required this.state});

  final AppState state;

  @override
  State<_SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<_SeekSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.state.progressTick,
      builder: (context, _, _) {
        final s = widget.state.player.state;
        final max = s.durationMs > 0 ? s.durationMs.toDouble() : 1.0;
        final live = s.positionMs.toDouble().clamp(0, max);
        // Same conformed look as the mini player's progress slider: the
        // shared gapped rounded track plus a bar thumb that shrinks on
        // press (the default round thumb would not match it).
        return SliderTheme(
          data: const SliderThemeData(
            trackHeight: 16,
            trackShape: GappedRoundedTrackShape(),
            thumbShape: ShrinkBarThumbShape(height: 48),
            // Continuous sliders hide the indicator by default
            // (onlyForDiscrete); force it on for seek drags.
            showValueIndicator: ShowValueIndicator.onDrag,
            // ignore: deprecated_member_use
            year2023: false,
          ),
          child: Slider(
            value: (_dragValue ?? live).clamp(0, max).toDouble(),
            min: 0,
            max: max,
            // A non-null label enables the value-indicator bubble; it is
            // recomputed each build, so it follows the drag value.
            label: _fmtMs((_dragValue ?? live).toInt()),
            onChangeEnd: (v) {
              final target = v.toInt();
              setState(() => _dragValue = null);
              widget.state.player.seekTo(target);
            },
            onChanged: (v) => setState(() => _dragValue = v),
          ),
        );
      },
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
            child: RepaintBoundary(child: _SeekSlider(state: state)),
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
              _fmtMs(s.positionMs),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              _fmtMs(s.durationMs),
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
enum _NowMenuAction { shareLink, openYoutube }

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
  }
}

/// Compact icon + label row for a popup menu item.
class _NowMenuRow extends StatelessWidget {
  const _NowMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: scheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

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
            child: Row(
              children: [
                FilterChip(
                  selected: autoplay,
                  label: Text(
                    'Autoplay',
                    style: TextStyle(color: scheme.onSurface),
                  ),
                  backgroundColor: chipFill,
                  selectedColor: scheme.primary.withValues(alpha: 0.28),
                  checkmarkColor: scheme.onSurface,
                  side: chipEdge,
                  onSelected: (_) => state.player.toggleAutoplay(),
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
                          final current = state.player.state.current;
                          if (current == null) return;
                          final res = await state.startRadio(current);
                          if (!context.mounted) return;
                          // User moved on mid-fetch: stay silent.
                          if (state.player.state.current?.videoId !=
                              current.videoId) {
                            return;
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
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
        Expanded(
          child: ListView.builder(
            itemCount: queue.length,
            itemBuilder: (context, i) {
              final t = queue[i];
              return TrackRow(
                track: t,
                playing: i == index,
                onPlay: () => state.player.playAt(i),
                rateable: true,
              );
            },
          ),
        ),
      ],
    );
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
    final lyrics = context.select<AppState, List<LyricLine>>((s) => s.lyrics);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(Icons.fullscreen_rounded),
              tooltip: 'Fullscreen lyrics',
              // Always enabled: lyrics may still be fetching, and the
              // fullscreen view follows them live when they land.
              onPressed: state.expandLyrics,
            ),
          ],
        ),
        Expanded(
          child: lyrics.isEmpty
              ? Center(
                  child: Text(
                    'No lyrics found',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              // Active-line highlight + auto-scroll follow progress
              // ticks, not full rebuilds.
              : ValueListenableBuilder<int>(
                  valueListenable: state.progressTick,
                  builder: (context, _, _) {
                    final positionMs = state.player.state.positionMs;
                    return LyricsList(
                      ctrl: _ctrl,
                      lyrics: lyrics,
                      positionMs: positionMs,
                      state: state,
                    );
                  },
                ),
        ),
      ],
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
    final lyrics = context.select<AppState, List<LyricLine>>((s) => s.lyrics);
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
            padding: const EdgeInsets.all(screenPadding),
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
                  child: lyrics.isEmpty
                      ? Center(
                          child: Text(
                            'No lyrics found',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : ValueListenableBuilder<int>(
                          valueListenable: state.progressTick,
                          builder: (context, _, _) {
                            return LyricsList(
                              ctrl: _ctrl,
                              lyrics: lyrics,
                              positionMs: state.player.state.positionMs,
                              state: state,
                              large: true,
                            );
                          },
                        ),
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
        row('Duration', shownMs > 0 ? _fmtMs(shownMs) : ''),
        if (track.views.trim().isNotEmpty) row('Views', track.views),
        row('Likes', _fmtCount(track.likeCount)),
      ],
    );
  }
}

String _fmtMs(int ms) {
  if (ms <= 0) return '0:00';
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
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
