// Settings screen ported from Kotlin `Settings.kt`: account cards,
// listening-history toggle, and desktop integration toggles.

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../sys/browser_cookies.dart';
import '../../sys/discord.dart';
import '../../sys/mpris.dart';
import '../app_state.dart';
import '../theme.dart';

/// Account, playback and app settings.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
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
        Text('Account', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        // Two independent sign-ins are required: a Google
        // account (OAuth) for the YouTube Data API, and a
        // browser cookie for InnerTube. Each card states
        // what it unlocks; neither substitutes for the other.
        if (state.account != null) ...[
          _AccountCard(),
          const SizedBox(height: 16),
        ],
        const _GoogleSignInCard(),
        const SizedBox(height: 16),
        const _CookieSignInCard(),
        const SizedBox(height: 24),
        Text('Playback', style: Theme.of(context).textTheme.titleLarge),
        SwitchListTile(
          title: const Text('Report listening history'),
          subtitle: const Text(
            'Send watchtime beacons so plays appear in your YouTube history.',
          ),
          value: state.config.reportPlayback,
          onChanged: (v) {
            state.config.setBool('reportPlayback', v);
            state.refreshConfig();
          },
        ),
        const SizedBox(height: 24),
        Text(
          'Desktop integrations',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const _IntegrationsCard(),
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

/// MPRIS media-keys service + Discord Rich Presence toggles.
class _IntegrationsCard extends StatefulWidget {
  const _IntegrationsCard();

  @override
  State<_IntegrationsCard> createState() => _IntegrationsCardState();
}

class _IntegrationsCardState extends State<_IntegrationsCard> {
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
    final mpris = context.watch<MprisService>();
    final discord = context.watch<DiscordPresence>();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('MPRIS (media keys, playerctl)'),
                      Text(
                        mpris.lastError ??
                            (!Platform.isLinux
                                ? 'Linux only'
                                : mpris.active
                                ? 'Active on the session bus'
                                : 'Inactive'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: mpris.lastError != null
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: state.config.mprisEnabled,
                  onChanged: !Platform.isLinux
                      ? null
                      : (v) {
                          state.config.setBool('mpris.enabled', v);
                          mpris.setEnabled(v);
                          if (v && !mpris.active) {
                            unawaited(mpris.start());
                          }
                          state.refreshConfig();
                        },
                ),
              ],
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Discord Rich Presence'),
                      Text(
                        'Status: ${discord.status}',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: state.config.discordEnabled,
                  onChanged: (v) {
                    state.config.setBool('discord.enabled', v);
                    discord.setEnabled(v);
                    state.refreshConfig();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
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
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                state.account ?? '',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            // Signs out of both the Google (OAuth) and the
            // browser-cookie sessions.
            TextButton(onPressed: state.logout, child: const Text('Sign out')),
          ],
        ),
      ),
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
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final connected = state.oauthSignedIn;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
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
                  connected: connected,
                  label: connected ? 'Connected' : 'Not connected',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              connected
                  ? 'Signed in. Unlocks playlists, liked songs, '
                        'recent activity and followed artists.'
                  : 'Required for playlists, liked songs, recent '
                        'activity and followed artists. The YouTube '
                        'Data API needs a Google OAuth token — a '
                        'browser cookie will not work for these.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (!connected) ...[
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
                  FilledButton(
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
                    TextButton(
                      onPressed: state.cancelGoogleLogin,
                      child: const Text('Cancel'),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
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

  /// Runs the one-click import. With several browsers/profiles
  /// detected, asks which one before reading its cookie store.
  Future<void> _importFromBrowser(List<BrowserProfile> profiles) async {
    final state = context.read<AppState>();
    final profile = profiles.length == 1
        ? profiles.first
        : await showDialog<BrowserProfile>(
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
    if (profile == null || !context.mounted) return;
    await state.loginFromBrowser(profile: profile);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final hasCookie = state.hasCookieSession;
    final valid = state.loginValid;
    final connected = hasCookie && valid;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
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
                  label: !hasCookie
                      ? 'Not connected'
                      : valid
                      ? 'Connected'
                      : 'Expired',
                  expired: hasCookie && !valid,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              connected
                  ? 'Signed in. Unlocks playback, listening '
                        'history (watchtime) and the InnerTube '
                        'library.'
                  : hasCookie
                  ? 'This cookie has expired — YouTube treats '
                        'the session as signed out, so listening '
                        'history stops recording. Paste a fresh '
                        'Cookie header.'
                  : 'Required for playback, listening history '
                        '(watchtime) and the InnerTube library. '
                        'InnerTube needs a cookie + SAPISIDHASH — '
                        'an OAuth token will not work for these.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (!connected) ...[
              const SizedBox(height: 12),
              if (state.browserProfiles.isNotEmpty) ...[
                OutlinedButton.icon(
                  onPressed: state.loginBusy
                      ? null
                      : () => _importFromBrowser(
                          state.browserProfiles,
                        ),
                  icon: const Icon(Icons.download),
                  label: Text(state.loginBusy
                      ? 'Reading cookies…'
                      : 'Import from ${state.browserProfiles.first.label}'),
                ),
                const SizedBox(height: 10),
                Text(
                  'Reads the signed-in session from your browser '
                  'directly — no DevTools needed.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                const Text('…or paste it manually:'),
                const SizedBox(height: 8),
              ],
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
              if (state.loginDetail != null) ...[
                const SizedBox(height: 8),
                Text(
                  state.loginDetail!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 8),
              FilledButton(
                onPressed: state.loginBusy
                    ? null
                    : () => state.login(_cookie.text),
                child: Text(state.loginBusy ? 'Verifying…' : 'Sign in'),
              ),
            ],
          ],
        ),
      ),
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
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
