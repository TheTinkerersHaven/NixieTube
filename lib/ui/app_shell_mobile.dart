// Mobile application shell: bottom NavigationBar and floating mini-player bar above it.

import 'package:material_ui/material_ui.dart';

import 'theme.dart';
import 'widgets/player_bar_mobile.dart';

/// Mobile shell view: full-width content with bottom NavigationBar
/// and a collapsible mini-player bar hovering above it.
class AppShellMobile extends StatelessWidget {
  const AppShellMobile({
    super.key,
    required this.body,
    required this.navIndex,
    required this.onNavTap,
  });

  final Widget body;
  final int? navIndex;
  final void Function(BuildContext context, int index) onNavTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // The body fills the full screen so in-screen positioned widgets
        // (like the library FAB) measure from the real bottom edge. Its
        // scrolling lists already pad by playerBarClearance, so their
        // ends still clear the player bar and the navigation bar.
        body,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The mini player sits above the navigation bar, never on
              // top of it: the bar's surface starts underneath, so the
              // two read as two stacked rows instead of one tall block.
              const PlayerBarMobile(),
              // The shell fills the window, so the status bar's top inset
              // is already handled per screen: drop it here, or the
              // NavigationBar's SafeArea adds it again above the icons and
              // makes the bar unnaturally tall. The bottom view padding is
              // kept so the bar clears the gesture pill.
              MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: NavigationBar(
                  height: mobileNavHeight,
                  maintainBottomViewPadding: true,
                  selectedIndex: navIndex ?? 0,
                  onDestinationSelected: (i) => onNavTap(context, i),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.home_rounded),
                      label: 'Home',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.search_rounded),
                      label: 'Search',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.library_music_rounded),
                      label: 'Library',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
