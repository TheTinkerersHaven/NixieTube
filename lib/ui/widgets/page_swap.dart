// The app's screen-swap transition.
//
// Every level of NixieTube replaces one view with another inside the
// same widget slot — a tab, a pushed detail page, a settings category,
// an opened playlist — so they all animate through this one widget
// instead of each site inventing a cut or its own switcher.
//
// Forward moves rise from just below, back moves sink from just above,
// and both cross-fade. The outgoing view stays mounted for the length
// of the transition (it is part of the fade, not a hole behind the
// incoming one) but takes no taps and reads nothing out: it is on its
// way out.

import 'package:material_ui/material_ui.dart';

import '../a11y.dart';

/// How far a forward move starts below its resting place, as a
/// fraction of the view's height.
const _forwardRise = 0.05;

/// How far a back move starts above it. Back travels less than forward:
/// the user is returning, not arriving.
const _backSink = -0.04;

/// Swaps between two views with the app's motion language.
///
/// Give [child] a `ValueKey` that changes with the view, so a move that
/// keeps the same widget type (artist → album, category → category)
/// still animates. [fill] sizes each view to the whole slot; pass false
/// when the parent sizes to its child, as a page body may.
class PageSwap extends StatelessWidget {  const PageSwap({
    super.key,
    required this.child,
    required this.forward,
    this.fill = true,
  });

  /// The view to show now.
  final Widget child;

  /// True when navigating forward (into a page, onto a tab), false when
  /// coming back. Decides which way the incoming view travels.
  final bool forward;

  /// Whether both views fill the slot. False lets the slot size to its
  /// children as a plain stack would.
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final begin = Offset(0, forward ? _forwardRise : _backSink);
    return AnimatedSwitcher(
      duration: motionDuration(context, const Duration(milliseconds: 220)),
      reverseDuration: motionDuration(
        context,
        const Duration(milliseconds: 180),
      ),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: begin,
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: fill ? StackFit.expand : StackFit.loose,
        alignment: Alignment.topCenter,
        children: [
          for (final child in previousChildren)
            IgnorePointer(child: ExcludeSemantics(child: child)),
          ?currentChild,
        ],
      ),
      child: child,
    );
  }
}

/// The same motion for a real route: the incoming page rises over a fade
/// while the page it covers drifts up a little, so a push reads like
/// every other move in the app.
///
/// Android does not use this: it gets the platform's own predictive-back
/// transition from [PageTransitionsTheme], which the system drives with
/// the gesture. Everywhere else this is the desktop and iOS default.
class NixiePageTransitionsBuilder extends PageTransitionsBuilder {
  const NixiePageTransitionsBuilder();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reducedMotionOf(context)) return child;
    final enter = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final covered = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      // The page being covered gives a little, so the two read as stacked
      // rather than one sliding across a static background.
      position: Tween(
        begin: Offset.zero,
        end: const Offset(0, -0.02),
      ).animate(covered),
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, _forwardRise),
          end: Offset.zero,
        ).animate(enter),
        child: FadeTransition(opacity: animation, child: child),
      ),
    );
  }
}
