// Accessibility motion helpers. The reduced-motion setting
// collapses animation durations to zero so motion-sensitive
// users get a static UI. Two flavours:
//
//   - [motionDuration] registers a dependency (call it inside
//     `build`) so the widget rebuilds when the setting flips;
//   - [readMotionDuration] only reads the current value (call
//     it from a callback, where registering is not possible).
//
// Both fall back to the full duration when no [AppState] is
// above the widget (standalone widget tests), matching the
// setting's off-by-default.

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';

/// Reads the reduced-motion flag, defaulting to false when no
/// [AppState] is in scope.
bool _reduced(BuildContext context, bool listen) {
  try {
    if (listen) {
      return context.select<AppState, bool>((s) => s.config.reducedMotion);
    }
    return Provider.of<AppState>(context, listen: false).config.reducedMotion;
  } on ProviderNotFoundException {
    return false;
  }
}

/// Zero when reduced motion is on, else [d]. Call within `build`
/// so the widget rebuilds when the accessibility setting flips.
Duration motionDuration(BuildContext context, Duration d) =>
    _reduced(context, true) ? Duration.zero : d;

/// Zero when reduced motion is on, else [d]. Reads without
/// registering a dependency — safe to call outside `build`.
Duration readMotionDuration(BuildContext context, Duration d) =>
    _reduced(context, false) ? Duration.zero : d;

/// True when the high-contrast theme is on. Registers a
/// dependency (call within `build`) so the widget rebuilds
/// when the setting flips; false when no [AppState] is in
/// scope (standalone widget tests).
bool highContrastOf(BuildContext context) {
  try {
    return context.select<AppState, bool>((s) => s.config.highContrast);
  } on ProviderNotFoundException {
    return false;
  }
}

/// Scrolls [controller] to [offset], honoring the reduced-motion
/// setting.
///
/// A zero-length scroll animation is not allowed by the framework, so
/// the reduced case jumps instead of animating — which is the very
/// motion the setting turns off.
void scrollToOffset(
  BuildContext context,
  ScrollController controller,
  double offset, {
  Duration duration = const Duration(milliseconds: 300),
  Curve curve = Curves.easeOut,
}) {
  if (readMotionDuration(context, duration) == Duration.zero) {
    controller.jumpTo(offset);
    return;
  }
  controller.animateTo(offset, duration: duration, curve: curve);
}
