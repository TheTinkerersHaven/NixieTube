// First-run setup: a short guided flow that introduces the app, signs
// the user in and offers a couple of choices (accent color, motion,
// Last.fm).
//
// It shows once, on the first start, and is skipped for good once the
// user is through it (the flag lives in the app settings).

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../sys/browser_cookies.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/browser_login_dialog.dart';
import '../widgets/lastfm_auth_actions.dart';

/// The steps of the setup, in order.
enum _Step { welcome, signIn, personalize }

/// Preset accent colors offered in the personalization step.
const _seedColors = <(String, int)>[
  ('YouTube red', 0xffff0000),
  ('Purple', 0xff7b1fa2),
  ('Indigo', 0xff3949ab),
  ('Teal', 0xff00897b),
  ('Amber', 0xffffa000),
];

/// The first-run setup.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  _Step _step = _Step.welcome;

  /// The cookie pasted by hand, if any.
  final TextEditingController _cookie = TextEditingController();

  @override
  void dispose() {
    _pageController.dispose();
    _cookie.dispose();
    super.dispose();
  }

  void _goTo(_Step step) {
    setState(() => _step = step);
    final index = _Step.values.indexOf(step);
    // The reduced-motion setting is read directly: the motion helper
    // needs a build context, and this runs in an event handler.
    final reduced = context.read<AppState>().config.reducedMotion;
    if (reduced) {
      // A zero-length scroll animation is not allowed — jump instead.
      _pageController.jumpToPage(index);
      return;
    }
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// Leaves the setup for good.
  void _finish() {
    context.read<AppState>().completeOnboarding();
  }

  Future<void> _loginWithBrowserWindow() async {
    final state = context.read<AppState>();
    final header = await showBrowserLoginDialog(context);
    if (header == null || header.isEmpty || !mounted) return;
    try {
      await state.login(header);
    } catch (_) {
      // login() reports known failures via loginDetail.
    }
  }

  Future<void> _importFromBrowser(List<BrowserProfile> profiles) async {
    final state = context.read<AppState>();
    if (profiles.length > 1 && !mounted) return;
    if (profiles.length > 1) {
      final picked = await showDialog<BrowserProfile>(
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
      if (picked == null || !mounted) return;
      await state.loginFromBrowser(profile: picked);
      return;
    }
    await state.loginFromBrowser(profile: profiles.first);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = context.read<AppState>();
    final signedIn = context.select<AppState, bool>((s) => s.hasCookieSession);
    final loginBusy = context.select<AppState, bool>((s) => s.loginBusy);
    final loginDetail = context.select<AppState, String?>((s) => s.loginDetail);
    final profiles = context.select<AppState, List<BrowserProfile>>(
      (s) => s.browserProfiles,
    );
    final last = _Step.values.length - 1;
    final index = _Step.values.indexOf(_step);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              children: [
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (i) {
                      setState(() => _step = _Step.values[i]);
                    },
                    children: [
                      _WelcomeStep(scheme: scheme),
                      _SignInStep(
                        scheme: scheme,
                        signedIn: signedIn,
                        loginBusy: loginBusy,
                        loginDetail: loginDetail,
                        profiles: profiles,
                        cookie: _cookie,
                        onBrowserWindow: _loginWithBrowserWindow,
                        onImportBrowser: _importFromBrowser,
                        onPaste: () => state.login(_cookie.text),
                      ),
                      const _PersonalizeStep(),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: () => _finish(),
                        child: const Text('Skip setup'),
                      ),
                      const Spacer(),
                      if (index > 0)
                        TextButton(
                          onPressed: () => _goTo(_Step.values[index - 1]),
                          child: const Text('Back'),
                        ),
                      const SizedBox(width: 8),
                      M3EFilledButton(
                        onPressed: () {
                          if (index == last) {
                            _finish();
                          } else {
                            _goTo(_Step.values[index + 1]);
                          }
                        },
                        child: Text(index == last ? 'Start listening' : 'Next'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Step one: what the app is.
class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Image.asset(
            'assets/icon/nixietube.png',
            width: 64,
            height: 64,
            filterQuality: FilterQuality.medium,
          ),
          const SizedBox(height: 20),
          Text('Welcome to NixieTube', style: text.headlineSmall),
          const SizedBox(height: 12),
          Text(
            'A YouTube Music client for your desktop, with the look and '
            'feel of Material You.',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          const _Point(
            icon: Icons.login_rounded,
            title: 'Sign in once',
            body:
                'A browser session unlocks playback, your listening '
                'history and your whole library.',
          ),
          const _Point(
            icon: Icons.library_music_rounded,
            title: 'Your library, in order',
            body:
                'Playlists, liked songs, recent activity and the artists '
                'you follow.',
          ),
          const _Point(
            icon: Icons.download_rounded,
            title: 'Offline-friendly',
            body:
                'Artwork and metadata are cached, so the app stays snappy '
                'on a slow connection.',
          ),
        ],
      ),
    );
  }
}

/// One selling point on the welcome step.
class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleSmall),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Step two: the sign-in.
class _SignInStep extends StatelessWidget {
  const _SignInStep({
    required this.scheme,
    required this.signedIn,
    required this.loginBusy,
    required this.loginDetail,
    required this.profiles,
    required this.cookie,
    required this.onBrowserWindow,
    required this.onImportBrowser,
    required this.onPaste,
  });

  final ColorScheme scheme;
  final bool signedIn;
  final bool loginBusy;
  final String? loginDetail;
  final List<BrowserProfile> profiles;
  final TextEditingController cookie;
  final Future<void> Function() onBrowserWindow;
  final Future<void> Function(List<BrowserProfile>) onImportBrowser;
  final Future<void> Function() onPaste;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sign in to your account', style: text.headlineSmall),
          const SizedBox(height: 12),
          Text(
            'One sign-in covers everything. Your session is kept in the '
            'system keyring, never in a plain-text file.',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          if (signedIn)
            Row(
              children: [
                Icon(Icons.check_circle_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Signed in — you are all set.',
                    style: text.bodyLarge,
                  ),
                ),
              ],
            )
          else ...[
            M3EFilledButton.icon(
              onPressed: loginBusy ? null : onBrowserWindow,
              icon: const Icon(Icons.login_rounded),
              label: Text(loginBusy ? 'Verifying…' : 'Log in with browser'),
            ),
            const SizedBox(height: 10),
            Text(
              'Opens a login window right here — sign in with Google and '
              'the session is picked up when you confirm.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (profiles.isNotEmpty) ...[
              const SizedBox(height: 18),
              M3ETextButton.icon(
                onPressed: loginBusy ? null : () => onImportBrowser(profiles),
                icon: const Icon(Icons.download_rounded),
                label: Text(
                  loginBusy
                      ? 'Reading cookies…'
                      : "I've signed in — import now",
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Reads the fresh session from your system browser directly.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 22),
            Text('Or paste the cookie by hand:', style: text.bodyMedium),
            const SizedBox(height: 8),
            TextField(
              controller: cookie,
              decoration: const InputDecoration(
                labelText: 'Cookie header value',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
              minLines: 1,
            ),
            const SizedBox(height: 10),
            M3ETextButton(
              onPressed: loginBusy ? null : onPaste,
              child: const Text('Sign in with this cookie'),
            ),
          ],
          if (loginDetail != null) ...[
            const SizedBox(height: 12),
            Text(loginDetail!, style: TextStyle(color: scheme.error)),
          ],
        ],
      ),
    );
  }
}

/// Step three: the choices.
class _PersonalizeStep extends StatelessWidget {
  const _PersonalizeStep();

  @override
  Widget build(BuildContext context) {
    // Watched, not read: the toggles write to the config, and the
    // step has to rebuild for the switches and the swatches to show
    // the new values.
    final state = context.watch<AppState>();
    final config = state.config;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final systemAccent = config.themeSource == ThemeSource.system.name;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Make it yours', style: text.headlineSmall),
          const SizedBox(height: 12),
          Text(
            'Everything here can be changed later in Settings.',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          Text('Accent color', style: text.titleSmall),
          const SizedBox(height: 10),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(value: true, label: Text('System accent')),
              ButtonSegment<bool>(value: false, label: Text('Custom color')),
            ],
            selected: {systemAccent},
            onSelectionChanged: (selection) {
              config.themeSource = selection.first
                  ? ThemeSource.system.name
                  : ThemeSource.custom.name;
              state.refreshConfig();
            },
          ),
          if (!systemAccent) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                for (final (name, color) in _seedColors)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: _SeedDot(
                      name: name,
                      color: Color(color),
                      selected: config.themeSeedColor == color,
                      onTap: () {
                        config.themeSeedColor = color;
                        state.refreshConfig();
                      },
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 26),
          _Toggle(
            title: 'Reduce motion',
            body: 'Calms the animations down.',
            value: config.reducedMotion,
            onChanged: (v) {
              config.reducedMotion = v;
              state.refreshConfig();
            },
          ),
          _Toggle(
            title: 'High contrast',
            body: 'Stronger colors and borders.',
            value: config.highContrast,
            onChanged: (v) {
              config.highContrast = v;
              state.refreshConfig();
            },
          ),
          const SizedBox(height: 18),
          _LastFmRow(
            enabled: config.lastfmEnabled,
            signedIn: config.lastfmSessionKey.trim().isNotEmpty,
            onEnabled: (v) => config.lastfmEnabled = v,
          ),
        ],
      ),
    );
  }
}

/// The Last.fm row of the personalization step: the toggle plus the
/// sign-in, so the account can be connected right away.
class _LastFmRow extends StatefulWidget {
  const _LastFmRow({
    required this.enabled,
    required this.signedIn,
    required this.onEnabled,
  });

  /// Whether scrobbling is on.
  final bool enabled;

  /// Whether a Last.fm account is connected.
  final bool signedIn;

  /// Called with the new toggle state.
  final ValueChanged<bool> onEnabled;

  @override
  State<_LastFmRow> createState() => _LastFmRowState();
}

class _LastFmRowState extends State<_LastFmRow> {
  bool _busy = false;
  bool _failed = false;
  String? _token;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Toggle(
          title: 'Last.fm scrobbling',
          body:
              'Scrobble what you play to your Last.fm account. '
              'You can set the API keys later.',
          value: widget.enabled,
          onChanged: widget.onEnabled,
        ),
        if (_failed) ...[
          Text(
            'Sign-in failed or was denied. Check the key/secret and try '
            'again.',
            style: TextStyle(color: scheme.error),
          ),
          const SizedBox(height: 8),
        ],
        if (widget.signedIn)
          Row(
            children: [
              Icon(Icons.check_circle_rounded, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Connected to Last.fm.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          )
        else
          LastFmAuthActions(
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
      ],
    );
  }
}

/// A preset color button.
class _SeedDot extends StatelessWidget {
  const _SeedDot({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: name,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(
              color: selected ? scheme.onSurface : Colors.transparent,
              width: 3,
            ),
          ),
        ),
      ),
    );
  }
}

/// A switch with a title and a hint.
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.title,
    required this.body,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String body;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Expanded(
            // The whole row toggles, not just the switch.
            child: InkWell(
              onTap: () => onChanged(!value),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      body,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
