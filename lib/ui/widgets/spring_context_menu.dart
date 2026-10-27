// Spring-physics context menu: cursor-anchored pill stack for
// right-click menus, speaking the same motion language as
// [M3EFabMenuDown] (staggered spring scale-in, staggered collapse
// out, stadium pills). Replaces the stock `showMenu` popup wherever
// motion matters.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';

/// One row of a spring context menu.
class SpringMenuItem<T> {
  const SpringMenuItem({
    required this.icon,
    required this.label,
    required this.value,
    this.enabled = true,
  });

  final Widget icon;
  final String label;
  final T value;
  final bool enabled;
}

/// Dismisses the currently open spring menu, if any.
/// Set when a menu opens, replaced by the next one.
void Function()? _dismissActiveMenu;

/// Shows a spring context menu near [position] (usually the cursor),
/// clamped on-screen. Returns the tapped item's value, or null when
/// the menu is dismissed (click-away or escape).
///
/// Only one menu opens at a time: showing a new one drops any open
/// menu instantly (no collapse — the new menu springs in over it).
Future<T?> showSpringMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<SpringMenuItem<T>> items,
}) {
  assert(items.isNotEmpty, 'A context menu requires at least one item.');
  _dismissActiveMenu?.call();
  final size = MediaQuery.of(context).size;
  // Rough box estimate for clamping; the pills size themselves.
  const estimatedWidth = 280.0;
  const estimatedRow = 64.0;
  final left = position.dx.clamp(
    0.0,
    (size.width - estimatedWidth).clamp(0.0, size.width),
  );
  final top = position.dy.clamp(
    0.0,
    (size.height - items.length * estimatedRow).clamp(0.0, size.height),
  );
  final completer = Completer<T?>();
  final overlay = Overlay.of(context);
  final bodyKey = GlobalKey<_SpringMenuBodyState<T>>();
  late final OverlayEntry entry;
  var removed = false;

  void remove() {
    if (removed) return;
    removed = true;
    entry.remove();
  }

  // Registers this menu as the active one: a newer menu calling it
  // lands here after this menu already closed, in which case both
  // guards no-op and the current menu is untouched.
  void dismissInstant() {
    if (!completer.isCompleted) completer.complete(null);
    remove();
  }

  _dismissActiveMenu = dismissInstant;

  // Dismissal animates the pills out (like the header menu) and only
  // then drops the overlay; the selection completes up front so the
  // action runs while the menu collapses behind it.
  Future<void> dismiss([T? value]) async {
    if (!completer.isCompleted) completer.complete(value);
    await bodyKey.currentState?.close();
    remove();
  }

  entry = OverlayEntry(
    builder: (context) => Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          unawaited(dismiss());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => dismiss(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: _SpringMenuBody<T>(
              key: bodyKey,
              items: items,
              onSelect: (value) => dismiss(value),
            ),
          ),
        ],
      ),
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _SpringMenuBody<T> extends StatefulWidget {
  const _SpringMenuBody({
    super.key,
    required this.items,
    required this.onSelect,
  });

  final List<SpringMenuItem<T>> items;
  final ValueChanged<T> onSelect;

  @override
  State<_SpringMenuBody<T>> createState() => _SpringMenuBodyState<T>();
}

class _SpringMenuBodyState<T> extends State<_SpringMenuBody<T>>
    with TickerProviderStateMixin {
  late List<SingleMotionController> _ctrls;
  late List<bool> _visible;
  final List<Timer> _timers = [];
  Future<void>? _closeFuture;

  static const _staggerMs = 35;

  /// Settle budget for one pill's collapse spring.
  static const _closeSettleMs = 300;

  @override
  void initState() {
    super.initState();
    _ctrls = List<SingleMotionController>.generate(
      widget.items.length,
      (_) => SingleMotionController(
        motion: const M3EMotion.custom(
          stiffness: 380,
          damping: 0.55,
        ).toMotion(),
        vsync: this,
      ),
    );
    _visible = List<bool>.filled(widget.items.length, false);
    // Top-down unfold, like the header menu.
    for (var i = 0; i < _ctrls.length; i++) {
      _timers.add(
        Timer(Duration(milliseconds: i * _staggerMs), () {
          if (!mounted) return;
          setState(() => _visible[i] = true);
          unawaited(_ctrls[i].animateTo(1.0));
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  /// Collapses bottom-up (reverse of the reveal). Idempotent: concurrent
  /// dismissals share the one collapse.
  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closeFuture = _collapse();
    return _closeFuture!;
  }

  Future<void> _collapse() async {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    final count = _ctrls.length;
    for (var i = 0; i < count; i++) {
      final idx = count - 1 - i;
      _timers.add(
        Timer(Duration(milliseconds: i * _staggerMs), () {
          if (!mounted) return;
          unawaited(_ctrls[idx].animateTo(0.0));
        }),
      );
    }
    await Future<void>.delayed(
      Duration(milliseconds: (count - 1) * _staggerMs + _closeSettleMs),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.items.length; i++)
          if (_visible[i]) ...[
            if (i > 0) const SizedBox(height: 8),
            _row(context, cs, widget.items[i], _ctrls[i]),
          ],
      ],
    );
  }

  Widget _row(
    BuildContext context,
    ColorScheme cs,
    SpringMenuItem<T> item,
    SingleMotionController ctrl,
  ) {
    final content = Opacity(
      opacity: item.enabled ? 1.0 : 0.38,
      child: Material(
        color: cs.surfaceContainerHigh,
        elevation: 6.0,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          splashFactory: InkSparkle.splashFactory,
          onTap: item.enabled ? () => widget.onSelect(item.value) : null,
          child: Container(
            height: 48.0,
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconTheme.merge(
                  data: IconThemeData(color: cs.onSurface, size: 24.0),
                  child: item.icon,
                ),
                const SizedBox(width: 12),
                Text(
                  item.label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.15,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, child) {
        // Scale, not width: the pill springs up whole, so the label
        // never clips through an icon-only flash. The spring
        // overshoot past 1.0 is the pop.
        final scale = ctrl.value.clamp(0.0, 1.25);
        return Transform.scale(
          scale: scale,
          alignment: Alignment.centerLeft,
          child: child,
        );
      },
      child: content,
    );
  }
}
