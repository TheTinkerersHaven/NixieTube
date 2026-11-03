// Search screen ported from Kotlin `searchPanel`: query field, section
// filter chips, and categorized results.

import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/artwork_image.dart';
import '../widgets/rails.dart';
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

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
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
          padding: const EdgeInsets.all(screenPadding),
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
    final sections = state.search.sections;
    int count(String key) => sections[key]?.length ?? 0;
    final chips = <String, int>{
      'All': sections.values.fold(0, (n, l) => n + l.length),
      'Songs': count('Songs'),
      'Albums/EP/Singles': count('Albums/EP/Singles'),
      'Artists': count('Artists'),
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
            label: Text('$key (${chips[key]})'),
            selected: _filter == key,
            onSelected: (_) => setState(() => _filter = key),
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
    final rows = <({int kind, String? key, List<ShelfItem>? items, ShelfItem? item})>[];
    for (final key in keys) {
      rows.add((kind: 0, key: key, items: sections[key]!, item: null));
      for (final item in sections[key]!) {
        rows.add((kind: 1, key: null, items: null, item: item));
      }
      rows.add((kind: 2, key: null, items: null, item: null));
    }
    return SilkyListView.builder(
      scrollSpeed: 1.5,
      silkyScrollDuration: const Duration(milliseconds: 700),
      animationCurve: Curves.easeOutQuart,
      padding: const EdgeInsets.fromLTRB(
        screenPadding,
        0,
        screenPadding,
        screenPadding + playerBarClearance,
      ),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final r = rows[i];
        switch (r.kind) {
          case 0:
            return _sectionHeader(context, state, r.key!, r.items!);
          case 1:
            return _sectionItem(context, state, r.item!, playingId);
          default:
            return const SizedBox(height: 16);
        }
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
              onPressed: () => state.playSongs(songs, 0),
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
        b.thumbnails.isEmpty
            ? null
            : b.bestArtwork,
        size: 48,
        radius: rowArtRadius,
        iconSize: 24,
      ),
      title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(b.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  Widget _noResults(BuildContext context, AppState state) {
    return SilkyListView(
      scrollSpeed: 1.5,
      silkyScrollDuration: const Duration(milliseconds: 700),
      animationCurve: Curves.easeOutQuart,
      padding: const EdgeInsets.fromLTRB(
        screenPadding,
        screenPadding,
        screenPadding,
        screenPadding + playerBarClearance,
      ),
      children: [
        const Text('No results found'),
        const SizedBox(height: 16),
        _recentSearches(context, state),
      ],
    );
  }

  Widget _suggestions(BuildContext context, AppState state) {
    return SilkyListView(
      scrollSpeed: 1.5,
      silkyScrollDuration: const Duration(milliseconds: 700),
      animationCurve: Curves.easeOutQuart,
      padding: const EdgeInsets.fromLTRB(
        screenPadding,
        screenPadding,
        screenPadding,
        screenPadding + playerBarClearance,
      ),
      children: [
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
