// Settings screen ported from Kotlin `Settings.kt`: account cards,
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

import '../../sys/browser_cookies.dart';
import '../../sys/discord.dart';
import '../../sys/lastfm.dart';
import '../../sys/mpris.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/browser_login_dialog.dart';

/// Account, playback, accessibility and app settings.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final account = context.select<AppState, String?>((s) => s.account);
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
    // Drives the ordered sign-in: the cookie card unlocks once the
    // Google (OAuth) sign-in is done.
    final oauthSignedIn = context.select<AppState, bool>(
      (s) => s.oauthSignedIn,
    );
    final state = context.read<AppState>();
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        screenPadding,
        screenPadding,
        screenPadding,
        screenPadding + playerBarClearance,
      ),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        const _SectionTitle('Account'),
        const SizedBox(height: 8),
        if (account != null) ...[
          _SettingsCard(child: _AccountCard()),
          const SizedBox(height: 16),
        ],
        // --- Data API / OAuth ---
        // First in order: the cookie session below stays disabled until
        // this Google (OAuth) sign-in is done. A Google OAuth token
        // unlocks playlists, liked songs, recent activity and followed
        // artists; a browser cookie will not work for these.
        const _SectionTitle('YouTube Data API'),
        const SizedBox(height: 8),
        _SettingsCard(child: const _GoogleSignInCard()),
        const SizedBox(height: 24),
        // --- InnerTube / cookie ---
        // Second in order: the cookie session below is disabled until
        // the Google (OAuth) sign-in above is done, so the two steps
        // are completed in order rather than half-configured.
        const _SectionTitle('InnerTube (cookie)'),
        const SizedBox(height: 8),
        _SettingsCard(
          child: oauthSignedIn
              ? const _CookieSignInCard()
              : const _LoginOrderNotice(),
        ),
        const SizedBox(height: 24),
        const _SectionTitle('Playback'),
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
        const SizedBox(height: 24),
        const _SectionTitle('Appearance'),
        const SizedBox(height: 8),
        _SettingsCard(child: const _ThemeCard()),
        const SizedBox(height: 24),
        const _SectionTitle('Accessibility'),
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
        const SizedBox(height: 24),
        const _SectionTitle('Desktop integrations'),
        const SizedBox(height: 8),
        _SettingsCard(child: const _IntegrationsCard()),
        const SizedBox(height: 24),
        const _SectionTitle('Last.fm scrobbling'),
        const SizedBox(height: 8),
        _SettingsCard(child: const _LastFmCard()),
        const SizedBox(height: 24),
        const _SectionTitle('Debug'),
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
        const SizedBox(height: 24),
        Text(
          'NixieTube Flutter port — desktop client',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// A section heading in the settings list.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.titleLarge);
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
          'Delete every cached cover (raw downloads + rendered crops), '
          'reset failed-download skips, and drop decoded images from '
          'memory, so all artwork re-fetches and re-renders from '
          'scratch on the next display.',
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
    return _SettingsModal(
      title: 'Discord application ID',
      children: [
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
      ],
    );
  }
}

/// Placeholder for the InnerTube card while the Google (OAuth) sign-in
/// is still missing: sign-ins happen in a fixed order, and the second
/// step is not offered until the first is done.
class _LoginOrderNotice extends StatelessWidget {
  const _LoginOrderNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Complete the Google sign-in above first.',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          'Sign-ins run in order: 1) the Google account (Data API), '
          '2) the browser cookie (InnerTube). This step unlocks once '
          'the first is done.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        // Grayed-out preview of the gated card, so the shape of the
        // next step is visible (but inert) before it unlocks.
        Opacity(
          opacity: 0.4,
          child: IgnorePointer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Browser cookie — InnerTube',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Unlocks playback, listening history (watchtime) and '
                  'the InnerTube library.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                M3EFilledButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.lock_rounded),
                  label: const Text('Log in with browser'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AccountCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final account = context.select<AppState, String?>((s) => s.account);

    // Display-only: each session below (Data API, cookie) has its
    // own sign-out button.
    return Row(
      children: [
        Expanded(
          child: Text(
            account ?? '',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ],
    );
  }
}

class _GoogleSignInCard extends StatefulWidget {
  const _GoogleSignInCard();

  @override
  State<_GoogleSignInCard> createState() => _GoogleSignInCardState();
}

class _GoogleSignInCardState extends State<_GoogleSignInCard> {
  late final TextEditingController _id;
  late final TextEditingController _secret;

  @override
  void initState() {
    super.initState();
    final config = context.read<AppState>().config;
    _id = TextEditingController(text: config.googleClientId);
    _secret = TextEditingController(text: config.googleClientSecret);
  }

  @override
  void dispose() {
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final oauthSignedIn = context.select<AppState, bool>(
      (s) => s.oauthSignedIn,
    );
    final scheme = Theme.of(context).colorScheme;
    final state = context.read<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Google account — YouTube Data API',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            _AuthStatus(
              connected: oauthSignedIn,
              label: oauthSignedIn ? 'Connected' : 'Not connected',
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          oauthSignedIn
              ? 'Signed in. Unlocks playlists, liked songs, '
                    'recent activity and followed artists.'
              : 'Required for playlists, liked songs, recent '
                    'activity and followed artists. The YouTube '
                    'Data API needs a Google OAuth token — a '
                    'browser cookie will not work for these.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (oauthSignedIn) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: M3ETextButton(
              onPressed: state.logoutGoogle,
              child: const Text('Sign out'),
            ),
          ),
        ],
        if (!oauthSignedIn) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _id,
            decoration: const InputDecoration(
              labelText: 'OAuth client ID (Desktop type)',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => state.config.set('google.clientId', v),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _secret,
            decoration: const InputDecoration(
              labelText: 'OAuth client secret',
              border: OutlineInputBorder(),
            ),
            obscureText: true,
            onChanged: (v) => state.config.set('google.clientSecret', v),
          ),
          if (state.loginDetail != null) ...[
            const SizedBox(height: 8),
            Text(
              state.loginDetail!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              M3EFilledButton(
                onPressed: state.loginBusy
                    ? null
                    : () => state.googleBrowserLogin(),
                child: Text(
                  state.loginBusy
                      ? 'Waiting for browser…'
                      : 'Sign in with Google',
                ),
              ),
              if (state.loginBusy) ...[
                const SizedBox(width: 8),
                M3ETextButton(
                  onPressed: state.cancelGoogleLogin,
                  child: const Text('Cancel'),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class _CookieSignInCard extends StatefulWidget {
  const _CookieSignInCard();

  @override
  State<_CookieSignInCard> createState() => _CookieSignInCardState();
}

class _CookieSignInCardState extends State<_CookieSignInCard> {
  final TextEditingController _cookie = TextEditingController();

  @override
  void dispose() {
    _cookie.dispose();
    super.dispose();
  }

  /// Profile picker shared by the guided and instant flows. Null
  /// when several profiles exist and the dialog is dismissed.
  Future<BrowserProfile?> _pickProfile(List<BrowserProfile> profiles) async {
    if (profiles.length == 1) return profiles.first;
    if (!context.mounted) return null;
    return showDialog<BrowserProfile>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Choose a browser profile'),
        children: [
          for (final p in profiles)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text('${p.label} — ${p.cookiesDb}'),
              ),
            ),
        ],
      ),
    );
  }

  /// Runs the embedded login window, then signs in with the fresh
  /// session it returns (if any).
  Future<void> _loginWithBrowserWindow() async {
    final state = context.read<AppState>();
    final header = await showBrowserLoginDialog(context);
    if (header == null || header.isEmpty || !context.mounted) return;
    try {
      await state.login(header);
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

  /// Runs the one-click import. With several browsers/profiles
  /// detected, asks which one before reading its cookie store.
  Future<void> _importFromBrowser(List<BrowserProfile> profiles) async {
    final state = context.read<AppState>();
    final profile = await _pickProfile(profiles);
    if (profile == null || !context.mounted) return;
    await state.loginFromBrowser(profile: profile);
  }

  @override
  Widget build(BuildContext context) {
    final hasCookieSession = context.select<AppState, bool>(
      (s) => s.hasCookieSession,
    );
    final loginValid = context.select<AppState, bool>((s) => s.loginValid);
    final loginBusy = context.select<AppState, bool>((s) => s.loginBusy);
    final loginDetail = context.select<AppState, String?>((s) => s.loginDetail);
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
                'Browser cookie — InnerTube',
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
          M3EFilledButton.icon(
            onPressed: loginBusy ? null : _loginWithBrowserWindow,
            icon: const Icon(Icons.login_rounded),
            label: Text(loginBusy ? 'Verifying…' : 'Log in with browser'),
          ),
          const SizedBox(height: 10),
          Text(
            'Opens a login window right here — sign in with Google '
            'and the session is picked up when you confirm. '
            'Prefer your own browser? Open it below, sign in, '
            'then import.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          M3ETextButton.icon(
            onPressed: loginBusy ? null : _openSystemBrowser,
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Open YouTube Music instead'),
          ),
          const SizedBox(height: 12),
          if (state.browserProfiles.isNotEmpty) ...[
            M3EFilledButton.icon(
              onPressed: loginBusy
                  ? null
                  : () => _importFromBrowser(state.browserProfiles),
              icon: const Icon(Icons.download_rounded),
              label: Text(
                loginBusy ? 'Reading cookies…' : "I've signed in — import now",
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Reads the fresh session from your system '
              'browser directly — no DevTools needed.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ] else ...[
            Text(
              'No Chromium-family browser profile found on this '
              'device — use the manual paste below.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          const Text('…or paste it manually:'),
          const SizedBox(height: 8),
          const Text(
            '1. In your browser, open music.youtube.com while logged in.\n'
            '2. Open DevTools (F12) → Network tab, then play any song.\n'
            '3. Click any youtubei/v1/ request → Headers → view source → '
            'copy the whole Cookie value.',
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

/// Last.fm scrobbling card (ported from Kotlin `LastFmCard`): enable toggle,
/// API key/secret fields, browser-approval login, and sign-out.
class _LastFmCard extends StatefulWidget {
  const _LastFmCard();

  @override
  State<_LastFmCard> createState() => _LastFmCardState();
}

class _LastFmCardState extends State<_LastFmCard> {
  late bool _enabled;
  bool _busy = false;
  bool _failed = false;
  String? _token;

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
        const SizedBox(height: 8),
        Text(
          'Empty credential fields use the built-in shared key — fill '
          'them only to use your own last.fm/api application.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        if (_failed) ...[
          Text(
            'Sign-in failed or was denied. Check the key/secret and '
            'try again.',
            style: TextStyle(color: scheme.error),
          ),
          const SizedBox(height: 8),
        ],
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
          _LastFmAuthActions(
            token: _token,
            busy: _busy,
            onStart: () => setState(() {
              _failed = false;
              _busy = true;
            }),
            onBusyChange: (b) => setState(() => _busy = b),
            onFailed: () => setState(() => _failed = true),
            onToken: (t) => setState(() => _token = t),
            onSignedIn: () => setState(() => _token = null),
          ),
        const SizedBox(height: 8),
        Text(
          'Scrobbles tracks over 30 seconds once half played or '
          '4 minutes pass; now-playing shows on track start.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
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

/// Last.fm browser-approval flow: connect, confirm, or reopen.
class _LastFmAuthActions extends StatelessWidget {
  const _LastFmAuthActions({
    required this.token,
    required this.busy,
    required this.onStart,
    required this.onBusyChange,
    required this.onFailed,
    required this.onToken,
    required this.onSignedIn,
  });

  final String? token;
  final bool busy;
  final VoidCallback onStart;
  final ValueChanged<bool> onBusyChange;
  final VoidCallback onFailed;
  final ValueChanged<String?> onToken;
  final VoidCallback onSignedIn;

  Future<void> _requestToken(BuildContext context) async {
    onStart();
    final lastfm = context.read<LastFmService>();
    final app = context.read<AppState>();
    final fresh = await lastfm.requestToken();
    if (!context.mounted) return;
    if (fresh != null) {
      onToken(fresh);
      await app.openUrl(lastfm.authorizeUrl(fresh));
    } else {
      onFailed();
    }
    onBusyChange(false);
  }

  Future<void> _complete(BuildContext context) async {
    onStart();
    final lastfm = context.read<LastFmService>();
    final ok = await lastfm.completeAuth(token!);
    if (!context.mounted) return;
    if (ok) {
      onSignedIn();
    } else {
      onFailed();
    }
    onBusyChange(false);
  }

  @override
  Widget build(BuildContext context) {
    if (token == null) {
      return Row(
        children: [
          M3EFilledButton(
            onPressed: busy ? null : () => _requestToken(context),
            child: Text(busy ? 'Requesting…' : 'Connect with last.fm'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Approve NixieTube in the browser tab, then continue here.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            M3EFilledButton(
              onPressed: busy ? null : () => _complete(context),
              child: Text(busy ? 'Verifying…' : "I've authorized it"),
            ),
            const SizedBox(width: 8),
            M3ETextButton(
              onPressed: () => context.read<AppState>().openUrl(
                context.read<LastFmService>().authorizeUrl(token!),
              ),
              child: const Text('Reopen browser'),
            ),
          ],
        ),
      ],
    );
  }
}
