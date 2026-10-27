// Shelf cards ported from Kotlin `BrowseCard`, `TrackRailCard`,
// `QuickPickCard` and `SimilarArtistCard`.

import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../theme.dart';
import 'artwork_image.dart';

/// Card for a browsable shelf item (album, playlist, artist): 208dp wide,
/// 200dp art, two-line title plus subtitle.
class BrowseCard extends StatelessWidget {
  const BrowseCard({super.key, required this.item, required this.onTap});

  final BrowseItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final art = item.thumbnails.isEmpty
        ? null
        : item.bestArtwork;
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 208,
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArtworkImage(art, size: 200, radius: cardRadius, iconSize: 48),
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
  }
}

/// Rail card for a track with large artwork, title and artist line.
class TrackRailCard extends StatelessWidget {
  const TrackRailCard({
    super.key,
    required this.track,
    this.playing = false,
    required this.onTap,
  });

  final Track track;
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
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
    final art = item.thumbnails.isEmpty
        ? null
        : item.bestArtwork;
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
