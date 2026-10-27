// Downward-opening port of m3e_core's M3EFabMenu.
//
// The package's M3EFabMenu hardcodes the M3E FAB-menu pattern of
// opening UPWARDS (the overlay follower anchors to the trigger's
// top edge with a negative offset). That is right for a bottom-
// anchored FAB, but our triggers sit in screen headers, where an
// upward menu flies off the top of the screen. This variant keeps
// every behavior identical — shape-morphing trigger, staggered
// spring reveal, tap-outside-to-close, pill items — and simply
// hangs the stack below the trigger instead.

import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';

/// An [M3EFabMenu] whose items open downwards.
///
/// Reuses the package's item model, decoration and color roles so
/// call sites read exactly like the upward original.
class M3EFabMenuDown extends StatefulWidget {
  const M3EFabMenuDown({
    super.key,
    required this.items,
    this.icon = const Icon(Icons.add_rounded),
    this.closeIcon = const Icon(Icons.close_rounded),
    this.expandIcon,
    this.collapseIcon,
    this.color = M3EFabColor.primary,
    this.size = M3EFabSize.medium,
    this.position = M3EFabMenuPosition.right,
    this.decoration,
    this.tooltip,
    this.onOpenChanged,
  }) : assert(items.length > 0, 'A FAB menu requires at least one item.');

  /// The list of items displayed when the menu is open.
  final List<M3EFabMenuItem> items;

  /// Icon shown when the menu is closed.
  final Widget icon;

  /// Icon shown when the menu is open.
  final Widget closeIcon;

  /// Optional custom expand icon (overrides [icon]).
  final Widget? expandIcon;

  /// Optional custom collapse icon (overrides [closeIcon]).
  final Widget? collapseIcon;

  /// Color role for the trigger FAB and the default item colors.
  final M3EFabColor color;

  /// Size of the trigger FAB.
  final M3EFabSize size;

  /// Alignment position of the FAB and menu items (left or right).
  final M3EFabMenuPosition position;

  /// Custom styling parameters for the menu and FAB.
  final M3EFabMenuDecoration? decoration;

  /// Optional tooltip for the trigger FAB.
  final String? tooltip;

  /// Callback triggered whenever the open/closed state toggles.
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<M3EFabMenuDown> createState() => _M3EFabMenuDownState();
}

class _M3EFabMenuDownState extends State<M3EFabMenuDown>
    with TickerProviderStateMixin {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();

  /// Mirrors the portal: `show()`/`hide()` while already shown/hidden
  /// trips framework asserts, and reopen-mid-collapse hits exactly that.
  bool _portalShown = false;

  late List<SingleMotionController> _itemCtrls;
  late List<bool> _itemVisible;
  final List<Timer> _staggerTimers = [];

  late final SingleMotionController _fabShapeCtrl;
  bool _open = false;

  /// True while the collapse animation runs; superseded by reopening.
  bool _closing = false;

  /// Invalidates in-flight close timers when a reopen supersedes them.
  int _closeGen = 0;

  /// Settle budget for one pill's collapse spring before the overlay drops.
  static const int _closeSettleMs = 300;

  M3EFabMenuDecoration get _dec =>
      widget.decoration ?? const M3EFabMenuDecoration();

  Widget get _resolvedExpandIcon => widget.expandIcon ?? widget.icon;
  Widget get _resolvedCollapseIcon => widget.collapseIcon ?? widget.closeIcon;
  bool get _isRight => widget.position == M3EFabMenuPosition.right;
  Alignment get _menuItemAlign =>
      _isRight ? Alignment.centerRight : Alignment.centerLeft;

  @override
  void initState() {
    super.initState();
    _itemCtrls = _createControllers(widget.items.length);
    _itemVisible = List<bool>.filled(widget.items.length, false);
    _fabShapeCtrl = SingleMotionController(
      motion: _dec.fabShapeMotion.toMotion(),
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(covariant M3EFabMenuDown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      _closeGen++;
      _closing = false;
      _disposeItemControllers();
      _itemCtrls = _createControllers(widget.items.length);
      _itemVisible = List<bool>.filled(widget.items.length, _open);
      if (_open) {
        for (final c in _itemCtrls) {
          c.value = 1.0;
        }
      }
    }
  }

  @override
  void dispose() {
    _cancelStagger();
    _disposeItemControllers();
    _fabShapeCtrl.dispose();
    super.dispose();
  }

  List<SingleMotionController> _createControllers(int count) {
    return List<SingleMotionController>.generate(
      count,
      (_) => SingleMotionController(
        motion: _dec.expandMotion.toMotion(),
        vsync: this,
      ),
    );
  }

  void _disposeItemControllers() {
    for (final c in _itemCtrls) {
      c.dispose();
    }
  }

  void _cancelStagger() {
    for (final t in _staggerTimers) {
      t.cancel();
    }
    _staggerTimers.clear();
  }

  void _toggle() {
    if (_open && !_closing) {
      _close();
    } else {
      // Closed, or mid-collapse (reopening supersedes the close).
      _openMenu();
    }
  }

  void _openMenu() {
    _cancelStagger();
    // Supersede any in-flight collapse so its delayed overlay-hide
    // cannot drop this freshly opened menu.
    _closeGen++;
    _closing = false;
    for (final c in _itemCtrls) {
      c.value = 0.0;
    }
    _itemVisible = List<bool>.filled(_itemCtrls.length, false);
    setState(() => _open = true);
    widget.onOpenChanged?.call(true);

    _fabShapeCtrl.motion = _dec.fabShapeMotion.toMotion();
    unawaited(_fabShapeCtrl.animateTo(1.0));
    _revealMenuItems();
  }

  void _revealMenuItems() {
    if (!_portalShown) {
      _portal.show();
      _portalShown = true;
    }
    final count = _itemCtrls.length;
    for (var i = 0; i < count; i++) {
      // Items nearest the trigger unfold first, so the stack
      // appears to grow downwards instead of teleporting in
      // from the far end one pill at a time.
      final delayMs = i * _dec.expandStaggerMs;
      _staggerTimers.add(
        Timer(Duration(milliseconds: delayMs), () {
          if (!mounted || !_open) return;
          setState(() => _itemVisible[i] = true);
          _itemCtrls[i]
            ..motion = _dec.expandMotion.toMotion()
            ..value = 0.0;
          unawaited(_itemCtrls[i].animateTo(1.0));
        }),
      );
    }
  }

  void _close() {
    if (!_open || _closing) return;
    _cancelStagger();
    _closing = true;
    final gen = ++_closeGen;
    widget.onOpenChanged?.call(false);

    // Collapse bottom-up (reverse of the reveal), then drop the
    // overlay once the springs settle.
    final count = _itemCtrls.length;
    for (var i = 0; i < count; i++) {
      final idx = count - 1 - i;
      _staggerTimers.add(
        Timer(Duration(milliseconds: i * _dec.expandStaggerMs), () {
          if (!mounted || gen != _closeGen) return;
          unawaited(_itemCtrls[idx].animateTo(0.0));
        }),
      );
    }
    _staggerTimers.add(
      Timer(
        Duration(
          milliseconds: (count - 1) * _dec.expandStaggerMs + _closeSettleMs,
        ),
        () {
          if (!mounted || gen != _closeGen) return;
          if (_portalShown) {
            _portal.hide();
            _portalShown = false;
          }
          for (final c in _itemCtrls) {
            c.value = 0.0;
          }
          _itemVisible = List<bool>.filled(count, false);
          _closing = false;
          setState(() => _open = false);
        },
      ),
    );

    _fabShapeCtrl.motion = _dec.fabShapeMotion.toMotion();
    unawaited(_fabShapeCtrl.animateTo(0.0));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dec = _dec;

    final fabMetrics = _getFabMetrics(widget.size);
    final double closedRadius = fabMetrics.radius;
    final double targetClosedSize = dec.closedFabSize ?? fabMetrics.container;
    final double targetOpenSize =
        dec.openFabSize ?? dec.closedFabSize ?? fabMetrics.container;
    final double openRadius = targetOpenSize / 2;

    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => _buildOverlay(context, cs, dec),
      child: CompositedTransformTarget(
        link: _link,
        child: AnimatedBuilder(
          animation: _fabShapeCtrl,
          builder: (context, child) {
            final t = _fabShapeCtrl.value.clamp(0.0, 1.0);
            final radius = lerpDouble(closedRadius, openRadius, t)!;
            final fabSize = lerpDouble(targetClosedSize, targetOpenSize, t)!;

            return SizedBox(
              width: targetClosedSize,
              height: targetClosedSize,
              child: Center(
                child: SizedBox(
                  width: fabSize,
                  height: fabSize,
                  child: M3EFab(
                    icon: _open ? _resolvedCollapseIcon : _resolvedExpandIcon,
                    color: widget.color,
                    size: widget.size,
                    cornerRadius: radius,
                    tooltip: widget.tooltip,
                    onPressed: _toggle,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildOverlay(
    BuildContext context,
    ColorScheme cs,
    M3EFabMenuDecoration dec,
  ) {
    final right = _isRight;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Tap anywhere outside to close. Translucent so the
        // underlying UI stays visible and interactive-looking.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        // Downwards: the follower hangs from the trigger's BOTTOM
        // edge with a positive offset (the package original anchors
        // to the top edge and opens upward).
        CompositedTransformFollower(
          link: _link,
          targetAnchor: right ? Alignment.bottomRight : Alignment.bottomLeft,
          followerAnchor: right ? Alignment.topRight : Alignment.topLeft,
          offset: Offset(0, dec.menuOffset),
          child: _buildMenu(context, cs, dec),
        ),
      ],
    );
  }

  Widget _buildMenu(
    BuildContext context,
    ColorScheme cs,
    M3EFabMenuDecoration dec,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: _isRight
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.items.length; i++)
          if (_itemVisible[i])
            Padding(
              padding: EdgeInsets.only(
                bottom: _isLastVisibleItem(i) ? 0 : dec.itemGap,
              ),
              child: _buildItem(context, cs, dec, widget.items[i], i),
            ),
      ],
    );
  }

  bool _isLastVisibleItem(int index) {
    for (var i = index + 1; i < _itemVisible.length; i++) {
      if (_itemVisible[i]) return false;
    }
    return true;
  }

  Widget _buildItem(
    BuildContext context,
    ColorScheme cs,
    M3EFabMenuDecoration dec,
    M3EFabMenuItem item,
    int index,
  ) {
    final ctrl = _itemCtrls[index];
    final itemBg =
        item.backgroundColor ??
        dec.itemBackgroundColor ??
        _getMenuDefaultBackground(widget.color, cs);
    final itemFg =
        item.foregroundColor ??
        dec.itemForegroundColor ??
        _getMenuDefaultForeground(widget.color, cs);

    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, child) {
        // Scale, not width: the pill springs up whole from the
        // trigger edge, so the label never clips through an
        // icon-only flash. The spring overshoot past 1.0 is the pop.
        final scale = ctrl.value.clamp(0.0, 1.25);
        return Align(
          alignment: _menuItemAlign,
          child: Transform.scale(
            scale: scale,
            alignment: _menuItemAlign,
            child: Material(
              color: itemBg,
              elevation: dec.itemElevation,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                splashFactory: InkSparkle.splashFactory,
                onTap: () {
                  item.onPressed?.call();
                  _close();
                },
                child: Container(
                  height: dec.itemHeight,
                  padding: EdgeInsets.symmetric(
                    horizontal: dec.itemHorizontalPadding,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconTheme.merge(
                        data: IconThemeData(color: itemFg, size: dec.iconSize),
                        child: item.icon,
                      ),
                      SizedBox(width: dec.iconLabelGap),
                      Text(
                        item.label,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: itemFg,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.15,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  _FabMetrics _getFabMetrics(M3EFabSize size) => switch (size) {
    M3EFabSize.small => const _FabMetrics(40, 12),
    M3EFabSize.medium => const _FabMetrics(56, 16),
    M3EFabSize.large => const _FabMetrics(96, 28),
  };

  Color _getMenuDefaultBackground(M3EFabColor color, ColorScheme scheme) =>
      switch (color) {
        M3EFabColor.primary => scheme.primaryContainer,
        M3EFabColor.secondary => scheme.secondaryContainer,
        M3EFabColor.tertiary => scheme.tertiaryContainer,
        M3EFabColor.surface => scheme.surfaceContainerHigh,
      };

  Color _getMenuDefaultForeground(M3EFabColor color, ColorScheme scheme) =>
      switch (color) {
        M3EFabColor.primary => scheme.onPrimaryContainer,
        M3EFabColor.secondary => scheme.onSecondaryContainer,
        M3EFabColor.tertiary => scheme.onTertiaryContainer,
        M3EFabColor.surface => scheme.onSurface,
      };
}

class _FabMetrics {
  const _FabMetrics(this.container, this.radius);

  final double container;
  final double radius;
}
