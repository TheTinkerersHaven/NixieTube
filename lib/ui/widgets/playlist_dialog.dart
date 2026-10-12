// Add-to-playlist dialog ported from Kotlin `PlaylistPickerDialog`:
// play-next shortcut plus one toggle row per account playlist.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../../core/innertube/gdata_api.dart';
import '../app_state.dart';

/// Centered add-to-playlist dialog for the dialog track.
class PlaylistPickerDialog extends StatelessWidget {
  const PlaylistPickerDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final track = context.select<AppState, Track?>((s) => s.playlistDialogTrack);
    final playlists = context.select<AppState, List<GPlaylist>>((s) => s.playlists);
    // Render state, not just data: the loading flag flips
    // and the membership map is replaced when the
    // per-playlist checks land, while the track and the
    // playlist list above stay identical — without these
    // selects the dialog never rebuilds and the spinner
    // stays up forever.
    final gdata = context.select<AppState, bool>((s) => s.gdataAvailable);
    final state = context.read<AppState>();
    final loading = context.select<AppState, bool>(
      (s) => s.playlistDialogLoading,
    );
    final membership = context.select<AppState, Map<String, bool>>(
      (s) => s.playlistMembership,
    );
    final dialogError = context.select<AppState, String?>(
      (s) => s.playlistDialogError,
    );
    if (track == null) return const SizedBox.shrink();
    final mine = playlists.where((p) => p.id != '__liked').toList();
    return AlertDialog(
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add to playlist',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              [
                track.title,
                track.artistNames(),
              ].where((s) => s.trim().isNotEmpty).join(' • '),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () {
                state.player.enqueueNext(track);
                // Pop the route: clearing state alone leaves the dialog's
                // ModalBarrier darkening the screen until it is tapped.
                // The dialog watcher clears state when the pop completes.
                Navigator.of(context).pop();
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.playlist_add_rounded),
                    SizedBox(width: 12),
                    Text('Play next'),
                  ],
                ),
              ),
            ),
            const Divider(),
            if (!gdata)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Sign in to manage playlists.'),
              )
            else if (loading && mine.isNotEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  // M3E loading shapes; tight 32x32 keeps the
                  // slot the spinner used to occupy.
                  child: M3ELoadingIndicator(
                    constraints: BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                  ),
                ),
              )
            else if (mine.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No playlists yet. Create some on YouTube Music.'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: mine.length,
                  itemBuilder: (context, i) {
                    final pl = mine[i];
                    final member = membership[pl.id] == true;
                    return InkWell(
                      onTap: () => state.toggleTrackPlaylist(pl.id, track),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Checkbox(
                              value: member,
                              onChanged: (_) =>
                                  state.toggleTrackPlaylist(pl.id, track),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    pl.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyLarge,
                                  ),
                                  Text(
                                    '${pl.itemCount} songs',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (dialogError != null) ...[
              const SizedBox(height: 8),
              Text(
                dialogError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        M3ETextButton(
          onPressed: () {
            // Pop the route (see above): state-only close strands the
            // ModalBarrier.
            Navigator.of(context).pop();
          },
          child: const Text('Close'),
        ),
      ],
    );
  }
}
