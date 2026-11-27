// Settings screen: account cards,
// listening-history toggle, accessibility options, and desktop
// integration toggles.
//
// Every section shares the same chrome: a [_SectionTitle] heading and
// an [_SettingsSegments] group built from M3ESegmentedList, so the whole
// screen reads as one uniform list without card surfaces or dividers.

import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/player/stream_proxy.dart';
import '../../sys/discord.dart';
import '../../sys/lastfm.dart';
import '../../sys/listenbrainz.dart';
import '../../sys/mpris.dart';
import '../../sys/platform_features.dart';
import '../../sys/sys_config.dart';
import '../../sys/updater.dart';
import '../../sys/version.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/page_swap.dart';
import '../widgets/screen_list.dart';
import '../widgets/browser_login_dialog.dart';
import '../widgets/lastfm_auth_actions.dart';

/// Whether the settings list has the MPRIS row at all: MPRIS is a Linux
/// session-bus interface, so on any other host the integrations section
/// is Discord only and says so in its heading.
/// Account, playback, accessibility and app settings.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// One entry of the settings index: what the category is called, what it
/// holds, and the icon its row shows.
enum _SettingsCategory {
  account(
    'Account',
    'Sign in to YouTube Music and manage your session.',
    Icons.person_rounded,
  ),
  playback(
    'Playback',
    'Listening history reporting and offline audio.',
    Icons.play_circle_rounded,
  ),
  appearance(
    'Appearance',
    'Color source, seed and manual overrides.',
    Icons.palette_rounded,
  ),
  accessibility(
    'Accessibility',
    'Contrast, motion and link styling.',
    Icons.accessibility_new_rounded,
  ),
  connections(
    'Connections',
    'Media keys, Discord presence and play scrobbling.',
    Icons.hub_rounded,
  ),
  updates(
    'App updates',
    'Check for and install new releases.',
    Icons.system_update_rounded,
  ),
  debug('Debug', 'Cache and diagnostic actions.', Icons.bug_report_rounded),
  setup('Setup', 'Run the first-run wizard again.', Icons.rocket_launch_rounded);

  const _SettingsCategory(this.title, this.subtitle, this.icon);

  /// The category name, used both by its index row and its page title.
  final String title;

  /// One line saying what the category holds, under the row's title.
  final String subtitle;

  final IconData icon;
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// The category the user opened, or null while the index is showing.
  _SettingsCategory? _open;

  /// Direction of the last index ↔ category move, so the page transition
  /// rises into a category and sinks back to the index.
  bool _forward = true;

  void _openCategory(_SettingsCategory category) => setState(() {
    _forward = true;
    _open = category;
  });

  void _closeCategory() => setState(() {
    _forward = false;
    _open = null;
  });

  @override
  Widget build(BuildContext context) {
    // The update banner opens Settings with App updates in mind: jump
    // straight into that category instead of making the user find it.
    final state = context.read<AppState>();
    if (state.focusAppUpdates && _open == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        state.clearAppUpdatesFocus();
        setState(() => _open = _SettingsCategory.updates);
      });
    }
    final open = _open;
    // A phone's back press asks the app to go back: while a category is
    // open that means returning to the index, not leaving Settings.
    // Vetoing the pop also keeps the system from previewing a pop this
    // page would then refuse.
    return PopScope(
      canPop: open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeCategory();
      },
      // The index and a category are two pages of one slot: swap them
      // with the app's page motion instead of cutting between them.
      child: PageSwap(
        forward: _forward,
        child: KeyedSubtree(
          key: ValueKey(open),
          child: open == null
              ? _index(context, state)
              : _category(context, state, open),
        ),
      ),
    );
  }

  /// The first screen: one row per category, each opening its own page.
  Widget _index(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    return _page(
      context,
      title: 'Settings',
      // Settings is pushed from the rail, so the desktop header keeps the
      // app's own back affordance on a phone.
      onBack: state.canGoBack ? state.goBack : null,
      children: [
        _SettingsSegments(
          // The list owns the tap, so the whole segment is the target —
          // padding included — and the press animation covers it.
          onTap: (i) => _openCategory(_SettingsCategory.values[i]),
          children: [
            for (final category in _SettingsCategory.values)
              _CategoryRow(category: category),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          '${_shortVersion(appVersionLabel)} - build '
          '${_buildNumber(appVersionLabel)}',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        Text(
          'Made with ♥  by TheTinkerersHaven :3',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// A category's own page: its controls, nothing else.
  Widget _category(
    BuildContext context,
    AppState state,
    _SettingsCategory category,
  ) => _page(
    context,
    title: category.title,
    subtitle: category.subtitle,
    onBack: _closeCategory,
    children: _controls(context, state, category),
  );

  /// The page shell shared by the index and every category: a large title
  /// (with the app's back button on a phone) above the scrolling body.
  Widget _page(
    BuildContext context, {
    required String title,
    String? subtitle,
    VoidCallback? onBack,
    required List<Widget> children,
  }) {
    final compact = isCompactLayout(context);
    final scheme = Theme.of(context).colorScheme;
    final heading = <Widget>[
      Text(title, style: Theme.of(context).textTheme.headlineMedium),
      if (subtitle case final String text) ...[
        const SizedBox(height: 2),
        Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    ];
    if (!compact) {
      return screenColumn(
        context: context,
        children: [...heading, const SizedBox(height: 16), ...children],
      );
    }
    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              screenPadding,
              8,
              screenPadding,
              8,
            ),
            child: Row(
              children: [
                if (onBack != null)
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: 'Back',
                    onPressed: onBack,
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: heading,
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: screenColumn(
            context: context,
            topInset: false,
            topPadding: 8,
            children: children,
          ),
        ),
      ],
    );
  }

  /// The controls a category holds, each group on its own surface.
  List<Widget> _controls(
    BuildContext context,
    AppState state,
    _SettingsCategory category,
  ) {
    switch (category) {
      case _SettingsCategory.account:
        return [_SettingsCard(child: const _AccountCard())];
      case _SettingsCategory.playback:
        // Selected here rather than in build: only this page rebuilds
        // when the toggle flips.
        final reportPlayback = context.select<AppState, bool>(
          (s) => s.config.reportPlayback,
        );
        final audioCache = context.select<AppState, bool>(
          (s) => s.config.audioCacheEnabled,
        );
        final cacheMb = context.select<AppState, int>(
          (s) => s.config.audioCacheMb,
        );
        final downloadAhead = context.select<AppState, int>(
          (s) => s.config.audioDownloadAhead,
        );
        return [
          _SettingsSegments(
            children: [
              _ToggleRow(
                title: 'Report listening history',
                subtitle:
                    'Send watchtime beacons so plays appear in your '
                    'YouTube history.',
                value: reportPlayback,
                onChanged: (v) {
                  state.config.setBool('reportPlayback', v);
                  state.refreshConfig();
                },
              ),
              _ToggleRow(
                title: 'Keep audio on disk',
                subtitle:
                    'Stores played tracks and the next few in the queue, '
                    'so a weak connection does not stop the music.',
                value: audioCache,
                action: audioCache
                    ? M3ETextButton(
                        onPressed: () {
                          unawaited(StreamProxy.instance.cache?.clear());
                        },
                        child: const Text('Clear'),
                      )
                    : null,
                onChanged: (v) {
                  state.config.setBool('audio.cache', v);
                  state.refreshConfig();
                },
              ),
              // Both only make sense while the cache is on, and each
              // shows its current value on its own row: the toggle's
              // subtitle names the feature, not a number.
              if (audioCache) ...[
                _SteppedSliderRow(
                  title: 'Cache size',
                  subtitle:
                      'What the stored tracks may use on disk. The oldest '
                      'are deleted first.',
                  values: audioCacheMbSteps,
                  value: cacheMb,
                  format: _formatCacheSize,
                  onChanged: (v) {
                    state.config.audioCacheMb = v;
                    state.refreshConfig();
                  },
                ),
                _SteppedSliderRow(
                  title: 'Songs downloaded ahead',
                  subtitle:
                      'Rows after the playing one kept complete on disk, '
                      'so a skip works with no connection.',
                  values: [
                    for (var i = 1; i <= maxAudioDownloadAhead; i++) i,
                  ],
                  value: downloadAhead,
                  format: (v) => v == 1 ? '1 song' : '$v songs',
                  onChanged: (v) {
                    state.config.audioDownloadAhead = v;
                    state.refreshConfig();
                  },
                ),
              ],
            ],
          ),
        ];
      case _SettingsCategory.appearance:
        return [_SettingsSegments(children: const [_ThemeCard()])];
      case _SettingsCategory.accessibility:
        final highContrast = context.select<AppState, bool>(
          (s) => s.config.highContrast,
        );
        final reducedMotion = context.select<AppState, bool>(
          (s) => s.config.reducedMotion,
        );
        final underlineLinks = context.select<AppState, bool>(
          (s) => s.config.underlineLinks,
        );
        return [
          _SettingsSegments(
            children: [
              _ToggleRow(
                title: 'High contrast',
                subtitle:
                    'Brighter text, stronger borders and more '
                    'distinct surfaces.',
                value: highContrast,
                onChanged: (v) {
                  state.config.highContrast = v;
                  state.refreshConfig();
                },
              ),
              _ToggleRow(
                title: 'Reduce motion',
                subtitle:
                    'Freezes the shimmer, crossfades and slide '
                    'transitions.',
                value: reducedMotion,
                onChanged: (v) {
                  state.config.reducedMotion = v;
                  state.refreshConfig();
                },
              ),
              _ToggleRow(
                title: 'Underline links',
                subtitle:
                    'Underlines tappable links in the info tab. '
                    'Off keeps them plain primary-colored text.',
                value: underlineLinks,
                onChanged: (v) {
                  state.config.underlineLinks = v;
                  state.refreshConfig();
                },
              ),
            ],
          ),
        ];
      case _SettingsCategory.connections:
        return [const _ConnectionsSegments()];
      case _SettingsCategory.updates:
        return [
          _SettingsSegments(children: const [_AppUpdatesCard()]),
        ];
      case _SettingsCategory.debug:
        return [
          _SettingsSegments(
            children: [
              _DebugCard(
                onClearArtwork: () {
                  state.clearArtworkCache();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Artwork cache cleared.')),
                  );
                },
              ),
            ],
          ),
        ];
      case _SettingsCategory.setup:
        return [
          _SettingsSegments(children: const [_OnboardingCard()]),
        ];
    }
  }
}

/// An index row: the category's icon, its name and what it holds. The
/// segment itself is the tap target and says it opens a page through the
/// list's own press animation, so no chevron is drawn.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.category});

  final _SettingsCategory category;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(category.icon, color: scheme.primary),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                category.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 2),
              Text(
                category.subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The expressive outer radius shared by every settings surface, so
/// standalone cards and segmented groups read as one family. Matches the
/// M3 Expressive segmented-list default.
const double _settingsSurfaceRadius = 24.0;

/// Inner padding of a settings surface: 16dp horizontal so row content
/// aligns inside segments and cards alike, 12dp vertical.
const EdgeInsets _settingsSurfacePadding = EdgeInsets.fromLTRB(16, 12, 16, 12);

/// A standalone settings card surface matching the M3 segmented group
/// styling (expressive radius, surfaceContainer background) without
/// the list focus-traversal wrappers that disrupt embedded text fields.
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(_settingsSurfaceRadius),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: _settingsSurfacePadding, child: child),
    );
  }
}

/// A settings group drawn as one M3 Expressive segmented list: each child
/// is a segment, so related controls share a surface without divider
/// lines. Uses the M3E default outer radius and even inner padding so the
/// segments and their content align on every width.
class _SettingsSegments extends StatelessWidget {
  const _SettingsSegments({required this.children, this.onTap});

  final List<Widget> children;

  /// Makes each segment tappable as one surface: the list handles the
  /// gesture, so the hit area is the segment's full bounds — including
  /// the padding a widget-level [InkWell] would leave dead — and the
  /// press animation and haptic come with it.
  final void Function(int index)? onTap;

  @override
  Widget build(BuildContext context) => M3ESegmentedList(
    itemCount: children.length,
    itemBuilder: (context, i) => children[i],
    outerRadius: _settingsSurfaceRadius,
    padding: _settingsSurfacePadding,
    onTap: onTap,
  );
}

/// A uniform settings toggle row: a title, an optional
/// description, a trailing switch, and an optional cog button that
/// opens a modal with the row's advanced fields (custom keys live
/// there so the card stays uncluttered). Every toggle in the
/// settings screen uses this so they read identically.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.subtitleColor,
    this.enabled = true,
    this.onSettings,
    this.action,
  });

  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  /// Opens the advanced-fields modal, or null when the row has none.
  final VoidCallback? onSettings;

  /// An inline action (e.g. Sign out) placed before the cog.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle case final String s) ...[
                const SizedBox(height: 2),
                Text(
                  s,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: subtitleColor ?? scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        ?action,
        if (onSettings != null)
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Advanced settings',
            onPressed: onSettings,
          ),
        Switch(value: value, onChanged: enabled ? onChanged : null),
      ],
    );
  }
}

/// Human size for the cache slider: whole gigabytes once it gets there,
/// megabytes below.
String _formatCacheSize(int mb) => mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB';

/// A settings row that picks from a fixed list of steps: title and the
/// current value share a line, an explanation sits under it, then an
/// M3E slider that snaps to the steps and shows the value in its pill
/// while dragging. The choice is written once the gesture ends, so a
/// drag does not rewrite the settings file at every step.
class _SteppedSliderRow extends StatefulWidget {
  const _SteppedSliderRow({
    required this.title,
    required this.subtitle,
    required this.values,
    required this.value,
    required this.format,
    required this.onChanged,
  });

  final String title;
  final String subtitle;

  /// The steps, ascending; the slider has one position per entry.
  final List<int> values;
  final int value;
  final String Function(int value) format;
  final ValueChanged<int> onChanged;

  @override
  State<_SteppedSliderRow> createState() => _SteppedSliderRowState();
}

class _SteppedSliderRowState extends State<_SteppedSliderRow> {
  late int _index = _nearestIndex(widget.values, widget.value);

  /// The nearest step, matching how the config reads a stray value.
  static int _nearestIndex(List<int> values, int value) {
    var best = 0;
    for (var i = 1; i < values.length; i++) {
      if ((values[i] - value).abs() < (values[best] - value).abs()) best = i;
    }
    return best;
  }

  @override
  void didUpdateWidget(_SteppedSliderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      _index = _nearestIndex(widget.values, widget.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = widget.format(widget.values[_index]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(widget.title, style: theme.textTheme.titleMedium),
            ),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          widget.subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        M3ESlider(
          value: _index.toDouble(),
          min: 0,
          max: (widget.values.length - 1).toDouble(),
          divisions: widget.values.length - 1,
          label: label,
          onChanged: (v) {
            final next = v.round().clamp(0, widget.values.length - 1);
            if (next == _index) return;
            setState(() => _index = next);
          },
          onChangeEnd: (_) => widget.onChanged(widget.values[_index]),
        ),
      ],
    );
  }
}

/// Modal shell for a row's advanced fields: title on top, fields
/// below, and a single Close action. Content scrolls if the window
/// is short.
class _SettingsModal extends StatelessWidget {
  const _SettingsModal({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
      actions: [
        M3ETextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// What the "System" color source actually follows on this host: the
/// XDG portal / GTK theme on Linux desktop, wallpaper colors on
/// Android, and nothing on iOS (the built-in theme is used).
String _systemSourceNote() => switch (currentPlatform()) {
  AppPlatform.android =>
    'Follows your wallpaper accent color when the system reports one; '
        'otherwise the built-in theme.',
  AppPlatform.ios =>
    'iOS reports no system accent color, so the built-in theme is used.',
  _ =>
    'Follows your desktop accent color when the system reports one '
        '(XDG portal / GTK theme); otherwise the built-in theme.',
};

/// Theme card: color source (system accent vs custom seed),
/// seed swatches, and manual per-role overrides applied on top
/// of either source. Every control persists to config and
/// notifies, so the MaterialApp theme rebuilds in place.
class _ThemeCard extends StatelessWidget {
  const _ThemeCard();

  @override
  Widget build(BuildContext context) {
    final source = context.select<AppState, ThemeSource>(
      (s) => ThemeSource.fromKey(s.config.themeSource),
    );
    final seed = context.select<AppState, int>((s) => s.config.themeSeedColor);
    final primary = context.select<AppState, int?>(
      (s) => s.config.themePrimaryOverride,
    );
    final secondary = context.select<AppState, int?>(
      (s) => s.config.themeSecondaryOverride,
    );
    final tertiary = context.select<AppState, int?>(
      (s) => s.config.themeTertiaryOverride,
    );
    final surface = context.select<AppState, int?>(
      (s) => s.config.themeSurfaceOverride,
    );
    final scheme = Theme.of(context).colorScheme;
    final state = context.read<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Color source', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        M3EToggleButtonGroup(
          type: M3EButtonGroupType.connected,
          size: M3EButtonSize.sm,
          semanticLabel: 'Theme color source',
          selectedIndex: source == ThemeSource.system ? 0 : 1,
          onSelectedIndexChanged: (i) {
            // Selection-required: tapping the active source keeps it.
            if (i == null) return;
            state.config.themeSource = i == 0
                ? ThemeSource.system.name
                : ThemeSource.custom.name;
            state.refreshConfig();
          },
          actions: const [
            M3EToggleButtonGroupAction(label: Text('System')),
            M3EToggleButtonGroupAction(label: Text('Custom')),
          ],
          decoration: toggleButtonGroupDecoration(scheme),
        ),
        const SizedBox(height: 6),
        Text(
          source == ThemeSource.system
              ? _systemSourceNote()
              : 'Built from the seed color below.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (source == ThemeSource.custom) ...[
          const SizedBox(height: 12),
          Text('Seed color', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _SwatchRow(
            keyPrefix: 'theme-seed',
            selected: seed,
            onPick: (c) {
              if (c == null) return;
              state.config.themeSeedColor = c;
              state.refreshConfig();
            },
          ),
        ],
        const SizedBox(height: 12),
        const Divider(),
        const SizedBox(height: 12),
        Text(
          'Manual overrides',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 2),
        Text(
          'Applied on top of either source, exactly as picked. '
          'Auto follows the scheme.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        _OverrideRow(
          title: 'Primary',
          value: primary,
          keyPrefix: 'theme-primary',
          onPick: (c) {
            state.config.themePrimaryOverride = c;
            state.refreshConfig();
          },
        ),
        const SizedBox(height: 8),
        _OverrideRow(
          title: 'Secondary',
          value: secondary,
          keyPrefix: 'theme-secondary',
          onPick: (c) {
            state.config.themeSecondaryOverride = c;
            state.refreshConfig();
          },
        ),
        const SizedBox(height: 8),
        _OverrideRow(
          title: 'Tertiary',
          value: tertiary,
          keyPrefix: 'theme-tertiary',
          onPick: (c) {
            state.config.themeTertiaryOverride = c;
            state.refreshConfig();
          },
        ),
        const SizedBox(height: 8),
        _OverrideRow(
          title: 'Surface',
          value: surface,
          keyPrefix: 'theme-surface',
          onPick: (c) {
            state.config.themeSurfaceOverride = c;
            state.refreshConfig();
          },
        ),
      ],
    );
  }
}

/// One manual-override row: a role label plus an Auto chip and
/// the shared preset swatches.
class _OverrideRow extends StatelessWidget {
  const _OverrideRow({
    required this.title,
    required this.value,
    required this.onPick,
    required this.keyPrefix,
  });

  final String title;
  final int? value;
  final ValueChanged<int?> onPick;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _SwatchRow(
          selected: value,
          showAuto: true,
          onPick: onPick,
          keyPrefix: keyPrefix,
        ),
      ],
    );
  }
}

/// Preset swatch strip (plus an Auto chip for overrides).
/// Tapping a dot persists the color immediately; the theme
/// rebuilds through the config notifier.
class _SwatchRow extends StatelessWidget {
  const _SwatchRow({
    required this.selected,
    required this.onPick,
    required this.keyPrefix,
    this.showAuto = false,
  });

  /// Currently picked ARGB value, or null for Auto.
  final int? selected;
  final ValueChanged<int?> onPick;
  final String keyPrefix;
  final bool showAuto;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (showAuto)
          ChoiceChip(
            key: ValueKey('$keyPrefix-auto'),
            label: const Text('Auto'),
            selected: selected == null,
            onSelected: (_) => onPick(null),
          ),
        for (final c in themeColorPresets)
          _SwatchDot(
            key: ValueKey('$keyPrefix-${c.toRadixString(16)}'),
            value: c,
            selected: selected == c,
            onTap: () => onPick(c),
          ),
      ],
    );
  }
}

/// Single 32dp preset dot with a selection ring.
class _SwatchDot extends StatelessWidget {
  const _SwatchDot({
    super.key,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  /// Preset color as 32-bit ARGB.
  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '#${value.toRadixString(16).padLeft(8, '0')}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Color(value),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// Debug-only actions (artwork cache invalidation).
class _DebugCard extends StatelessWidget {
  const _DebugCard({required this.onClearArtwork});

  final VoidCallback onClearArtwork;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Artwork cache', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Delete every cached cover (raw downloads + rendered tiles + '
          'square-cover map), reset failed-download skips, and drop decoded '
          'images from memory, so all artwork re-fetches and re-renders '
          'from scratch on the next display.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: M3EOutlinedButton.icon(
            onPressed: onClearArtwork,
            icon: const Icon(Icons.cleaning_services_rounded),
            label: const Text('Clear artwork cache'),
          ),
        ),
      ],
    );
  }
}

/// MPRIS media-keys and Discord Rich Presence toggles, each its own
/// segment in the integrations group.
///
/// Rows the host cannot support are dropped rather than shown dead:
/// MPRIS exists only on a Linux session bus. Discord is the exception —
/// its row stays on a phone, disabled, because the presence is a feature
/// users look for and "not available here" answers it better than a
/// missing setting.
/// Everything that leaves the app, on one list: the presence it
/// publishes (media keys on a desktop, Discord elsewhere) and the
/// services it scrobbles plays to.
///
/// Phones have no desktop to integrate with, but the Discord row is
/// still worth showing (unavailable and saying why) rather than hiding
/// a capability the user may have read about.
class _ConnectionsSegments extends StatelessWidget {
  const _ConnectionsSegments();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final mpris = context.watch<MprisService>();
    final discord = context.watch<DiscordPresenceBase>();
    final scheme = Theme.of(context).colorScheme;
    // MPRIS is a Linux session-bus interface: on any other host the
    // service reports itself unsupported and the row is dropped rather
    // than shown dead.
    final showMpris = mpris.supported;
    return _SettingsSegments(
      children: [
        if (showMpris)
          _ToggleRow(
            title: 'MPRIS (media keys, playerctl)',
            subtitle:
                mpris.lastError ??
                (mpris.active ? 'Active on the session bus' : 'Inactive'),
            subtitleColor: mpris.lastError != null ? scheme.error : null,
            value: state.config.mprisEnabled,
            onChanged: (v) {
              state.config.setBool('mpris.enabled', v);
              mpris.setEnabled(v);
              if (v && !mpris.active) {
                unawaited(mpris.start());
              }
              state.refreshConfig();
            },
          ),
        _ToggleRow(
          title: 'Discord Rich Presence',
          subtitle: discord.supported
              ? 'Status: ${discord.status}'
              : discord.status,
          value: state.config.discordEnabled && discord.supported,
          enabled: discord.supported,
          onChanged: (v) {
            state.config.setBool('discord.enabled', v);
            discord.setEnabled(v);
            state.refreshConfig();
          },
          onSettings: !discord.supported
              ? null
              : () => showDialog(
                  context: context,
                  builder: (context) => const _DiscordAppIdDialog(),
                ),
        ),
        const _LastFmCard(),
        const _ListenBrainzCard(),
      ],
    );
  }
}

/// Custom Discord application ID, kept behind the integration row's
/// cog. Empty means the built-in ID.
class _DiscordAppIdDialog extends StatefulWidget {
  const _DiscordAppIdDialog();

  @override
  State<_DiscordAppIdDialog> createState() => _DiscordAppIdDialogState();
}

class _DiscordAppIdDialogState extends State<_DiscordAppIdDialog> {
  late final TextEditingController _appId;

  @override
  void initState() {
    super.initState();
    _appId = TextEditingController(
      text: context.read<AppState>().config.discordAppId,
    );
  }

  @override
  void dispose() {
    _appId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final discord = context.read<DiscordPresenceBase>();
    return Dialog(
      child: SizedBox(
        width: 560,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Discord Rich Presence',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'The line Discord shows for the activity.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              _DiscordStatusLinePicker(config: state.config),
              const SizedBox(height: 16),
              Text(
                'Presence is withdrawn after a track stays paused for:',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              _DiscordPauseHidePicker(config: state.config),
              const SizedBox(height: 16),
              TextField(
                controller: _appId,
                decoration: const InputDecoration(
                  labelText: 'Discord application ID',
                  helperText: 'Optional, leave empty for the built-in ID',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  state.config.set('discord.appId', v);
                  discord.setAppId(v);
                },
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: M3ETextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Status-line choice: app name, song title, song artist or song album.
///
/// Watches the presence rather than reading it once: the dialog itself
/// only `read`s it, so a read-only pick would keep painting the old
/// selection until the dialog was reopened.
class _DiscordStatusLinePicker extends StatelessWidget {
  const _DiscordStatusLinePicker({required this.config});

  final SysConfig config;

  @override
  Widget build(BuildContext context) {
    final discord = context.watch<DiscordPresenceBase>();
    final scheme = Theme.of(context).colorScheme;
    final modes = DiscordStatusText.values;
    return M3EToggleButtonGroup(
      type: M3EButtonGroupType.connected,
      size: M3EButtonSize.sm,
      semanticLabel: 'Discord status line',
      selectedIndex: modes.indexOf(discord.statusText),
      onSelectedIndexChanged: (i) {
        if (i == null) return;
        final mode = modes[i];
        config.set('discord.statusText', discordStatusTextKey(mode));
        discord.setStatusText(mode);
      },
      actions: [
        for (final mode in modes)
          M3EToggleButtonGroupAction(label: Text(discordStatusTextLabel(mode))),
      ],
      decoration: toggleButtonGroupDecoration(scheme),
    );
  }
}

/// The account card: who is signed in, and how to sign in (or out).
class _AccountCard extends StatefulWidget {
  const _AccountCard();

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  final TextEditingController _cookie = TextEditingController();

  @override
  void dispose() {
    _cookie.dispose();
    super.dispose();
  }

  /// Runs the embedded login window, then signs in with the fresh
  /// session it returns (if any).
  Future<void> _loginWithBrowserWindow() async {
    final state = context.read<AppState>();
    final cookie = await showBrowserLoginDialog(context);
    if (cookie == null || cookie.isEmpty || !context.mounted) return;
    try {
      await state.login(cookie);
    } catch (_) {
      // login() reports known failures via loginDetail; never let a
      // transport error escape the button handler.
    }
  }

  /// Opens YouTube Music in the real system browser as a fallback
  /// when the embedded window misbehaves; import afterwards below.
  Future<void> _openSystemBrowser() async {
    await context.read<AppState>().openUrl('https://music.youtube.com');
  }

  @override
  Widget build(BuildContext context) {
    final hasCookieSession = context.select<AppState, bool>(
      (s) => s.hasCookieSession,
    );
    final loginValid = context.select<AppState, bool>((s) => s.loginValid);
    final loginBusy = context.select<AppState, bool>((s) => s.loginBusy);
    final loginDetail = context.select<AppState, String?>((s) => s.loginDetail);
    final account = context.select<AppState, String?>((s) => s.account);
    final scheme = Theme.of(context).colorScheme;
    final state = context.read<AppState>();
    final connected = hasCookieSession && loginValid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                account ?? 'YouTube Music account',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            _AuthStatus(
              connected: connected,
              label: !hasCookieSession
                  ? 'Not connected'
                  : loginValid
                  ? 'Connected'
                  : 'Expired',
              expired: hasCookieSession && !loginValid,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          connected
              ? 'Signed in. Unlocks playback, listening '
                    'history (watchtime) and the InnerTube '
                    'library.'
              : hasCookieSession
              ? 'This cookie has expired — YouTube treats '
                    'the session as signed out, so listening '
                    'history stops recording. Log in again below '
                    'for a fresh session.'
              : 'Required for playback, listening history '
                    '(watchtime) and the InnerTube library. '
                    'InnerTube needs a cookie + SAPISIDHASH — '
                    'an OAuth token will not work for these.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (connected) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: M3ETextButton(
              onPressed: state.logoutCookie,
              child: const Text('Sign out'),
            ),
          ),
        ],
        if (!connected) ...[
          const SizedBox(height: 12),
          // The built-in login window is a desktop WebKit view; phones
          // sign in by importing a cookie from a browser.
          if (supportsEmbeddedLogin(currentPlatform())) ...[
            Text(
              'Method 1 — Built-in browser',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Opens the sign-in page right here — sign in with Google '
              'and the session is picked up when you confirm.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            M3EFilledButton.icon(
              onPressed: loginBusy ? null : _loginWithBrowserWindow,
              icon: const Icon(Icons.login_rounded),
              label: Text(loginBusy ? 'Verifying…' : 'Log in with browser'),
            ),
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 4),
            Text(
              'Method 2 — Manual import',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
          ] else ...[
            Text(
              'Sign in from a browser',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Sign in at music.youtube.com in a browser, then import its '
              'cookie below.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          M3EButton.icon(
            style: M3EButtonStyle.outlined,
            onPressed: loginBusy ? null : _openSystemBrowser,
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Open YouTube Music in your browser'),
          ),
          const SizedBox(height: 8),
          Text(
            supportsEmbeddedLogin(currentPlatform())
                ? '1. In your browser, open music.youtube.com while logged in.\n'
                      '2. Open DevTools (F12) → Network tab, then play any song.\n'
                      '3. Click any youtubei/v1/ request → Headers → view '
                      'source → copy the whole Cookie value.'
                : '1. On a computer, open music.youtube.com in a browser '
                      'and sign in.\n'
                      '2. Open DevTools (F12) → Network, then play any song.\n'
                      '3. Copy the whole Cookie header from a youtubei/v1 '
                      'request and paste it below.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _cookie,
            decoration: const InputDecoration(
              labelText: 'Cookie header value',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
            minLines: 1,
          ),
          if (loginDetail != null) ...[
            const SizedBox(height: 8),
            Text(
              loginDetail,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          M3EFilledButton(
            onPressed: loginBusy ? null : () => state.login(_cookie.text),
            child: Text(loginBusy ? 'Verifying…' : 'Sign in'),
          ),
        ],
      ],
    );
  }
}

/// Runs the first-run setup again.
class _OnboardingCard extends StatelessWidget {
  const _OnboardingCard();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      // Stretch so the trailing-aligned action button reaches the card's
      // right edge instead of hugging the widest text.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('First-run setup', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          'Walks through the welcome, the sign-in and the appearance '
          'choices once more.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: M3EButton.icon(
            style: M3EButtonStyle.outlined,
            onPressed: () => state.restartOnboarding(),
            icon: const Icon(Icons.replay_rounded),
            label: const Text('Run the setup again'),
          ),
        ),
      ],
    );
  }
}

/// Small coloured status badge for a sign-in method.
class _AuthStatus extends StatelessWidget {
  const _AuthStatus({
    required this.connected,
    required this.label,
    this.expired = false,
  });

  final bool connected;
  final String label;
  final bool expired;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = connected
        ? scheme.primary
        : expired
        ? scheme.error
        : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// Last.fm scrobbling card: enable toggle,
/// API key/secret fields, browser-approval login, and sign-out.
class _LastFmCard extends StatefulWidget {
  const _LastFmCard();

  @override
  State<_LastFmCard> createState() => _LastFmCardState();
}

class _LastFmCardState extends State<_LastFmCard> {
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _enabled = context.read<AppState>().config.lastfmEnabled;
  }

  /// Persists the toggle.
  void _save({bool? enabled}) {
    final config = context.read<AppState>().config;
    if (enabled != null) {
      _enabled = enabled;
      config.lastfmEnabled = enabled;
    }
    context.read<LastFmService>().refreshStatus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final lastfm = context.watch<LastFmService>();
    final scheme = Theme.of(context).colorScheme;
    final status = lastfm.status;
    final signedIn = status.startsWith('signed in as');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ToggleRow(
          title: 'Scrobble to Last.fm',
          subtitle: 'Status: $status',
          subtitleColor: status.startsWith('error') ? scheme.error : null,
          value: _enabled,
          onChanged: (v) => _save(enabled: v),
          onSettings: () => showDialog(
            context: context,
            builder: (context) => const _LastFmKeysDialog(),
          ),
          action: signedIn
              ? M3ETextButton(
                  onPressed: () {
                    lastfm.logout();
                    setState(() {});
                  },
                  child: const Text('Sign out'),
                )
              : null,
        ),
        if (!signedIn) ...[
          const SizedBox(height: 12),
          const LastFmAuthActions(),
        ],
      ],
    );
  }
}

/// Custom Last.fm API key/secret, kept behind the card's cog. Empty
/// means the built-in shared credentials; saving different values
/// signs out the previous application's session.
class _LastFmKeysDialog extends StatefulWidget {
  const _LastFmKeysDialog();

  @override
  State<_LastFmKeysDialog> createState() => _LastFmKeysDialogState();
}

class _LastFmKeysDialogState extends State<_LastFmKeysDialog> {
  late final TextEditingController _apiKey;
  late final TextEditingController _secret;

  @override
  void initState() {
    super.initState();
    final config = context.read<AppState>().config;
    _apiKey = TextEditingController(text: config.lastfmApiKey);
    _secret = TextEditingController(text: config.lastfmSecret);
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _secret.dispose();
    super.dispose();
  }

  void _save({String? apiKey, String? secret}) {
    final config = context.read<AppState>().config;
    final lastfm = context.read<LastFmService>();
    final nextKey = apiKey ?? _apiKey.text;
    final nextSecret = secret ?? _secret.text;
    if (nextKey.trim() != config.lastfmApiKey ||
        nextSecret.trim() != config.lastfmSecret) {
      lastfm.logout();
    }
    config.lastfmApiKey = nextKey.trim();
    config.lastfmSecret = nextSecret.trim();
    lastfm.refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsModal(
      title: 'Last.fm API credentials',
      children: [
        TextField(
          controller: _apiKey,
          decoration: const InputDecoration(
            labelText: 'Last.fm API key',
            helperText: 'Empty means the built-in shared key',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => _save(apiKey: v),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _secret,
          decoration: const InputDecoration(
            labelText: 'Last.fm shared secret',
            helperText: 'Empty means the built-in shared secret',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
          onChanged: (v) => _save(secret: v),
        ),
      ],
    );
  }
}

/// ListenBrainz scrobbling card: enable toggle, token status, and a
/// dialog for the user token from listenbrainz.org/settings.
class _ListenBrainzCard extends StatefulWidget {
  const _ListenBrainzCard();

  @override
  State<_ListenBrainzCard> createState() => _ListenBrainzCardState();
}

class _ListenBrainzCardState extends State<_ListenBrainzCard> {
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _enabled = context.read<AppState>().config.listenbrainzEnabled;
  }

  /// Persists the toggle.
  void _save({bool? enabled}) {
    final config = context.read<AppState>().config;
    if (enabled != null) {
      _enabled = enabled;
      config.listenbrainzEnabled = enabled;
    }
    _service(context)?.refreshStatus();
    setState(() {});
  }

  /// The service when it is wired; Settings also runs in tests and
  /// previews without it, where the card still edits the config.
  ListenBrainzService? _service(BuildContext context) {
    try {
      return context.read<ListenBrainzService>();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = context.read<AppState>().config;
    final scheme = Theme.of(context).colorScheme;
    final hasToken = config.listenbrainzToken.trim().isNotEmpty;
    final status = !config.listenbrainzEnabled
        ? 'disabled'
        : hasToken
        ? 'token set'
        : 'token needed';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ToggleRow(
          title: 'Scrobble to ListenBrainz',
          subtitle: 'Status: $status',
          subtitleColor: status == 'token needed' ? scheme.error : null,
          value: _enabled,
          onChanged: (v) => _save(enabled: v),
          onSettings: () => showDialog(
            context: context,
            builder: (context) => const _ListenBrainzTokenDialog(),
          ),
          action: hasToken
              ? M3ETextButton(
                  onPressed: () {
                    context.read<AppState>().config.listenbrainzToken = '';
                    _service(context)?.logout();
                    setState(() {});
                  },
                  child: const Text('Remove token'),
                )
              : null,
        ),
      ],
    );
  }
}

/// ListenBrainz user token, kept behind the card's cog. The token lives
/// in the secret store, not in `config.properties`.
class _ListenBrainzTokenDialog extends StatefulWidget {
  const _ListenBrainzTokenDialog();

  @override
  State<_ListenBrainzTokenDialog> createState() =>
      _ListenBrainzTokenDialogState();
}

class _ListenBrainzTokenDialogState extends State<_ListenBrainzTokenDialog> {
  late final TextEditingController _token;

  @override
  void initState() {
    super.initState();
    final config = context.read<AppState>().config;
    _token = TextEditingController(text: config.listenbrainzToken);
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  void _save(String value) {
    final config = context.read<AppState>().config;
    config.listenbrainzToken = value.trim();
    try {
      context.read<ListenBrainzService>().refreshStatus();
    } catch (_) {
      // Sandbox settings without the service: the config write is enough.
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsModal(
      title: 'ListenBrainz token',
      children: [
        TextField(
          controller: _token,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'User token',
            helperText: 'From listenbrainz.org/settings',
            border: OutlineInputBorder(),
          ),
          onChanged: _save,
        ),
      ],
    );
  }
}

/// App updates card: current version, a manual check button, and an
/// install button when a newer release is available on GitHub.
///
/// The whole update flow lives in [AppState], so the startup check that
/// raised the banner is the same one this card shows: opening Settings
/// from the banner already lands on the available version instead of
/// asking for another scan.
class _AppUpdatesCard extends StatelessWidget {
  const _AppUpdatesCard();

  /// Current short version (e.g. "0.4.1").
  String get _currentVersion => appVersion.split('+').first;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = context.read<AppState>();
    final info = context.select<AppState, UpdateInfo?>((s) => s.updateInfo);
    final checking = context.select<AppState, bool>((s) => s.updateChecking);
    final checked = context.select<AppState, bool>((s) => s.updateChecked);
    final applying = context.select<AppState, bool>((s) => s.updateApplying);
    final applied = context.select<AppState, bool>((s) => s.updateApplied);
    final failed = context.select<AppState, bool>((s) => s.updateFailed);
    final canInstall = state.canInstallUpdates;
    final busy = checking || applying;
    final bodyStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      // Stretch so the trailing-aligned action buttons reach the card's
      // right edge instead of hugging the widest text.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Current version', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 2),
        Text(_currentVersion, style: bodyStyle),
        const SizedBox(height: 12),
        if (!canInstall) ...[
          // A phone (or a build run from the SDK) has no executable of
          // its own to replace, so "install" would be a dead button:
          // the release page is the whole flow.
          Text(
            'This build cannot replace its own binary, so updates are '
            'installed from the release page.',
            style: bodyStyle,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: M3EOutlinedButton.icon(
              onPressed: () => unawaited(state.openReleasesPage()),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Open the download page'),
            ),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: M3EOutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => unawaited(state.checkForUpdates(force: true)),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Check for updates'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (checking || applying)
            const LinearProgressIndicator()
          else if (applied)
            Text(
              'Update installed. Restart NixieTube to use the new version.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.primary),
            )
          else if (failed)
            Text(
              'The update could not be installed. Download the new AppImage '
              'from the release page instead.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.error),
            )
          else if (info != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Version ${info.version} is available.', style: bodyStyle),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: M3EFilledButton.icon(
                    onPressed: () => unawaited(state.applyUpdate()),
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Install update'),
                  ),
                ),
              ],
            )
          else if (checked)
            Text(
              'No updates available — you are on the latest version.',
              style: bodyStyle,
            ),
        ],
      ],
    );
  }
}

/// The short version from a label like "0.4.1+123" or just "0.3.1".
String _shortVersion(String label) {
  final parts = label.split('+');
  return parts.first;
}

/// The build number from a label like "0.4.1+123", or "unknown" when absent.
String _buildNumber(String label) {
  final parts = label.split('+');
  return parts.length > 1 ? parts[1] : 'unknown';
}

/// Pause-hide timeout: 5, 10 or 15 minutes.
class _DiscordPauseHidePicker extends StatelessWidget {
  const _DiscordPauseHidePicker({required this.config});

  final SysConfig config;

  static const _options = [5, 10, 15];

  @override
  Widget build(BuildContext context) {
    final discord = context.watch<DiscordPresenceBase>();
    final scheme = Theme.of(context).colorScheme;
    return M3EToggleButtonGroup(
      type: M3EButtonGroupType.connected,
      size: M3EButtonSize.sm,
      semanticLabel: 'Discord pause hide timeout',
      selectedIndex: _options.indexOf(discord.pauseHideAfter.inMinutes),
      onSelectedIndexChanged: (i) {
        if (i == null) return;
        final minutes = _options[i];
        config.set('discord.pauseHideMinutes', '$minutes');
        discord.setPauseHideMinutes(minutes);
      },
      actions: [
        for (final m in _options)
          M3EToggleButtonGroupAction(label: Text('$m min')),
      ],
      decoration: toggleButtonGroupDecoration(scheme),
    );
  }
}
