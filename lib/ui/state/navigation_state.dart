// Navigation state for the NixieTube app.
//
// Owns the current screen, the detail item and the back stack. The
// owning AppState notifies its listeners after every navigation.

import '../../core/innertube/metadata.dart' show canonical;
import '../../core/models/models.dart';

/// Navigation destinations for the single-window app.
enum Screen { home, search, library, settings, detail }

/// History entry for back navigation.
class HistoryEntry {
  const HistoryEntry(this.screen, this.detail);
  final Screen screen;
  final BrowseItem? detail;
}

/// Normalizes a name for navigation matching.
String navigationName(String value) => canonical(value);

/// True when [left] and [right] represent the same navigation target.
bool sameNavigationName(String left, String right) {
  if (left.toLowerCase() == right.toLowerCase()) return true;
  final a = navigationName(left);
  return a.isNotEmpty && a == navigationName(right);
}

/// Loads the detail content for [item] when a detail screen opens.
typedef OnLoadDetail = void Function(BrowseItem item);

/// Navigation state: current screen, detail item and back stack.
class NavigationState {
  /// Creates a navigation state. [onLoadDetail] is invoked whenever a
  /// detail screen becomes current, so the detail content is reloaded
  /// on arrival instead of showing a stale page.
  NavigationState({this._onLoadDetail});

  Screen _screen = Screen.home;
  BrowseItem? _detailItem;
  final List<HistoryEntry> _history = [];
  bool _canGoBack = false;
  bool _lastNavForward = true;
  final OnLoadDetail? _onLoadDetail;

  /// The current screen being displayed.
  Screen get screen => _screen;

  /// The detail item being displayed, null outside detail screens.
  BrowseItem? get detailItem => _detailItem;

  /// Whether the user can navigate back.
  bool get canGoBack => _canGoBack;

  /// Direction of the latest navigation: false only for back pops.
  bool get lastNavForward => _lastNavForward;

  /// Navigates forward, pushing the current screen for [goBack].
  void go(Screen screen, {BrowseItem? detail}) {
    _lastNavForward = true;
    _history.add(HistoryEntry(_screen, _detailItem));
    if (_history.length > 100) _history.removeAt(0);
    _canGoBack = true;
    _screen = screen;
    _detailItem = detail;
    _loadDetailIfNeeded(screen, detail);
  }

  /// Returns to the pushed screen, if any. Returns false when the
  /// back stack is empty, so the caller can skip the notification.
  bool goBack() {
    if (_history.isEmpty) return false;
    _lastNavForward = false;
    final entry = _history.removeLast();
    _canGoBack = _history.isNotEmpty;
    _screen = entry.screen;
    _detailItem = entry.detail;
    _loadDetailIfNeeded(entry.screen, entry.detail);
    return true;
  }

  /// Reloads the current detail page in place, used after edits such
  /// as removing a track from an open playlist.
  void reloadDetail() {
    final item = _detailItem;
    if (item != null) _onLoadDetail?.call(item);
  }

  void _loadDetailIfNeeded(Screen screen, BrowseItem? detail) {
    if (screen != Screen.detail || detail == null) return;
    _onLoadDetail?.call(detail);
  }
}
