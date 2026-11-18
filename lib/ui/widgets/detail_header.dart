// Shared top bar for the album/playlist detail views and the library's
// open-playlist view: back, title and a trailing menu or action.

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// The top sliver: a back button when [onBack] is given, the page title,
/// and a trailing action such as the overflow menu.
class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.title,
    this.onBack,
    this.trailing,
  });

  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(screenPadding),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: 'Back',
              onPressed: onBack,
            ),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
