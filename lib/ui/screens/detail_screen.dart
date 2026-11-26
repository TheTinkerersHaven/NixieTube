// Detail screen: picks the body for an opened browse item — the artist
// page, or the shared album/playlist panel with its loading and error
// states.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/album_panel.dart';
import '../widgets/detail_header.dart';
import '../widgets/detail_menu.dart';
import '../widgets/loading_placeholders.dart';
import '../widgets/palette_backdrop.dart';
import '../widgets/rails.dart';
import 'artist_screen.dart';

/// Coarse kind derived from a browse id's prefix, used to pick the
/// loading skeleton and the body layout without scattering `startsWith`
/// checks across the build method.
enum DetailKind { artist, album, playlist, unknown }

DetailKind _detailKind(String? browseId) {
  if (browseId == null || browseId.isEmpty) return DetailKind.unknown;
  if (browseId.startsWith('UC')) return DetailKind.artist;
  if (browseId.startsWith('MPRE')) return DetailKind.album;
  return DetailKind.playlist;
}

/// Album/artist/playlist detail page for [AppState.detailItem].
class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final detail = context.select<AppState, DetailUiState>((s) => s.detail);
    final item = context.select<AppState, BrowseItem?>((s) => s.detailItem);
    final state = context.read<AppState>();
    if (detail.loading) {
      switch (_detailKind(item?.browseId)) {
        case DetailKind.album:
          return const _DetailSkeleton(numbered: true);
        case DetailKind.artist:
          return const ArtistScreenSkeleton();
        case DetailKind.playlist:
          return const _DetailSkeleton(numbered: false);
        case DetailKind.unknown:
          return const Center(child: M3ELoadingIndicator());
      }
    }
    if (detail.error != null) {
      return Center(
        child: ErrorBox(
          message: detail.error!,
          onRetry: () {
            if (item != null) state.go(Screen.detail, detail: item);
          },
        ),
      );
    }
    Widget body;
    if (detail.artist != null) {
      body = ArtistScreen(artist: detail.artist!);
    } else if (detail.album != null) {
      final album = detail.album!;
      body = AlbumPlaylistView(
        title: album.title.isNotEmpty ? album.title : (item?.title ?? 'Album'),
        subtitle: album.subtitle.isNotEmpty
            ? album.subtitle
            : (item?.subtitle ?? ''),
        description: album.description,
        art: album.artworkOr(item),
        owner: album.artist,
        tracks: album.tracks,
        numbered: true,
        isAlbum: true,
        showViews: true,
        topPadding: 16,
      );
    } else if (detail.playlist != null) {
      final pl = detail.playlist!;
      body = AlbumPlaylistView(
        title: pl.title.isNotEmpty ? pl.title : (item?.title ?? 'Playlist'),
        subtitle: pl.subtitle.isNotEmpty ? pl.subtitle : (item?.subtitle ?? ''),
        description: '',
        art: pl.artworkOr(item),
        owner: pl.author,
        tracks: pl.tracks,
        numbered: false,
        topPadding: 16,
        removable: pl.editable,
        onRemoveTrack: pl.editable && pl.id.isNotEmpty
            ? (t) async {
                final ok = await state.removeTrackFromPlaylist(pl.id, t);
                if (ok) state.reloadDetail();
              }
            : null,
      );
    } else {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(gutter),
          child: Text(
            'No details available.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }
    // Artist pages keep their own collapsing-banner app bar on every
    // layout; albums and playlists share the chrome below.
    if (detail.artist != null) return body;
    final title =
        detail.album?.title ?? detail.playlist?.title ?? item?.title ?? '';
    return Stack(
      fit: StackFit.expand,
      children: [
        if (item != null)
          RepaintBoundary(
            child: ArtworkBackdrop(
              artUrl: _artUrlFor(detail, item),
              paletteFor: state.paletteFor,
              ensurePalette: state.ensurePalette,
              tick: state.paletteTick,
            ),
          ),
        // The palette wash is the Stack's own backdrop and stays
        // full-bleed; the header and content clear the status bar.
        SafeArea(
          bottom: false,
          child: _DetailScrollFade(
            title: title,
            onBack: state.goBack,
            trailing: item != null && detail.album != null
                ? DetailMenuButton(item: item, album: detail.album!)
                : null,
            body: body,
          ),
        ),
      ],
    );
  }

  /// Cover whose palette washes the background behind an open
  /// album/playlist: the detail's own art, else the first track's
  /// cover, else the originating card's thumbnail.
  String? _artUrlFor(DetailUiState detail, BrowseItem item) {
    final covers =
        (detail.album?.tracks ?? detail.playlist?.tracks ?? const <Track>[])
            .map((t) => t.displayArtwork)
            .whereType<String>()
            .where((u) => u.isNotEmpty)
            .toSet()
            .toList();
    return detail.album?.artworkOr(item) ??
        detail.playlist?.artworkOr(item) ??
        (covers.isEmpty ? null : covers.first);
  }
}

/// Album/playlist detail body under the top bar. The page's hero card
/// shows the title at rest, so on phones the bar's title fades in only
/// once the list has scrolled ~100dp; the scroll offset reaches the
/// header through a notifier so scrolling never rebuilds the body.
class _DetailScrollFade extends StatefulWidget {
  const _DetailScrollFade({
    required this.title,
    required this.onBack,
    this.trailing,
    required this.body,
  });

  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;
  final Widget body;

  @override
  State<_DetailScrollFade> createState() => _DetailScrollFadeState();
}

class _DetailScrollFadeState extends State<_DetailScrollFade> {
  final ValueNotifier<double> _scrollPixels = ValueNotifier<double>(0);

  bool _onScroll(ScrollNotification notification) {
    final pixels = notification.metrics.pixels;
    if (pixels != _scrollPixels.value) _scrollPixels.value = pixels;
    return false;
  }

  @override
  void dispose() {
    _scrollPixels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DetailHeader(
          title: widget.title,
          onBack: widget.onBack,
          trailing: widget.trailing,
          scrollPixels: _scrollPixels,
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: widget.body,
          ),
        ),
      ],
    );
  }
}

/// Skeleton album/playlist detail: the same panel as the loaded
/// view with placeholder songs, so rows reveal in place.
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton({required this.numbered});

  final bool numbered;

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      enabled: true,
      enableSwitchAnimation: true,
      child: AlbumPlaylistView(
        title: 'Loading songs',
        subtitle: '',
        description: '',
        art: null,
        owner: null,
        tracks: placeholderTracks,
        numbered: numbered,
        isAlbum: numbered,
      ),
    );
  }
}
