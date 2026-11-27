// The app's navigation stack.
//
// One entry per screen, and the shell renders that stack as a Navigator
// with one route per entry. Back therefore walks the stack a step at a
// time, and because every step is a real route the platform's back
// gesture can preview the pop instead of guessing at a widget swap.

import '../../core/innertube/metadata.dart' show canonical;
import '../../core/models/models.dart';

/// Navigation destinations for the app shell.
enum Screen { home, search, library, settings, detail }

/// One page of the navigation stack: the screen, and on a detail page
/// the browse item it was opened for.
class NavEntry {
  const NavEntry({required this.id, required this.screen, this.detail});

  /// Identity of the route built from this entry, never reused. The
  /// [Navigator] keys a page on it and reports pops by it.
  final int id;

  /// The screen this entry shows.
  final Screen screen;

  /// The item a [Screen.detail] page was opened for, null otherwise.
  final BrowseItem? detail;

  /// True when [screen] and [detail] would show the same page: the same
  /// screen, and for a detail page the same browse target.
  bool shows(Screen screen, BrowseItem? detail) {
    if (screen != this.screen) return false;
    if (screen != Screen.detail) return true;
    return this.detail?.browseId == detail?.browseId &&
        this.detail?.browseParams == detail?.browseParams;
  }
}

/// Normalizes a name for navigation matching.
String navigationName(String value) => canonical(value);

/// True when [left] and [right] represent the same navigation target.
bool sameNavigationName(String left, String right) {
  if (left.toLowerCase() == right.toLowerCase()) return true;
  final a = navigationName(left);
  return a.isNotEmpty && a == navigationName(right);
}

/// The navigation stack: which page is showing, and what back returns to.
///
/// The [pages] snapshot only changes when the stack does, so the shell
/// can select on it without rebuilding on every player tick.
class NavigationState {
  static const _initial = NavEntry(id: 0, screen: Screen.home);

  /// Deep enough for any browsing session; each mounted route holds its
  /// screen's state, so the stack is capped rather than unbounded.
  static const maxDepth = 24;

  final List<NavEntry> _stack = [_initial];
  List<NavEntry> _pages = const [_initial];
  int _nextId = 1;

  /// The page showing now.
  NavEntry get top => _stack.last;

  /// The current screen.
  Screen get screen => top.screen;

  /// The detail item being displayed, null outside detail screens.
  BrowseItem? get detailItem => top.detail;

  /// Whether the user can navigate back.
  bool get canGoBack => _stack.length > 1;

  /// The stack, oldest first, as an immutable snapshot.
  List<NavEntry> get pages => _pages;

  /// The most recent top-level destination below the current pushed
  /// screen (detail or settings), so the mobile bottom bar can keep the
  /// section the user came from highlighted. Null at a root destination.
  Screen? get parentScreen {
    for (var i = _stack.length - 2; i >= 0; i--) {
      final screen = _stack[i].screen;
      if (screen != Screen.detail && screen != Screen.settings) {
        return screen;
      }
    }
    return null;
  }

  /// Pushes [screen] on top of the current page, unless it is already
  /// the page showing — tapping the tab you are on is not a move.
  bool go(Screen screen, {BrowseItem? detail}) {
    if (top.shows(screen, detail)) return false;
    _stack.add(NavEntry(id: _nextId++, screen: screen, detail: detail));
    if (_stack.length > maxDepth) _stack.removeAt(0);
    _publish();
    return true;
  }

  /// Returns to the page below, if any.
  bool goBack() {
    if (_stack.length < 2) return false;
    _stack.removeLast();
    _publish();
    return true;
  }

  /// Drops the page the [Navigator] popped for us — a system back gesture
  /// or the platform's back button — returning to the page below. Does
  /// nothing for an id this stack no longer holds, which is what happens
  /// when [goBack] already removed it.
  bool popped(int id) {
    final index = _stack.indexWhere((entry) => entry.id == id);
    if (index < 0) return false;
    _stack.removeAt(index);
    if (_stack.isEmpty) _stack.add(_initial);
    _publish();
    return true;
  }

  void _publish() => _pages = List<NavEntry>.unmodifiable(_stack);
}
