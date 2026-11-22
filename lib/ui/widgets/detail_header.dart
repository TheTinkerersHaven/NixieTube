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
    final compact = isCompactLayout(context);
    return Padding(
      // A phone top bar hugs its back button: the icon button already
      // carries its own 12px inset, so the header only adds a little on
      // top of it. Without a back button the title lines up with the
      // screen content instead of hugging the edge.
      padding: compact
          ? EdgeInsets.fromLTRB(onBack == null ? screenPadding : 4, 4, 8, 4)
          : const EdgeInsets.all(screenPadding),
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: compact
                  ? Theme.of(context).textTheme.titleLarge
                  : Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
