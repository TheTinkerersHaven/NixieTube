// One track menu at a time across the app.
//
// Every track row and rail card owns an [M3EMenuController], but an
// [M3EMenuAnchor] only closes sibling submenus of the same parent — two
// separate anchors can both stay open. Right-clicking another row while a
// menu is open would otherwise either stack a second menu or have the
// first menu's dismiss barrier swallow the click. The coordinator makes
// the newest menu win: opening one closes whichever menu is open.

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../theme.dart';
import 'track_row.dart';

/// Tracks the currently open track menu.
class TrackMenuCoordinator extends ChangeNotifier {
  M3EMenuController? _active;
  M3EMenuController? _previous;

  /// Controllers whose anchor is currently mounted. A target drops its
  /// anchor while another menu is active, so opening has to wait for the
  /// rebuild that mounts it again.
  final Set<M3EMenuController> _mounted = {};

  M3EMenuController? get active => _active;

  /// True when [controller]'s anchor should be removed: it is the menu
  /// that was just replaced, and its overlay has to go at once.
  bool shouldDropAnchor(M3EMenuController controller) =>
      identical(_previous, controller) && !identical(_active, controller);

  /// Records whether [controller]'s anchor is in the tree. Called from
  /// build (a plain set mutation, no notification).
  void setMounted(M3EMenuController controller, bool mounted) {
    if (mounted) {
      _mounted.add(controller);
    } else {
      _mounted.remove(controller);
    }
  }

  /// Opens [controller] at [position], closing the menu that is open.
  ///
  /// The previous target drops its anchor on the rebuild below, which
  /// removes its overlay at once: letting it animate out would make it
  /// jump, because [M3EMenuController.close] clears the anchor position
  /// that the overlay was laid out from.
  void open(M3EMenuController controller, {Offset? position}) {
    final previous = _active;
    if (!identical(previous, controller)) {
      _previous = previous;
      _active = controller;
      notifyListeners();
    }
    if (_mounted.contains(controller)) {
      controller.open(position: position);
      return;
    }
    // The target mounts its anchor on the rebuild above; opening before
    // it is attached would be dropped, so wait for the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_active, controller)) return;
      if (!_mounted.contains(controller)) return;
      controller.open(position: position);
    });
  }

  /// Forgets [controller] when its menu closes.
  void close(M3EMenuController controller) {
    if (!identical(_active, controller)) return;
    _active = null;
    _previous = null;
    notifyListeners();
  }
}

/// Provides the app-wide [TrackMenuCoordinator] to track menus.
class TrackMenuScope extends InheritedWidget {
  const TrackMenuScope({
    super.key,
    required this.coordinator,
    required super.child,
  });

  final TrackMenuCoordinator coordinator;

  /// The coordinator above [context], or null when no scope is present
  /// (a bare widget test): callers then open their own menu directly.
  static TrackMenuCoordinator? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TrackMenuScope>()?.coordinator;

  @override
  bool updateShouldNotify(TrackMenuScope oldWidget) => false;
}

/// Opens [controller] through the app coordinator when one is available.
void openTrackMenu(
  BuildContext context,
  M3EMenuController controller, {
  Offset? position,
}) {
  final coordinator = TrackMenuScope.maybeOf(context);
  if (coordinator == null) {
    controller.open(position: position);
  } else {
    coordinator.open(controller, position: position);
  }
}

/// Clears [controller] from the app coordinator when its menu closes.
void closeTrackMenu(BuildContext context, M3EMenuController controller) {
  TrackMenuScope.maybeOf(context)?.close(controller);
}

/// State plumbing shared by every widget that hosts a track menu.
///
/// Owns the menu controller, keeps it registered with the app
/// coordinator, and rebuilds only when its anchor has to appear or
// disappear. Hosts add their own key to the subtree that must survive
// the swap (see [menuChildKey]).
mixin TrackMenuHost<T extends StatefulWidget> on State<T> {
  /// The menu this host opens.
  late final M3EMenuController menuController = M3EMenuController();

  /// Key for the subtree that moves in and out of the menu anchor, so
  /// reparenting it preserves state (notably decoded artwork).
  final GlobalKey menuChildKey = GlobalKey();

  TrackMenuCoordinator? _coordinator;
  bool _anchorVisible = true;

  /// Whether the anchor is currently in the tree.
  bool get anchorVisible => _anchorVisible;

  /// Whether the anchor should be in the tree: every host except the
  /// menu that was just replaced.
  bool get anchorWanted =>
      _coordinator == null || !_coordinator!.shouldDropAnchor(menuController);

  @override
  void initState() {
    super.initState();
    _coordinator = TrackMenuScope.maybeOf(context);
    _coordinator?.addListener(_onCoordinatorChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final coordinator = TrackMenuScope.maybeOf(context);
    if (!identical(coordinator, _coordinator)) {
      _coordinator?.removeListener(_onCoordinatorChanged);
      _coordinator = coordinator;
      _coordinator?.addListener(_onCoordinatorChanged);
    }
  }

  @override
  void dispose() {
    _coordinator?.removeListener(_onCoordinatorChanged);
    _coordinator?.setMounted(menuController, false);
    menuController.dispose();
    super.dispose();
  }

  void _onCoordinatorChanged() {
    if (!mounted) return;
    final visible =
        _coordinator == null || !_coordinator!.shouldDropAnchor(menuController);
    if (visible == _anchorVisible) return;
    setState(() => _anchorVisible = visible);
  }

  /// Records whether the anchor is in the tree. Call from build, after
  // computing visibility; a plain set mutation, no notification.
  void updateAnchorVisibility(bool visible) {
    _anchorVisible = visible;
    _coordinator?.setMounted(menuController, visible);
  }
}

///
/// Used by track rows, rail cards, quick-pick tiles and the song cards in
/// mixed shelves — anything that stands for one song. Set [enabled] to
/// false for hosts that own their own menu.
class TrackMenuTarget extends StatefulWidget {
  const TrackMenuTarget({
    super.key,
    required this.track,
    required this.child,
    this.showPlaylists = true,
    this.enabled = true,
  });

  final Track track;
  final Widget child;
  final bool showPlaylists;
  final bool enabled;

  @override
  State<TrackMenuTarget> createState() => _TrackMenuTargetState();
}

class _TrackMenuTargetState extends State<TrackMenuTarget>
    with TrackMenuHost<TrackMenuTarget> {
  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final showAnchor = anchorWanted;
    // While the previous menu is being replaced, drop the anchor: its
    // dispose removes the overlay immediately, with no jumpy close.
    updateAnchorVisibility(showAnchor);
    // On phones there is no right-click: press and hold the tile opens
    // the same menu at the press point.
    final longPress = isCompactLayout(context)
        ? (LongPressStartDetails details) => openTrackMenu(
            context,
            menuController,
            position: details.localPosition,
          )
        : null;
    Widget wrap(Widget child) => GestureDetector(
      onSecondaryTapDown: (details) => openTrackMenu(
        context,
        menuController,
        position: details.localPosition,
      ),
      onLongPressStart: longPress,
      child: child,
    );
    final child = KeyedSubtree(key: menuChildKey, child: widget.child);
    if (!showAnchor) return wrap(child);
    return wrap(
      M3EMenuAnchor(
        controller: menuController,
        menuChildren: trackMenuItems(
          context,
          widget.track,
          showPlaylists: widget.showPlaylists,
        ),
        builder: (ctx, controller, child) => child!,
        onClose: () => closeTrackMenu(context, menuController),
        // Translucent so a right-click on another tile reaches it; the
        // coordinator closes this menu as the new one opens.
        consumeOutsideTaps: false,
        child: child,
      ),
    );
  }
}
