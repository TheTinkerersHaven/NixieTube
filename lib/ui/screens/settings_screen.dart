// Settings screen: account cards,
// listening-history toggle, accessibility options, and desktop
// integration toggles.
//
// Every section shares the same chrome: a [_SectionTitle] heading,
// a [_SettingsCard] surface, and [_ToggleRow] for any switch, so
// the whole screen reads as one uniform list.

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../sys/discord.dart';
import '../../sys/lastfm.dart';
import '../../sys/mpris.dart';
import '../../sys/sys_config.dart';
import '../../sys/updater.dart';
import '../../sys/version.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/screen_list.dart';
import '../widgets/browser_login_dialog.dart';
import '../widgets/lastfm_auth_actions.dart';

/// Account, playback, accessibility and app settings.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _accountKey = GlobalKey();
  final _playbackKey = GlobalKey();
  final _appearanceKey = GlobalKey();
  final _accessibilityKey = GlobalKey();
  final _integrationsKey = GlobalKey();
  final _lastfmKey = GlobalKey();
  final _updatesKey = GlobalKey();
  final _debugKey = GlobalKey();
  final _setupKey = GlobalKey();

  /// Guards against queueing the same post-frame scroll more than once
  /// while the request is still set (it clears after the scroll runs).
  bool _focusScheduled = false;

  @override
  Widget build(BuildContext context) {
    // Select the toggle states so the switches rebuild when the
    // setting flips. Reading them once via `read` would leave the
    // Switch showing its pre-toggle value.
    final reportPlayback = context.select<AppState, bool>(
      (s) => s.config.reportPlayback,
    );
    final highContrast = context.select<AppState, bool>(
      (s) => s.config.highContrast,
    );
    final reducedMotion = context.select<AppState, bool>(
      (s) => s.config.reducedMotion,
    );
    final underlineLinks = context.select<AppState, bool>(
      (s) => s.config.underlineLinks,
    );
    final state = context.read<AppState>();
    // The update banner opens this screen with the App updates section
    // in mind: scroll there once the first frame has laid the list out.
    if (state.focusAppUpdates && !_focusScheduled) {
      _focusScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusScheduled = false;
        if (!mounted) return;
        final target = _updatesKey.currentContext;
        if (target != null) {
          Scrollable.ensureVisible(
            target,
            alignment: 0.04,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
          );
        }
        context.read<AppState>().clearAppUpdatesFocus();
      });
    }
    return screenColumn(
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        Container(
          key: _accountKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                'Account',
                subtitle: 'Sign in to YouTube Music and manage your session.',
              ),
              const SizedBox(height: 8),
              _SettingsCard(child: const _AccountCard()),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Container(
          key: _playbackKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                'Playback',
                subtitle: 'Listening history reporting.',
              ),
              const SizedBox(height: 8),
              _SettingsCard(
                child: _ToggleRow(
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
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Container(
          key: _appearanceKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                'Appearance',
                subtitle: 'Color source, seed and manual overrides.',
              ),
              const SizedBox(height: 8),
              _SettingsCard(child: const _ThemeCard()),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Container(
          key: _accessibilityKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                'Accessibility',
                subtitle: 'Contrast, motion and link styling.',
              ),
              const SizedBox(height: 8),
              _SettingsCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                    const Divider(),
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
                    const Divider(),
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
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Container(
          key: _integrationsKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                'Desktop integrations',
                subtitle: 'MPRIS media keys and Discord Rich Presence.',
              ),
              const SizedBox(height: 8),
              _SettingsCard(child: const _IntegrationsCard()),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Container(
          key: _lastfmKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                'Last.fm scrobbling',
                subtitle: 'Scrobble plays and manage credentials.',
              ),
              const SizedBox(height: 8),
              _SettingsCard(child: const _LastFmCard()),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Container(
          key: _updatesKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                'App updates',
                subtitle: 'Check for and install new releases.',
              ),
              const SizedBox(height: 8),
              _SettingsCard(child: const _AppUpdatesCard()),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Container(
          key: _debugKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                'Debug',
                subtitle: 'Cache and diagnostic actions.',
              ),
              const SizedBox(height: 8),
              _SettingsCard(
                child: _DebugCard(
                  onClearArtwork: () {
                    state.clearArtworkCache();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Artwork cache cleared.')),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Container(
          key: _setupKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                'Setup',
                subtitle: 'Run the first-run wizard again.',
              ),
              const SizedBox(height: 8),
              _SettingsCard(child: const _OnboardingCard()),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          '${_shortVersion(appVersionLabel)} - build ${_buildNumber(appVersionLabel)}',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        Text(
          'Made with ♥  by TheTinkerersHaven :3',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// A section heading in the settings list, with an optional
/// one-line description so the purpose of the section is clear
/// before reading its controls.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.subtitle});

  final String text;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: Theme.of(context).textTheme.titleLarge),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// Uniform card chrome for every settings section: a Material
/// card with a constant inset, so all sections share the same
/// surface and padding.
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
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
  });

  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  /// Opens the advanced-fields modal, or null when the row has none.
  final VoidCallback? onSettings;

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
              ? 'Follows your desktop accent color when the system '
                    'reports one (XDG portal / GTK theme); otherwise '
                    'the built-in theme.'
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

/// MPRIS media-keys service + Discord Rich Presence toggles.
class _IntegrationsCard extends StatefulWidget {
  const _IntegrationsCard();

  @override
  State<_IntegrationsCard> createState() => _IntegrationsCardState();
}

class _IntegrationsCardState extends State<_IntegrationsCard> {
  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final mpris = context.watch<MprisService>();
    final discord = context.watch<DiscordPresence>();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ToggleRow(
          title: 'MPRIS (media keys, playerctl)',
          subtitle:
              mpris.lastError ??
              (!Platform.isLinux
                  ? 'Linux only'
                  : mpris.active
                  ? 'Active on the session bus'
                  : 'Inactive'),
          subtitleColor: mpris.lastError != null ? scheme.error : null,
          value: state.config.mprisEnabled,
          enabled: Platform.isLinux,
          onChanged: (v) {
            state.config.setBool('mpris.enabled', v);
            mpris.setEnabled(v);
            if (v && !mpris.active) {
              unawaited(mpris.start());
            }
            state.refreshConfig();
          },
        ),
        const Divider(),
        _ToggleRow(
          title: 'Discord Rich Presence',
          subtitle: 'Status: ${discord.status}',
          value: state.config.discordEnabled,
          onChanged: (v) {
            state.config.setBool('discord.enabled', v);
            discord.setEnabled(v);
            state.refreshConfig();
          },
          onSettings: () => showDialog(
            context: context,
            builder: (context) => const _DiscordAppIdDialog(),
          ),
        ),
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
    final discord = context.read<DiscordPresence>();
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
    final discord = context.watch<DiscordPresence>();
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
          Text(
            'Method 1 — Built-in browser',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            'Opens a login window right here — sign in with Google '
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
          M3EButton.icon(
            style: M3EButtonStyle.outlined,
            onPressed: loginBusy ? null : _openSystemBrowser,
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Open YouTube Music in your browser'),
          ),
          const SizedBox(height: 8),
          Text(
            '1. In your browser, open music.youtube.com while logged in.\n'
            '2. Open DevTools (F12) → Network tab, then play any song.\n'
            '3. Click any youtubei/v1/ request → Headers → view source → '
            'copy the whole Cookie value.',
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
      crossAxisAlignment: CrossAxisAlignment.start,
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
        M3ETextButton.icon(
          onPressed: () => state.restartOnboarding(),
          icon: const Icon(Icons.replay_rounded),
          label: const Text('Run the setup again'),
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
          title: 'Scrobble plays',
          subtitle: 'Status: $status',
          subtitleColor: status.startsWith('error') ? scheme.error : null,
          value: _enabled,
          onChanged: (v) => _save(enabled: v),
          onSettings: () => showDialog(
            context: context,
            builder: (context) => const _LastFmKeysDialog(),
          ),
        ),
        const SizedBox(height: 12),
        if (signedIn)
          Align(
            alignment: Alignment.centerRight,
            child: M3ETextButton(
              onPressed: () {
                lastfm.logout();
                setState(() {});
              },
              child: const Text('Sign out'),
            ),
          )
        else
          const LastFmAuthActions(),
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
    final busy = checking || applying;
    final bodyStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Current version', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 2),
        Text(_currentVersion, style: bodyStyle),
        const SizedBox(height: 12),
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
    final discord = context.watch<DiscordPresence>();
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
