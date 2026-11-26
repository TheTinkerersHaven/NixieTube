// Desktop application shell: persistent left sidebar (NavigationRail)
// and bottom playback bar.

import 'package:material_ui/material_ui.dart';

import 'widgets/player_bar.dart';

/// Desktop shell view: persistent navigation rail on the left,
/// content and floating banners in the middle, and pinned playback bar
/// at the bottom.
class AppShellDesktop extends StatelessWidget {
  const AppShellDesktop({
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
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NavigationRail(
              selectedIndex: navIndex,
              onDestinationSelected: (i) => onNavTap(context, i),
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
            Expanded(child: body),
          ],
        ),
        const Positioned(left: 0, right: 0, bottom: 0, child: PlayerBar()),
      ],
    );
  }
}
