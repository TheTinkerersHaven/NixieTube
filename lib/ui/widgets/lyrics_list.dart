// Synced-lyrics list with active-line follow, shared by the Now Playing
// lyrics tab and the full-screen lyrics view: tap-to-seek rows,
// auto-scroll tracking the song position, optional large type.

import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../app_state.dart';

/// Synced lyric lines with a swelling active line that auto-scrolls
/// into view as [positionMs] advances.
class LyricsList extends StatefulWidget {
  const LyricsList({
    super.key,
    required this.ctrl,
    required this.lyrics,
    required this.positionMs,
    required this.state,
    this.large = false,
  });

  final ScrollController ctrl;
  final List<LyricLine> lyrics;
  final int positionMs;
  final AppState state;

  /// Full-screen presentation: bigger type and airier rows.
  final bool large;

  @override
  State<LyricsList> createState() => _LyricsListState();
}

class _LyricsListState extends State<LyricsList> {
  /// Last line index we auto-scrolled to. Progress ticks rebuild twice a
  /// second; without this guard every tick restarts a 300ms scroll
  /// animation, which janks and fights manual scrolling.
  int _autoIndex = -1;

  /// One stable key per row. Rows keep their Element (and their
  /// AnimatedDefaultTextStyle state) as the active line moves, so the
  /// highlight swells instead of snapping — keying only the active row
  /// would remount two rows on every line change and the animation
  /// would never play. Doubles as the auto-scroll measuring point.
  List<GlobalKey> _rowKeys = const [];

  void _ensureKeys(int count) {
    if (_rowKeys.length != count) {
      _rowKeys = List.generate(count, (_) => GlobalKey());
    }
  }

  @override
  void didUpdateWidget(LyricsList old) {
    super.didUpdateWidget(old);
    if (!identical(old.lyrics, widget.lyrics)) _autoIndex = -1;
  }

  @override
  Widget build(BuildContext context) {
    _ensureKeys(widget.lyrics.length);
    final lyrics = widget.lyrics;
    final ctrl = widget.ctrl;
    final timed = lyrics.any((l) => l.timeMs >= 0);
    var currentIndex = -1;
    if (timed) {
      for (var i = 0; i < lyrics.length; i++) {
        if (lyrics[i].timeMs <= widget.positionMs) currentIndex = i;
      }
      if (currentIndex < 0) currentIndex = 0;
    }
    if (currentIndex >= 0 && currentIndex != _autoIndex) {
      _autoIndex = currentIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // The lyrics may have swapped since this frame was scheduled;
        // the fresh key list may no longer cover the stale index.
        if (currentIndex < 0 || currentIndex >= _rowKeys.length) return;
        final ctx = _rowKeys[currentIndex].currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.35,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
    final scheme = Theme.of(context).colorScheme;
    // No scrollbar: the list follows playback on its own and a thumb
    // flashing twice a second is visual noise.
    return ScrollConfiguration(
      behavior: const ScrollBehavior().copyWith(scrollbars: false),
      child: ListView.builder(
        controller: ctrl,
        padding: EdgeInsets.symmetric(
          vertical: widget.large ? 32 : 24,
          horizontal: 8,
        ),
        itemCount: lyrics.length,
        itemBuilder: (context, i) {
          final line = lyrics[i];
          final active = i == currentIndex;
          return InkWell(
            key: _rowKeys[i],
            onTap: line.timeMs >= 0
                ? () => widget.state.player.seekTo(line.timeMs)
                : null,
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: widget.large ? 12 : 8,
                horizontal: 16,
              ),
              // Quick style swell on the active line only; idle rows
              // keep a static style so ticks don't animate the world.
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                textAlign: TextAlign.center,
                style:
                    (active
                            ? (widget.large
                                ? Theme.of(context).textTheme.headlineMedium
                                : Theme.of(context).textTheme.titleLarge)
                            : (widget.large
                                ? Theme.of(context).textTheme.titleLarge
                                : Theme.of(context).textTheme.bodyLarge))
                        ?.copyWith(
                          color: active
                              ? scheme.primary
                              : scheme.onSurfaceVariant.withValues(alpha: 0.55),
                        ) ??
                    DefaultTextStyle.of(context).style,
                child: Text(line.text),
              ),
            ),
          );
        },
      ),
    );
  }
}
