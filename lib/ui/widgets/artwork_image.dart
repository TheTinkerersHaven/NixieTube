// Cached artwork image with the Kotlin `Artwork(url)` semantics: square
// art fills the tile (the store pre-crops every cover to 1:1, mirroring the
// manual center-crop blit), and a missing URL renders the album placeholder
// instead of an empty box.

import 'dart:async';
import 'dart:io' show File;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../app_state.dart';
import '../theme.dart';

/// Square artwork tile backed by the shared [ArtworkStore] disk cache.
/// Stateful so the backing future survives parent rebuilds.
///
/// When [squareCoverKey] is given (a `videoId`), a non-square frame is
/// swapped for the track's resolved square cover: the cover is looked up in
/// the disk-backed square-cover cache and, on a miss, resolved in the
/// background — the tile rebuilds via [AppState.squareCoverTick] when it
/// lands, so lists can show the same square album art the player does.
class ArtworkImage extends StatefulWidget {
  const ArtworkImage(
    this.url, {
    super.key,
    this.size = 48,
    this.radius = cardRadius,
    this.circular = false,
    this.iconSize = 24,
    this.squareCoverKey,
  });

  final String? url;
  final double size;
  final double radius;
  final bool circular;
  final double iconSize;

  /// `videoId` used to resolve a square cover for non-square art.
  final String? squareCoverKey;

  @override
  State<ArtworkImage> createState() => _ArtworkImageState();
}

class _ArtworkImageState extends State<ArtworkImage> {
  String? _loadedUrl;
  File? _file;
  Timer? _retryTimer;
  bool _retried = false;
  bool _failed = false;

  /// Last-seen artwork-cache generation; bumped by the Settings "Clear
  /// artwork cache" action to force every tile to re-fetch.
  int _lastCacheTick = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // context.select is only legal inside build; the build select on
    // artworkCacheTick subscribes this tile, so on a cache clear this
    // method fires again and the bumped generation forces a re-fetch.
    final tick = context.read<AppState>().artworkCacheTick.value;
    if (tick != _lastCacheTick) {
      _lastCacheTick = tick;
      _retried = false;
      _retryTimer?.cancel();
      _retryTimer = null;
      _file = null;
      _loadedUrl = null;
      _failed = false;
    }
    _maybeLoad();
  }

  @override
  void didUpdateWidget(ArtworkImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url ||
        old.squareCoverKey != widget.squareCoverKey) {
      _retried = false;
      _retryTimer?.cancel();
      _retryTimer = null;
      // The raw frame often swaps under enrichment while the displayed
      // (square) cover stays put: only blank the tile when the
      // effective artwork actually changed. Otherwise _maybeLoad
      // early-returns on the unchanged URL and the tile would shimmer
      // forever with nothing left to load.
      if (_effectiveUrl() != _loadedUrl) {
        _file = null;
        setState(_maybeLoad);
      }
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  /// The artwork URL this tile displays: the frame URL (with the
  /// `//` scheme fixed), swapped for the track's resolved square cover
  /// when this tile opted into square-cover resolution and one is
  /// cached. On a cache miss the resolution is kicked off; the build's
  /// squareCoverTick select rebuilds this tile when it lands.
  String? _effectiveUrl() {
    var u = widget.url;
    if (u != null && u.startsWith('//')) u = 'https:$u';
    final key = widget.squareCoverKey;
    if (key != null && key.isNotEmpty && u != null && u.isNotEmpty) {
      final state = context.read<AppState>();
      final cover = state.cachedSquareCover(key);
      if (cover != null && cover.isNotEmpty) return cover;
      state.ensureSquareCover(key);
    }
    return (u == null || u.isEmpty) ? null : u;
  }

  void _maybeLoad() {
    // Same URL: keep the resolved file (or the pending load). Parent
    // rebuilds must not re-run a builder per frame.
    final u = _effectiveUrl();
    if (u == null) {
      _loadedUrl = null;
      _file = null;
      _failed = false;
      return;
    }
    if (u == _loadedUrl) return;
    _loadedUrl = u;
    _failed = false;
    // ignore: discarded_futures
    context
        .read<AppState>()
        .art
        .file(u)
        .then(
          (f) {
            if (!mounted || _loadedUrl != u) return;
            if (f == null) {
              _maybeRetry();
              // Rebuild to the static placeholder now: without this
              // the tile would keep shimmering until an unrelated
              // rebuild (or the delayed retry) swaps it out.
              setState(() => _failed = true);
              return;
            }
            setState(() => _file = f);
          },
          onError: (_) {
            // A failed load behaves like a missing file: placeholder now,
            // one delayed retry (see _maybeRetry).
            if (!mounted || _loadedUrl != u) return;
            _maybeRetry();
            setState(() => _failed = true);
          },
        );
  }

  /// One delayed retry when resolution yields nothing: a flaky boot-time
  /// download must not leave a permanent placeholder.
  void _maybeRetry() {
    if (_retried) return;
    final u = widget.url;
    if (u == null || u.isEmpty || _retryTimer != null) return;
    _retried = true;
    _retryTimer = Timer(const Duration(seconds: 5), () {
      _retryTimer = null;
      if (!mounted) return;
      _loadedUrl = null;
      _failed = false;
      setState(_maybeLoad);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Every tile subscribes to the artwork-cache generation: when the
    // Settings "Clear artwork cache" action bumps it, didChangeDependencies
    // fires and this tile re-fetches its cover.
    context.select<AppState, int>((s) => s.artworkCacheTick.value);
    // Tiles that opted into square-cover resolution subscribe too; when a
    // cover resolves (squareCoverTick bumps), didChangeDependencies fires
    // and _maybeLoad swaps the frame for the square cover.
    if (widget.squareCoverKey != null) {
      context.select<AppState, int>((s) => s.squareCoverTick.value);
    }
    final scheme = Theme.of(context).colorScheme;
    Widget placeholder() => Container(
      width: widget.size,
      height: widget.size,
      color: scheme.surfaceContainerHigh,
      child: Icon(
        Icons.album_rounded,
        size: widget.iconSize,
        color: scheme.onSurfaceVariant,
      ),
    );
    Widget frame(Widget child) => widget.circular
        ? ClipOval(
            child: SizedBox(
              width: widget.size,
              height: widget.size,
              child: child,
            ),
          )
        : ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: SizedBox(
              width: widget.size,
              height: widget.size,
              child: child,
            ),
          );
    final file = _file;
    // Per-item skeleton: the tile keeps shimmering until ITS OWN image is
    // loaded, even after the parent loading skeleton turns off — so
    // artwork never pops in later. Tiles without a URL, or whose load
    // failed, render their placeholder normally.
    final hasUrl = widget.url != null && widget.url!.trim().isNotEmpty;
    final skeleton = hasUrl && file == null && !_failed;
    // An enabled ancestor loading scope (home feed, quick-picks grid)
    // also means "art on its way" for URL-less placeholder tracks.
    final ancestorLoading =
        context
            .dependOnInheritedWidgetOfExactType<SkeletonizerScope>()
            ?.enabled ??
        false;
    Widget child;
    if (file != null) {
      child = Image.file(
        file,
        width: widget.size,
        height: widget.size,
        // Decode at display size: a 48px row must not decode 540px.
        cacheWidth: widget.size.toInt().clamp(1, 1 << 15),
        cacheHeight: widget.size.toInt().clamp(1, 1 << 15),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, _, _) => placeholder(),
      );
    } else if (_failed || (!hasUrl && !ancestorLoading)) {
      // Settled without art (or a failed load): the static album icon.
      child = placeholder();
    } else {
      // Art on its way: one bone for the whole tile. Skeletonizer only
      // ever bones text and icons, so the Container+Icon placeholder
      // above would paint a flat box with a lone shimmering glyph; the
      // Bone paints the shimmer across the full tile while any skeleton
      // scope (this tile's or an ancestor's) is enabled.
      child = Bone.square(size: widget.size);
    }
    return Skeletonizer(
      enabled: skeleton,
      // Late cover swaps (frame → resolved square art) crossfade
      // instead of popping: the switcher keys on the backing file.
      child: frame(
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: KeyedSubtree(
            key: ValueKey(_file?.path ?? 'art-pending'),
            child: child,
          ),
        ),
      ),
    );
  }
}
