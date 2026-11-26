// Shared top bar for the album/playlist detail views and the library's
// open-playlist view: back, title and a trailing menu or action.

import 'package:flutter/foundation.dart';
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
    this.scrollPixels,
  });

  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;

  /// Scroll offset of the page's list, on pages with a hero card. The
  /// hero shows the title at rest, so on phones the top bar's title
  /// fades in over the first ~100dp of scroll instead of duplicating
  /// it. Null (or a wide window) keeps the title fully visible.
  final ValueListenable<double>? scrollPixels;

  @override
  Widget build(BuildContext context) {
    final compact = isCompactLayout(context);
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: compact
          ? Theme.of(context).textTheme.titleLarge
          : Theme.of(context).textTheme.headlineMedium,
    );
    final Widget titleWidget = scrollPixels == null
        ? titleText
        : ValueListenableBuilder<double>(
            valueListenable: scrollPixels!,
            builder: (context, pixels, child) {
              final opacity = compact ? (pixels / 100).clamp(0.0, 1.0) : 1.0;
              return Opacity(opacity: opacity, child: child);
            },
            child: titleText,
          );
    Widget row = Row(
      children: [
        if (onBack != null)
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Back',
            onPressed: onBack,
          ),
        Expanded(child: titleWidget),
        ?trailing,
      ],
    );
    // A phone top bar is a fixed 56dp sliver; wider windows keep their
    // padded, taller header.
    if (compact) row = SizedBox(height: 56, child: row);
    return Padding(
      // A phone top bar hugs its back button: the icon button already
      // carries its own 12px inset, so the header only adds a little on
      // top of it. Without a back button the title lines up with the
      // screen content instead of hugging the edge.
      padding: compact
          ? EdgeInsets.fromLTRB(onBack == null ? screenPadding : 4, 0, 8, 0)
          : const EdgeInsets.all(screenPadding),
      child: row,
    );
  }
}
