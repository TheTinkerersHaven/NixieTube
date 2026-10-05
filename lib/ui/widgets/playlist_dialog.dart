// Add-to-playlist dialog ported from Kotlin `PlaylistPickerDialog`:
// play-next shortcut plus one toggle row per account playlist.

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// Centered add-to-playlist dialog for the dialog track.
class PlaylistPickerDialog extends StatelessWidget {
  const PlaylistPickerDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final track = state.playlistDialogTrack;
    if (track == null) return const SizedBox.shrink();
    final mine = state.playlists.where((p) => p.id != '__liked').toList();
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
            if (state.gdataAvailable == false)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Sign in to manage playlists.'),
              )
            else if (state.playlistDialogLoading && mine.isNotEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(),
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
                    final member = state.playlistMembership[pl.id] == true;
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
            if (state.playlistDialogError != null) ...[
              const SizedBox(height: 8),
              Text(
                state.playlistDialogError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
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
