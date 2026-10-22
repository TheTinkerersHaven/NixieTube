// The Last.fm browser-approval flow: connect, confirm, or reopen.
//
// Shared by the settings card and the first-run setup, so the account
// can be connected from either place.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../sys/lastfm.dart';
import '../app_state.dart';

/// The Last.fm sign-in actions.
class LastFmAuthActions extends StatelessWidget {
  const LastFmAuthActions({
    super.key,
    required this.token,
    required this.busy,
    required this.onStart,
    required this.onBusyChange,
    required this.onFailed,
    required this.onToken,
    required this.onSignedIn,
  });

  /// The token waiting for the browser approval, or null when the
  /// flow has not started.
  final String? token;

  /// Whether a request is in flight.
  final bool busy;

  /// Called when a request starts.
  final VoidCallback onStart;

  /// Called with the new busy state.
  final ValueChanged<bool> onBusyChange;

  /// Called when the request failed or was denied.
  final VoidCallback onFailed;

  /// Called with the token the browser has to approve.
  final ValueChanged<String?> onToken;

  /// Called when the account is connected.
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
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            M3EFilledButton(
              onPressed: busy ? null : () => _complete(context),
              child: Text(busy ? 'Verifying…' : "I've authorized it"),
            ),
            // The token is short-lived: if it expired before the
            // approval, a fresh one is the way forward — without
            // leaving the settings.
            M3ETextButton(
              onPressed: busy ? null : () => _requestToken(context),
              child: const Text('Get a new token'),
            ),
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
