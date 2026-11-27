// The shell's navigator: one route per navigation entry.
//
// The app's screens are real pages instead of a widget swapped into one
// slot, so back pops the top page — a tap on a back button, a system back
// gesture, or the Android predictive-back preview the platform drives
// while the finger is still down. The page underneath keeps its state,
// so returning to it shows what the user left.

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screens/detail_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';

/// The [Page] for one navigation entry.
///
/// The [Navigator] keys the route on [NavEntry.id] and reports a pop of a
/// page-based route through `onDidRemovePage`, which is how a system back
/// press gets back into the navigation stack.
class NavScreenPage extends Page<void> {
  const NavScreenPage({required super.key, required this.entry});

  final NavEntry entry;

  @override
  Route<void> createRoute(BuildContext context) => MaterialPageRoute<void>(
    settings: this,
    builder: (_) => NavScreenView(entry: entry),
  );
}

/// The screen of one entry, behind the gate that keeps a route from
/// popping while an overlay covers it.
///
/// The overlays (the phone's Now Playing view, fullscreen lyrics, an
/// opened playlist over the library) are drawn above the navigator but
/// are not routes, so the page under them has to refuse the pop: without
/// it a back gesture would throw away the page the user is still looking
/// past, and the overlay would outlive its screen.
class NavScreenView extends StatelessWidget {
  const NavScreenView({super.key, required this.entry});

  final NavEntry entry;

  @override
  Widget build(BuildContext context) {
    final covered = context.select<AppState, bool>(
      (state) => _overlayCovers(state, entry),
    );
    // A page that is not on top is still built (that is what makes going
    // back instant) but must not keep animating behind the page above
    // it: shimmering skeletons and scroll physics would burn frames on
    // something nobody can see.
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    return PopScope(
      canPop: !covered,
      child: TickerMode(
        enabled: onTop,
        // The page carries its own base colour, so a push moves a whole
        // page — background included — instead of sliding one page's
        // elements over another's. Screens that paint their own wash
        // (home's gradient, the library and detail washes) still do; this
        // is the colour that used to sit behind them, static, outside the
        // navigator. A Material rather than a ColoredBox: it gives the
        // page's ink somewhere to paint, which a bare colour box between a
        // ListTile and its Material ancestor would hide.
        child: Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: _screenFor(entry),
        ),
      ),
    );
  }
}

bool _overlayCovers(AppState state, NavEntry entry) {
  if (state.nowOpen || state.lyricsFull) return true;
  return entry.screen == Screen.library && state.openedPlaylist != null;
}

Widget _screenFor(NavEntry entry) {
  switch (entry.screen) {
    case Screen.home:
      return const HomeScreen();
    case Screen.search:
      return const SearchScreen();
    case Screen.library:
      return const LibraryScreen();
    case Screen.settings:
      return const SettingsScreen();
    case Screen.detail:
      final item = entry.detail;
      if (item == null) return const SizedBox.shrink();
      return DetailScreen(item: item);
  }
}
