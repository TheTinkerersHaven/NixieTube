// Track list row ported from Kotlin `TrackRow`: artwork, title,
// artist/album, duration, and optional rating/playlist actions.

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import 'artwork_image.dart';

/// One track row. Rating buttons appear when [rateable] and signed in;
/// the playlist button opens the add-to-playlist dialog.
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.track,
    this.index,
    this.playing = false,
    required this.onPlay,
    this.rateable = false,
    this.showPlaylists = false,
  });

  final Track track;
  final int? index;
  final bool playing;
  final VoidCallback onPlay;
  final bool rateable;
  final bool showPlaylists;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final signedIn = context.select<AppState, bool>((s) => s.account != null);
    final subtitle = [
      track.artistNames(),
      track.album?.name ?? '',
    ].where((s) => s.trim().isNotEmpty).join(' • ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      onTap: onPlay,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (index != null)
            SizedBox(
              width: 28,
              child: Text(
                '$index',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: playing ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ArtworkImage(
            track.displayArtwork,
            size: 48,
            radius: rowArtRadius,
            iconSize: 24,
          ),
        ],
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: playing ? scheme.primary : scheme.onSurface),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (rateable && signedIn) ...[
            IconButton(
              icon: const Icon(Icons.thumb_up_rounded),
              tooltip: track.rating == RatingStatus.like
                  ? 'Remove like'
                  : 'Like',
              color: track.rating == RatingStatus.like
                  ? scheme.primary
                  : scheme.onSurface,
              onPressed: () => context.read<AppState>().rateTrackFeedback(
                context,
                track.videoId,
                track.rating == RatingStatus.like
                    ? RatingStatus.indifferent
                    : RatingStatus.like,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.thumb_down_rounded),
              tooltip: track.rating == RatingStatus.dislike
                  ? 'Remove dislike'
                  : 'Dislike',
              color: track.rating == RatingStatus.dislike
                  ? scheme.primary
                  : scheme.onSurface,
              onPressed: () => context.read<AppState>().rateTrackFeedback(
                context,
                track.videoId,
                track.rating == RatingStatus.dislike
                    ? RatingStatus.indifferent
                    : RatingStatus.dislike,
              ),
            ),
          ] else ...[
            if (track.rating == RatingStatus.like ||
                track.rating == RatingStatus.dislike)
              Icon(
                track.rating == RatingStatus.dislike
                    ? Icons.thumb_down_rounded
                    : Icons.thumb_up_rounded,
                color: scheme.primary,
              ),
          ],
          if (track.durationSec > 0)
            Text(
              _fmtDur(track.durationSec),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (showPlaylists)
            IconButton(
              icon: const Icon(Icons.playlist_add_rounded),
              tooltip: 'Add to playlist',
              onPressed: () =>
                  context.read<AppState>().openPlaylistDialog(track),
            ),
        ],
      ),
    );
  }
}

String _fmtDur(int sec) {
  if (sec <= 0) return '0:00';
  return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
}
