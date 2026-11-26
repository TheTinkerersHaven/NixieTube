// Search screen: query field, section
// filter chips, and categorized results.

import 'dart:async' show Timer, unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/artwork_image.dart';
import '../widgets/browse_menu.dart';
import '../widgets/rails.dart';
import '../widgets/screen_list.dart';
import '../widgets/track_menu_scope.dart';
import '../widgets/track_row.dart';

/// Search songs, releases and artists.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _filter = 'All';
  String _lastQuery = '';
  Timer? _suggestTimer;
  (String, Brightness)? _bestMatchColorSchemeKey;
  Future<ColorScheme?>? _bestMatchColorSchemeFuture;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _suggestTimer?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Debounced autocomplete: while typing, ask InnerTube for
  /// suggestions (what YTM shows under the search box).
  void _onQueryChanged(AppState state, String text) {
    _suggestTimer?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      state.clearSearchSuggestions();
      return;
    }
    _suggestTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(state.fetchSearchSuggestions(q));
    });
  }

  void _submit(AppState state) {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    unawaited(state.searchFor(q));
  }

  @override
  Widget build(BuildContext context) {
    final search = context.select<AppState, SearchUiState>((s) => s.search);
    // Rebuild when the history changes (add/remove/clear) so the
    // recent-searches list and its per-row delete buttons stay live.
    context.select<AppState, int>((s) => s.searchHistory.length);
    final state = context.read<AppState>();
    // The controller is local to this screen, but the query lives in
    // AppState: navigating away and back recreates the screen with an
    // empty controller while the results are still there. Keep them in
    // sync only when the AppState query actually changes, so typing in
    // the field is never clobbered by a rebuild.
    if (search.query != _lastQuery) {
      _lastQuery = search.query;
      _filter = 'All';
      if (_controller.text != search.query) {
        _controller.value = TextEditingValue(
          text: search.query,
          selection: TextSelection.collapsed(offset: search.query.length),
        );
      }
    }
    return Column(
      children: [
        Padding(
          // The top inset keeps the field below the transparent status
          // bar; the scaffold colour fills the area behind it.
          padding: EdgeInsets.only(
            left: screenPadding,
            top: screenPadding + MediaQuery.viewPaddingOf(context).top,
            right: screenPadding,
            bottom: screenPadding,
          ),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            decoration: InputDecoration(
              labelText: 'Search songs, releases, artists',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, _) => value.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Clear search',
                        onPressed: () {
                          _controller.clear();
                          state.clearSearch();
                          _focus.requestFocus();
                        },
                      ),
              ),
              border: const OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.search,
            onChanged: (v) => _onQueryChanged(state, v),
            onSubmitted: (_) => _submit(state),
          ),
        ),
        if (search.query.isNotEmpty) _filters(context, state),
        if (search.loading)
          const Padding(
            padding: EdgeInsets.all(screenPadding),
            child: M3ELoadingIndicator(),
          ),
        if (search.error != null)
          ErrorBox(
            message: search.error!,
            onRetry: () => state.searchFor(search.query),
          ),
        Expanded(child: _body(context, state)),
      ],
    );
  }

  Widget _filters(BuildContext context, AppState state) {
    // Server-side filter chips: tapping one re-runs the search with the
    // `params` token YouTube Music's own chips send, so the category is
    // ranked and complete server-side rather than carved out of the
    // "All" response client-side.
    const chips = <String, String?>{
      'All': null,
      'Songs': 'songs',
      'Albums/EP/Singles': 'albums',
      'Artists': 'artists',
    };
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: screenPadding),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemCount: chips.length,
        itemBuilder: (context, i) {
          final key = chips.keys.elementAt(i);
          return FilterChip(
            label: Text(key),
            selected: _filter == key,
            onSelected: (_) {
              if (_filter == key) return;
              setState(() => _filter = key);
              final q = state.search.query;
              if (q.isNotEmpty) {
                unawaited(state.searchFor(q, filter: chips[key]));
              }
            },
          );
        },
      ),
    );
  }

  Widget _body(BuildContext context, AppState state) {
    final search = state.search;
    if (search.query.isEmpty) {
      return _suggestions(context, state);
    }
    final sections = search.sections;
    final keys = sections.keys
        .where((k) => _filter == 'All' || _filter == k)
        .toList();
    if (_filter == 'All') {
      final q = search.query.toLowerCase();
      keys.sort((a, b) {
        bool exact(String k) {
          final lower = k.toLowerCase();
          if (lower == 'exact match' ||
              lower == 'top result' ||
              lower == 'results' ||
              lower == 'best match') {
            return true;
          }
          // An artist section whose name matches the query is an exact hit.
          if (k == 'Artists') {
            return sections[k]!.any((it) {
              if (it is BrowseItem) return it.title.toLowerCase() == q;
              return false;
            });
          }
          return false;
        }

        final ae = exact(a);
        final be = exact(b);
        if (ae != be) return ae ? -1 : 1;
        return 0;
      });
    }
    if (keys.isEmpty && !search.loading) {
      return _noResults(context, state);
    }
    final playingId = state.playerState.current?.videoId;
    // Flatten the sections into a lazy list so off-screen rows (and
    // their artwork decodes) are only built when scrolled into view.
    final rows =
        <({int kind, String? key, List<ShelfItem>? items, ShelfItem? item})>[];
    // The top-result card shelf is the best match: pin its entity as a
    // prominent card above every category on the unfiltered "All" tab.
    final best = _filter == 'All' ? search.bestMatch : null;
    if (best != null) {
      rows.add((kind: 3, key: null, items: null, item: best));
      rows.add((kind: 2, key: null, items: null, item: null));
    }
    for (final key in keys) {
      rows.add((kind: 0, key: key, items: sections[key]!, item: null));
      for (final item in sections[key]!) {
        rows.add((kind: 1, key: null, items: null, item: item));
      }
      rows.add((kind: 2, key: null, items: null, item: null));
    }
    return screenListBuilder(
      topPadding: 0,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final r = rows[i];
        switch (r.kind) {
          case 0:
            return _sectionHeader(context, state, r.key!, r.items!);
          case 1:
            return _sectionItem(context, state, r.item!, playingId);
          case 3:
            return _bestMatchCard(context, state, r.item!, playingId);
          default:
            return const SizedBox(height: 16);
        }
      },
    );
  }

  /// The best-match card: the entity of the top-result card shelf shown
  /// above all categories — big cover, title, type/artist meta, and a
  /// play affordance for songs. Tap plays a song or opens the browsable
  /// entity; press-and-hold (mobile) / right-click opens its menu.
  Widget _bestMatchCard(
    BuildContext context,
    AppState state,
    ShelfItem item,
    String? playingId,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final song = item is SongItem ? item.track : null;
    final browse = item is BrowseItem ? item : null;
    final art = song == null
        ? browse?.displayArtwork
        : state.cachedSquareCover(song.videoId) ?? song.displayArtwork;
    final title = song?.title ?? browse?.title ?? '';
    final subtitle = song != null
        ? [
            song.artistNames(),
            song.album?.name ?? '',
            if (song.durationSec > 0) formatDuration(song.durationSec),
          ].where((s) => s.trim().isNotEmpty).join(' • ')
        : (browse?.subtitle ?? '');
    final playing = song != null && song.videoId == playingId;
    final brightness = Theme.of(context).brightness;
    final Future<ColorScheme?>? colorSchemeFuture;
    if (art == null) {
      colorSchemeFuture = null;
    } else {
      final key = (art, brightness);
      if (_bestMatchColorSchemeKey != key) {
        _bestMatchColorSchemeKey = key;
        _bestMatchColorSchemeFuture = _artColorScheme(state, art, brightness);
      }
      colorSchemeFuture = _bestMatchColorSchemeFuture;
    }

    void onTap() {
      if (song != null) {
        unawaited(state.playSingle(song));
      } else if (browse != null) {
        if (browse.isPlaylist) {
          state.openPlaylistById(browse.browseId, item: browse);
        } else {
          state.go(Screen.detail, detail: browse);
        }
      }
    }

    final wrapped = song != null
        ? TrackMenuTarget(
            track: song,
            child: _bestMatchCardSurface(
              context,
              colorSchemeFuture,
              scheme,
              art,
              title,
              subtitle,
              playing,
              browse,
              song,
              onTap,
            ),
          )
        : browse != null
        ? BrowseMenuTarget(
            item: browse,
            child: _bestMatchCardSurface(
              context,
              colorSchemeFuture,
              scheme,
              art,
              title,
              subtitle,
              playing,
              browse,
              song,
              onTap,
            ),
          )
        : _bestMatchCardSurface(
            context,
            colorSchemeFuture,
            scheme,
            art,
            title,
            subtitle,
            playing,
            browse,
            song,
            onTap,
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 0),
      child: wrapped,
    );
  }

  Future<ColorScheme?> _artColorScheme(
    AppState state,
    String url,
    Brightness brightness,
  ) async {
    final file = await state.art.file(url);
    if (file == null) return null;
    return ColorScheme.fromImageProvider(
      provider: FileImage(file),
      brightness: brightness,
    );
  }

  Widget _bestMatchCardSurface(
    BuildContext context,
    Future<ColorScheme?>? colorSchemeFuture,
    ColorScheme fallbackScheme,
    String? art,
    String title,
    String subtitle,
    bool playing,
    BrowseItem? browse,
    Track? song,
    VoidCallback onTap,
  ) {
    return FutureBuilder<ColorScheme?>(
      future: colorSchemeFuture,
      builder: (context, snapshot) {
        final scheme = snapshot.data ?? fallbackScheme;
        return Material(
          color: scheme.primaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(cardRadius),
            side: BorderSide(color: scheme.primary.withValues(alpha: 0.4)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  ArtworkImage(
                    art,
                    size: 96,
                    radius: rowArtRadius,
                    circular: browse?.browseId.startsWith('UC') ?? false,
                    iconSize: 40,
                    squareCoverKey: song?.videoId,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Best match',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: playing
                                    ? scheme.primary
                                    : scheme.onPrimaryContainer,
                              ),
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: scheme.onPrimaryContainer.withValues(
                                    alpha: 0.8,
                                  ),
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (song != null)
                    IconButton(
                      icon: const Icon(Icons.play_arrow_rounded),
                      tooltip: 'Play',
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.onPrimary,
                      ),
                      onPressed: onTap,
                    )
                  else
                    Icon(
                      Icons.chevron_right_rounded,
                      color: scheme.onPrimaryContainer,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _sectionHeader(
    BuildContext context,
    AppState state,
    String key,
    List<ShelfItem> items,
  ) {
    final songs = items.whereType<SongItem>().map((e) => e.track).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(key, style: Theme.of(context).textTheme.titleLarge),
          ),
          if (songs.isNotEmpty)
            M3ETextButton(
              onPressed: () => state.playSongs(songs, 0, sourceName: 'Search'),
              child: const Text('Play all'),
            ),
        ],
      ),
    );
  }

  Widget _sectionItem(
    BuildContext context,
    AppState state,
    ShelfItem item,
    String? playingId,
  ) {
    if (item is SongItem) {
      // A tapped search result plays as its own radio station, not
      // the surrounding result list (see AppState.playSingle).
      return TrackRow(
        track: item.track,
        playing: item.track.videoId == playingId,
        onPlay: () => state.playSingle(item.track),
        rateable: true,
        showPlaylists: true,
      );
    }
    final b = item as BrowseItem;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      onTap: () {
        if (b.isPlaylist) {
          state.openPlaylistById(b.browseId, item: b);
        } else {
          state.go(Screen.detail, detail: b);
        }
      },
      leading: ArtworkImage(
        b.thumbnails.isEmpty ? null : b.bestArtwork,
        size: 48,
        radius: rowArtRadius,
        iconSize: 24,
      ),
      title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(b.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  Widget _noResults(BuildContext context, AppState state) {
    return screenList(
      children: [
        const Text('No results found'),
        const SizedBox(height: 16),
        _recentSearches(context, state),
      ],
    );
  }

  Widget _suggestions(BuildContext context, AppState state) {
    final live = context.select<AppState, List<String>>(
      (s) => s.searchSuggestions,
    );
    final typing = _controller.text.trim().isNotEmpty;
    return screenList(
      children: [
        // While typing, show InnerTube's live autocomplete above history.
        if (typing && live.isNotEmpty) ...[
          for (final s in live)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const Icon(Icons.search_rounded),
              title: Text(s, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () {
                _controller.text = s;
                _submit(state);
              },
            ),
          const SizedBox(height: 16),
        ] else if (!typing)
          const Text('Try searching for songs, artists or albums.'),
        const SizedBox(height: 16),
        _recentSearches(context, state),
      ],
    );
  }

  Widget _recentSearches(BuildContext context, AppState state) {
    if (state.searchHistory.isEmpty) {
      return const SizedBox.shrink();
    }
    // History rows (not chips): clock icon reruns the query, the X
    // drops just that entry.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Recent searches',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            M3ETextButton(
              onPressed: state.clearSearchHistory,
              child: const Text('Clear'),
            ),
          ],
        ),
        for (final q in state.searchHistory)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(
              Icons.history_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(q, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Remove',
              onPressed: () => state.removeSearchHistory(q),
            ),
            onTap: () {
              _controller.text = q;
              unawaited(state.searchFor(q));
            },
          ),
      ],
    );
  }
}
