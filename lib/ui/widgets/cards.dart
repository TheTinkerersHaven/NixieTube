// Shelf cards: browse, track rail, quick-pick and similar-artist cards.

import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../theme.dart';
import 'artwork_image.dart';
import 'browse_menu.dart';
import 'track_menu_scope.dart';

/// Card for a browsable shelf item (album, playlist, artist): 208dp wide,
/// 200dp art, two-line title plus subtitle.
class BrowseCard extends StatelessWidget {
  const BrowseCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width,
    this.track,
    this.contextMenu = true,
  });

  final BrowseItem item;
  final VoidCallback onTap;
  final double? width;

  /// When set, the card stands for a song and right-click opens the
  /// track menu (mixed shelves render their songs as browse cards).
  final Track? track;

  /// Whether right-click and the ⋮ button open the browsable menu.
  final bool contextMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final art = item.thumbnails.isEmpty ? null : item.bestArtwork;
    final cardW = width ?? 208.0;
    final artSize = width != null ? (width! - 8).clamp(40.0, 200.0) : 200.0;
    final card = InkWell(
      onTap: onTap,
      child: Container(
        width: cardW,
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArtworkImage(
              art,
              size: artSize,
              radius: cardRadius,
              iconSize: (artSize / 4).clamp(16.0, 48.0),
            ),
            const SizedBox(height: 8),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Text(
              item.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
    final track = this.track;
    if (track != null) return TrackMenuTarget(track: track, child: card);
    if (!contextMenu) return card;
    return BrowseMenuTarget(item: item, child: card);
  }
}

/// Rail card for a track with large artwork, title and artist line.
///
/// Right-click opens the shared track menu (Play next, Add to playlist,
/// Copy link, Song info). [contextMenu] can turn it off for hosts that
/// supply their own menu.
class TrackRailCard extends StatelessWidget {
  const TrackRailCard({
    super.key,
    required this.track,
    this.playing = false,
    required this.onTap,
    this.contextMenu = true,
    this.showPlaylists = true,
  });

  final Track track;
  final bool playing;
  final VoidCallback onTap;
  final bool contextMenu;
  final bool showPlaylists;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = InkWell(
      onTap: onTap,
      child: Container(
        width: 208,
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArtworkImage(
              track.displayArtwork,
              size: 200,
              radius: cardRadius,
              iconSize: 48,
              squareCoverKey: track.videoId,
            ),
            const SizedBox(height: 8),
            Text(
              track.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: playing ? scheme.primary : scheme.onSurface,
              ),
            ),
            Text.rich(
              TextSpan(
                children: [
                  if (track.explicit)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.explicit,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  TextSpan(
                    text: track.artistNames().isEmpty
                        ? (track.album?.name ?? '')
                        : track.artistNames(),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
    return TrackMenuTarget(
      track: track,
      showPlaylists: showPlaylists,
      enabled: contextMenu,
      child: card,
    );
  }
}

/// Quick-pick card in the YTM style: title overlaid on the artwork with a
/// bottom scrim and a chevron, no text below the art.
class QuickPickCard extends StatelessWidget {
  const QuickPickCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.art,
    this.playing = false,
    this.squareCoverKey,
    required this.onTap,
    this.track,
  });

  final String title;
  final String subtitle;
  final String? art;
  final bool playing;

  /// `videoId` used to resolve the square cover when [art] is a
  /// recognizably 16:9 still (`i.ytimg.com`): quick-pick tiles are
  /// square, so they show the true `yt3.googleusercontent.com` square
  /// art instead of a cropped frame (same rule as [TrackRailCard]).
  final String? squareCoverKey;
  final VoidCallback onTap;

  /// When set, the tile stands for a song and right-click opens the
  /// track menu.
  final Track? track;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = Padding(
      padding: const EdgeInsets.all(4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(cardRadius),
        child: InkWell(
          onTap: onTap,
          child: AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ArtworkImage(
                  art,
                  size: 200,
                  radius: 0,
                  iconSize: 48,
                  squareCoverKey: squareCoverKey,
                  expand: true,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Color.fromRGBO(0, 0, 0, 0.7),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: playing
                                        ? scheme.primary
                                        : Colors.white,
                                  ),
                            ),
                            if (subtitle.trim().isNotEmpty)
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: 0.75,
                                      ),
                                    ),
                              ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white.withValues(alpha: 0.9),
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
    final track = this.track;
    if (track == null) return card;
    return TrackMenuTarget(track: track, child: card);
  }
}

/// Circular-artwork card for an artist with title and subtitle.
class SimilarArtistCard extends StatelessWidget {
  const SimilarArtistCard({super.key, required this.item, required this.onTap});

  final BrowseItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final art = item.thumbnails.isEmpty ? null : item.bestArtwork;
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 160,
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            ArtworkImage(art, size: 136, circular: true, iconSize: 40),
            const SizedBox(height: 8),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (item.subtitle.trim().isNotEmpty)
              Text(
                item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }
}
