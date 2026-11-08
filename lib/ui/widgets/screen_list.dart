// The scrollable page body shared by the top-level screens.
//
// Every screen scrolls with the same feel and the same clearance for
// the floating player bar, so those settings live in one place.

import 'package:material_ui/material_ui.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../theme.dart';

/// A page body that scrolls with the app-wide feel.
///
/// [bottomClearance] adds room below the last row so the floating
/// player bar never covers it.
Widget screenList({
  required List<Widget> children,
  double bottomClearance = playerBarClearance,
}) {
  return SilkyListView(
    scrollSpeed: 1.5,
    silkyScrollDuration: const Duration(milliseconds: 700),
    animationCurve: Curves.easeOutQuart,
    padding: EdgeInsets.fromLTRB(
      screenPadding,
      screenPadding,
      screenPadding,
      screenPadding + bottomClearance,
    ),
    children: children,
  );
}

/// A page body for short, fixed content, scrolling with the same feel.
///
/// Unlike [screenList], the whole column is built at once, so a section
/// can be scrolled to by its key even before it has been on screen.
Widget screenColumn({
  required List<Widget> children,
  double bottomClearance = playerBarClearance,
}) {
  return SilkySingleChildScrollView(
    scrollSpeed: 1.5,
    silkyScrollDuration: const Duration(milliseconds: 700),
    animationCurve: Curves.easeOutQuart,
    padding: EdgeInsets.fromLTRB(
      screenPadding,
      screenPadding,
      screenPadding,
      screenPadding + bottomClearance,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

/// A page body built lazily, scrolling with the app-wide feel.
///
/// [topPadding] replaces the default top inset for bodies that start
/// with a header of their own.
Widget screenListBuilder({
  required int itemCount,
  required NullableIndexedWidgetBuilder itemBuilder,
  double topPadding = screenPadding,
  double horizontalPadding = screenPadding,
  double bottomClearance = playerBarClearance,
}) {
  return SilkyListView.builder(
    scrollSpeed: 1.5,
    silkyScrollDuration: const Duration(milliseconds: 700),
    animationCurve: Curves.easeOutQuart,
    padding: EdgeInsets.fromLTRB(
      horizontalPadding,
      topPadding,
      horizontalPadding,
      screenPadding + bottomClearance,
    ),
    itemCount: itemCount,
    itemBuilder: itemBuilder,
  );
}
