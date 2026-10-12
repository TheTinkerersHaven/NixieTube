// Search screen ported from Kotlin `searchPanel`: query field, section
// filter chips, and categorized results.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

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

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      context.read<AppState>().searchFieldFocused = _focus.hasFocus;
    });
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
    state.searchFor(q);
  }

  @override
  Widget build(BuildContext context) {
    final search = context.select<AppState, SearchUiState>((s) => s.search);
    final state = context.read<AppState>();
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
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _controller.clear();
                        setState(() {});
                      },
                    ),
              border: const OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submit(state),
            onChanged: (_) => setState(() {}),
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
    if (keys.isEmpty && !search.loading) {
      return _noResults(context, state);
    }
    final playingId = state.playerState.current?.videoId;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        screenPadding,
        0,
        screenPadding,
        screenPadding + playerBarClearance,
      ),
      children: [
        for (final key in keys) ...[
          _sectionHeader(context, state, key, sections[key]!),
          for (final item in sections[key]!)
            _sectionItem(context, state, item, playingId),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  Widget _sectionHeader(
    BuildContext context,
    AppState state,
    String key,
    List<ShelfItem> items,
  ) {
    final songs = items.whereType<SongItem>().map((e) => e.track).toList();
    return Row(
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
      onTap: () => state.go(Screen.detail, detail: b),
      leading: ArtworkImage(
        b.thumbnails.isEmpty
            ? null
            : b.thumbnails.reduce((a, x) => a.width >= x.width ? a : x).url,
        size: 48,
        radius: rowArtRadius,
        iconSize: 24,
      ),
      title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(b.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  Widget _noResults(BuildContext context, AppState state) {
    return ListView(
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
    return ListView(
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
              state.searchFor(q);
            },
          ),
      ],
    );
  }
}
