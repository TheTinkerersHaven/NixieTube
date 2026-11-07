// The Last.fm sign-in panel: connect, confirm, or reopen.
//
// Shared by the settings card and the first-run setup, so the account
// can be connected from either place. The panel owns the flow state
// (the pending token, the in-flight flag and the failure notice), so
// both screens stay free of duplicated bookkeeping.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../sys/lastfm.dart';
import '../app_state.dart';

/// The Last.fm sign-in actions, including the failure notice.
class LastFmAuthActions extends StatefulWidget {
  const LastFmAuthActions({super.key});

  @override
  State<LastFmAuthActions> createState() => _LastFmAuthActionsState();
}

class _LastFmAuthActionsState extends State<LastFmAuthActions> {
  bool _busy = false;
  bool _failed = false;
  String? _token;

  /// Asks Last.fm for a token and opens the approval page.
  Future<void> _requestToken() async {
    setState(() {
      _failed = false;
      _busy = true;
    });
    final lastfm = context.read<LastFmService>();
    final app = context.read<AppState>();
    final fresh = await lastfm.requestToken();
    if (!mounted) return;
    if (fresh == null) {
      setState(() => _failed = true);
    } else {
      setState(() => _token = fresh);
      await app.openUrl(lastfm.authorizeUrl(fresh));
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Confirms the token the user approved in the browser.
  Future<void> _complete() async {
    setState(() {
      _failed = false;
      _busy = true;
    });
    final lastfm = context.read<LastFmService>();
    final ok = await lastfm.completeAuth(_token!);
    if (!mounted) return;
    if (ok) {
      setState(() => _token = null);
    } else {
      setState(() => _failed = true);
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_failed) ...[
          Text(
            'Sign-in failed or was denied. Check the key/secret and try '
            'again.',
            style: TextStyle(color: scheme.error),
          ),
          const SizedBox(height: 8),
        ],
        if (_token == null)
          M3EFilledButton(
            onPressed: _busy ? null : _requestToken,
            child: Text(_busy ? 'Requesting…' : 'Connect with last.fm'),
          )
        else
          _approvalActions(context),
      ],
    );
  }

  /// The actions shown while a token waits for the browser approval.
  Widget _approvalActions(BuildContext context) {
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
              onPressed: _busy ? null : _complete,
              child: Text(_busy ? 'Verifying…' : "I've authorized it"),
            ),
            // The token is short-lived: if it expired before the
            // approval, a fresh one is the way forward — without
            // leaving the settings.
            M3ETextButton(
              onPressed: _busy ? null : _requestToken,
              child: const Text('Get a new token'),
            ),
            M3ETextButton(
              onPressed: () => context.read<AppState>().openUrl(
                context.read<LastFmService>().authorizeUrl(_token!),
              ),
              child: const Text('Reopen browser'),
            ),
          ],
        ),
      ],
    );
  }
}
