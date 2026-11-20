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
    // With edge-to-edge the navigation bar runs behind the gesture
    // pill, so its real height is the bar plus the bottom view inset.
    // The floating mini player bar has to clear both.
    final navInset = MediaQuery.viewPaddingOf(context).bottom;

    return Stack(
      children: [
        Column(
          children: [
            Expanded(child: body),
            NavigationBar(
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
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: mobileNavHeight + navInset,
          child: const PlayerBarMobile(),
        ),
      ],
    );
  }
}
