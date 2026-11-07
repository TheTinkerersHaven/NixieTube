// Search state for the NixieTube app.
//
// Owns the current search query, its results and the persisted query
// history. The owning AppState notifies its listeners after every
// change.

import 'dart:async';
import 'dart:io';

import '../../core/innertube/inner_tube.dart';
import '../../core/models/models.dart';
import '../../sys/paths.dart' show configDir;

/// Stamps search sections with the locally known ratings.
typedef StampSearchSections = Map<String, List<ShelfItem>> Function(
  Map<String, List<ShelfItem>> sections,
);

/// Formats an error for display.
typedef FormatError = String Function(Object error);

/// Records the rating carried by a freshly resolved track.
typedef RecordEnrichedRating = void Function(Track track);

/// The loaded state of the search results.
class SearchUiState {
  SearchUiState({
    this.query = '',
    this.loading = false,
    this.sections = const {},
    this.error,
  });

  String query;
  bool loading;
  Map<String, List<ShelfItem>> sections;
  String? error;

  /// Creates a copy with optional overrides.
  SearchUiState copyWith({
    String? query,
    bool? loading,
    Map<String, List<ShelfItem>>? sections,
    String? error,
  }) {
    return SearchUiState(
      query: query ?? this.query,
      loading: loading ?? this.loading,
      sections: sections ?? this.sections,
      error: error,
    );
  }
}

/// Search state: the current query, its results and the query history.
class SearchState {
  /// Creates a search state.
  ///
  /// [stampSections] applies the locally known ratings to the result
  /// sections, [formatError] renders a failure for the user and
  /// [onChanged] asks the owner to notify its listeners.
  SearchState({
    required this.tube,
    required this.stampSections,
    required this.formatError,
    required this.recordEnrichedRating,
    required this.onChanged,
  });

  /// The number of queries kept in the history.
  static const historyLimit = 12;

  /// The InnerTube client used for the search requests.
  final InnerTube tube;

  /// Applies the locally known ratings to the result sections.
  final StampSearchSections stampSections;

  /// Renders a failed search for the user.
  final FormatError formatError;

  /// Records the rating carried by a freshly resolved track.
  final RecordEnrichedRating recordEnrichedRating;

  /// Asks the owner to notify its listeners after a state change.
  final void Function() onChanged;

  SearchUiState _search = SearchUiState();
  int _searchGen = 0;
  List<String> _searchHistory = [];

  /// The current search state.
  SearchUiState get search => _search;

  /// The recorded search queries, newest first.
  List<String> get searchHistory => List.unmodifiable(_searchHistory);

  /// The path of the file the search history is persisted to.
  File get _searchHistoryFile => File('${configDir().path}/search-history.txt');

  /// Reads the persisted search history into memory.
  void loadSearchHistory() {
    try {
      final f = _searchHistoryFile;
      if (!f.existsSync()) {
        _searchHistory = [];
        return;
      }
      _searchHistory = f
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toSet()
          .take(historyLimit)
          .toList();
    } catch (_) {
      _searchHistory = [];
    }
  }

  /// Records [query] in the history, newest first, and persists it.
  void recordSearchHistory(String query) {
    _searchHistory = [
      query,
      ..._searchHistory.where((q) => q.toLowerCase() != query.toLowerCase()),
    ].take(historyLimit).toList();
    unawaited(_persistSearchHistory());
  }

  /// Clears the in-memory and the persisted search history.
  void clearSearchHistory() {
    _searchHistory = [];
    unawaited(deletePersistedSearchHistory());
    onChanged();
  }

  /// Deletes the persisted search history file.
  Future<void> deletePersistedSearchHistory() async {
    try {
      final f = _searchHistoryFile;
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Drops one query from the in-memory and the persisted history.
  void removeSearchHistory(String query) {
    final key = query.trim().toLowerCase();
    if (key.isEmpty) return;
    final kept = _searchHistory.where((q) => q.toLowerCase() != key).toList();
    if (kept.length == _searchHistory.length) return;
    _searchHistory = kept;
    unawaited(_persistSearchHistory());
    onChanged();
  }

  /// Runs a search and enriches the song rows, cancelling older queries.
  Future<void> searchFor(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return;
    recordSearchHistory(normalized);
    final gen = ++_searchGen;
    _search = SearchUiState(query: normalized, loading: true);
    onChanged();
    try {
      final sections = await tube.search(normalized);
      if (gen != _searchGen) return;
      _search = SearchUiState(
        query: normalized,
        loading: false,
        sections: stampSections(sections),
      );
      onChanged();
      await _enrichSongRows(normalized, sections, gen);
    } catch (e) {
      if (gen != _searchGen) return;
      _search = SearchUiState(
        query: normalized,
        loading: false,
        error: formatError(e),
      );
      onChanged();
    }
  }

  /// Replaces the enriched song rows with their freshly resolved tracks.
  Future<void> _enrichSongRows(
    String normalized,
    Map<String, List<ShelfItem>> sections,
    int gen,
  ) async {
    final songs =
        sections['Songs']?.whereType<SongItem>().map((e) => e.track).toList() ??
        [];
    if (songs.isEmpty) return;
    final enriched = await tube.enrichTracks(songs);
    if (gen != _searchGen) return;
    final byId = {for (final t in enriched) t.videoId: t};
    final stamped = <String, List<ShelfItem>>{};
    _search.sections.forEach((key, items) {
      stamped[key] = items.map((item) {
        if (item is SongItem) {
          final fresh = byId[item.track.videoId];
          return fresh == null ? item : SongItem(fresh);
        }
        return item;
      }).toList();
    });
    _search = SearchUiState(
      query: normalized,
      loading: false,
      sections: stampSections(stamped),
    );
    for (final track in enriched) {
      recordEnrichedRating(track);
    }
    onChanged();
  }

  /// Clears the current search results and query.
  void clearSearch() {
    _search = SearchUiState();
    onChanged();
  }

  /// Replaces the result sections, keeping the current query.
  void replaceSections(Map<String, List<ShelfItem>> sections) {
    _search = SearchUiState(
      query: _search.query,
      sections: stampSections(sections),
    );
    onChanged();
  }

  Future<void> _persistSearchHistory() async {
    try {
      await _searchHistoryFile.writeAsString('${_searchHistory.join('\n')}\n');
    } catch (_) {}
  }
}
