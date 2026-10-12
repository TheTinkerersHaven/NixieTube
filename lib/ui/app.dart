// Application shell ported from Kotlin `App`: navigation rail, screen
// body, mini player bar, Now Playing overlay, and playlist dialog.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'a11y.dart';
import 'screens/detail_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/now_playing_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/player_bar.dart';
import 'widgets/playlist_dialog.dart';

/// Single-window shell with rail navigation and overlays.
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          final state = context.read<AppState>();
          if (state.lyricsFull) {
            state.collapseLyrics();
            return KeyEventResult.handled;
          }
        }
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.space) {
          final focused = FocusManager.instance.primaryFocus;
          final editing =
              focused?.context?.findAncestorWidgetOfExactType<EditableText>() !=
              null;
          if (!editing) {
            final state = context.read<AppState>();
            if (state.playerState.current != null) {
              state.player.togglePlayPause();
              return KeyEventResult.handled;
            }
          }
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          // Full-height content as the Stack's sizing child; the player
          // bar floats above it (see below), so screens extend behind
          // the bar's transparent gap.
          Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    NavigationRail(
                      selectedIndex: _railIndex(
                        context.select<AppState, Screen>((s) => s.screen),
                      ),
                      onDestinationSelected: (i) => _onRailTap(context, i),
                      labelType: NavigationRailLabelType.all,
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.home_rounded),
                          label: Text('Home'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.search_rounded),
                          label: Text('Search'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.library_music_rounded),
                          label: Text('Library'),
                        ),
                      ],
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          Column(
                            children: [
                              Expanded(child: _Body()),
                            ],
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: _SessionBanner(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Positioned(left: 0, right: 0, bottom: 0, child: PlayerBar()),
          _NowPlayingOverlay(),
          const _DialogWatcher(),
          const _ErrorWatcher(),
        ],
      ),
    );
  }

  int? _railIndex(Screen screen) {
    switch (screen) {
      case Screen.home:
      case Screen.detail:
        return 0;
      case Screen.search:
        return 1;
      case Screen.library:
        return 2;
      case Screen.settings:
        return null;
    }
  }

  void _onRailTap(BuildContext context, int index) {
    final state = context.read<AppState>();
    switch (index) {
      case 0:
        state.go(Screen.home);
      case 1:
        state.go(Screen.search);
      case 2:
        state.go(Screen.library);
    }
  }
}

class _Body extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final screen = context.select<AppState, Screen>((s) => s.screen);
    final forward = context.select<AppState, bool>((s) => s.lastNavForward);
    // Router-aware switch: pushes rise from the bottom, back pops
    // sink down, always over a fade. Only the incoming child stays
    // mounted (the outgoing one drops at once), so lists never
    // double-mount mid-transition.
    return AnimatedSwitcher(
      duration: motionDuration(context, const Duration(milliseconds: 220)),
      switchInCurve: Curves.easeOut,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position:
              Tween(
                begin: Offset(0, forward ? 0.05 : -0.04),
                end: Offset.zero,
              ).animate(animation),
          child: child,
        ),
      ),
      layoutBuilder: (currentChild, previousChildren) =>
          Stack(children: [?currentChild]),
      child: KeyedSubtree(
        key: ValueKey(screen),
        child: _screenFor(screen),
      ),
    );
  }

  Widget _screenFor(Screen screen) {
    switch (screen) {
      case Screen.home:
      case Screen.detail:
        if (screen == Screen.detail) {
          return const DetailScreen();
        }
        return const HomeScreen();
      case Screen.search:
        return const SearchScreen();
      case Screen.library:
        return const LibraryScreen();
      case Screen.settings:
        return const SettingsScreen();
    }
  }
}

/// Persistent notice when a saved cookie session has expired.
///
/// stats/* beacons ack with 204 regardless of auth, so an expired
/// LOGIN_INFO otherwise goes unnoticed: history silently stops
/// recording. The banner only shows for a saved cookie session
/// (not OAuth-only, which has no cookie to expire) and is hidden
/// on the settings page, where the account card states it inline.
class _SessionBanner extends StatelessWidget {
  const _SessionBanner();

  @override
  Widget build(BuildContext context) {
    final screen = context.select<AppState, Screen>((s) => s.screen);
    final expired = context.select<AppState, bool>(
      (s) => s.hasCookieSession && !s.loginValid,
    );
    if (screen == Screen.settings || !expired) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: scheme.errorContainer,
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 20,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'YouTube session expired — listening history '
              'and likes won\'t sync.',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
          M3ETextButton(
            onPressed: () => context.read<AppState>().go(Screen.settings),
            child: Text(
              'Sign in',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// Now Playing overlay with a warm tree: the screen stays mounted
/// while closed (paint skipped via [Offstage]) so opening is
/// paint-only — no first build, layout, or cover decode runs inside
/// the 250ms slide. Track switches pre-warm it in the background
/// through the same narrow selects the visible view uses.
class _NowPlayingOverlay extends StatefulWidget {
  @override
  State<_NowPlayingOverlay> createState() => _NowPlayingOverlayState();
}

class _NowPlayingOverlayState extends State<_NowPlayingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  bool _lastOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: AppState.nowPlayingTransition,
      vsync: this,
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    // Flip the paint gate when the exit animation lands; the
    // controller ticks alone don't rebuild this wrapper.
    _controller.addStatusListener((status) {
      if ((status == AnimationStatus.dismissed ||
              status == AnimationStatus.completed) &&
          mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = context.select<AppState, bool>((s) => s.nowOpen);
    // Follow the reduced-motion setting: this selector joins the
    // one above, so a flip rebuilds the wrapper and the controller
    // adopts the collapsed duration — the next forward/reverse
    // (and the mirrored palette hold) is then instant.
    _controller.duration = context.select<AppState, Duration>(
      (s) => s.nowPlayingTransitionDuration,
    );
    // Drive the transition on flag flips only: steady-state opens
    // rebuild nothing but this wrapper — the content tree is already
    // laid out and its cover decoded.
    if (open != _lastOpen) {
      _lastOpen = open;
      if (open) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
    final parked =
        !open && _controller.status == AnimationStatus.dismissed;
    // Slide only, no fade: fading a fullscreen tree forces an offscreen
    // compositing layer for the whole transition, which is exactly the
    // raster work Impeller's OpenGL path is slowest at. A plain slide
    // is a cheap layer transform with identical motion language.
    return Offstage(
      offstage: parked,
      child: SlideTransition(
        position: _slide,
        // The overlay composites as one cached layer while sliding
        // instead of repainting artwork, rails and the backdrop wash
        // on every transition frame.
        child: const RepaintBoundary(child: NowPlayingScreen()),
      ),
    );
  }
}

/// Shows the playlist dialog while a dialog track is set.
class _DialogWatcher extends StatefulWidget {
  const _DialogWatcher();

  @override
  State<_DialogWatcher> createState() => _DialogWatcherState();
}

class _DialogWatcherState extends State<_DialogWatcher> {
  String? _shownFor;
  bool _dialogOpen = false;

  @override
  Widget build(BuildContext context) {
    final track = context.select<AppState, TrackRef?>(
      (s) => s.playlistDialogTrack == null
          ? null
          : TrackRef(s.playlistDialogTrack!.videoId),
    );
    final id = track?.videoId;
    if (id != _shownFor) {
      _shownFor = id;
      if (id != null && !_dialogOpen) {
        _dialogOpen = true;
        final appState = context.read<AppState>();
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          await showDialog(
            context: context,
            builder: (_) => const PlaylistPickerDialog(),
          );
          _dialogOpen = false;
          if (!mounted) return;
          if (appState.playlistDialogTrack?.videoId == id) {
            appState.closePlaylistDialog();
          }
        });
      }
    }
    return const SizedBox.shrink();
  }
}

/// Shows a SnackBar on fresh playback errors so a dead stream is
/// noticeable (and actionable) instead of a silent spinner or a tiny
/// inline line. Benign MPV cache noise is skipped.
class _ErrorWatcher extends StatefulWidget {
  const _ErrorWatcher();

  @override
  State<_ErrorWatcher> createState() => _ErrorWatcherState();
}

class _ErrorWatcherState extends State<_ErrorWatcher> {
  String? _shownFor;

  @override
  Widget build(BuildContext context) {
    final error =
        context.select<AppState, String?>((s) => s.playerState.error);
    if (error != _shownFor) {
      _shownFor = error;
      // The engine reports MPV's benign file-cache notice as an error;
      // it resolves on its own and must not page the user.
      if (error != null && !error.contains('Failed to create file cache')) {
        final messenger = ScaffoldMessenger.of(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          messenger.showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(
                'Playback failed — check your network connection or '
                'restart the app.',
              ),
            ),
          );
        });
      }
    }
    return const SizedBox.shrink();
  }
}

/// Stable identity wrapper so select() only fires on track change.
class TrackRef {
  TrackRef(this.videoId);
  final String videoId;

  @override
  bool operator ==(Object other) =>
      other is TrackRef && other.videoId == videoId;

  @override
  int get hashCode => videoId.hashCode;
}
