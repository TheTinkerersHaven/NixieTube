// Cached artwork image tile: the store renders covers whole (no
// client-side crop, no bar trimming) and the tile cover-fits them into
// its square box, and a missing URL renders the album placeholder
// instead of an empty box.

import 'dart:async';
import 'dart:io' show File;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/artwork/artwork_store.dart';
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
/// Music videos have no square art anywhere, so when the resolution
/// settles empty the tile falls back to the frame itself (cover-fit).
class ArtworkImage extends StatefulWidget {
  const ArtworkImage(
    this.url, {
    super.key,
    this.size = 48,
    this.radius = cardRadius,
    this.circular = false,
    this.iconSize = 24,
    this.squareCoverKey,
    this.expand = false,
  });

  final String? url;
  final double size;
  final double radius;
  final bool circular;
  final double iconSize;

  /// `videoId` used to resolve a square cover for non-square art.
  final String? squareCoverKey;

  /// When true the tile fills its parent constraints instead of using
  /// the fixed [size] (used by variable-size square tiles such as the
  /// quick-pick grid), while [size] still drives the decode width.
  final bool expand;

  @override
  State<ArtworkImage> createState() => _ArtworkImageState();
}

class _ArtworkImageState extends State<ArtworkImage> {
  String? _loadedUrl;
  File? _file;

  /// Pixel size of the stored file ([ArtworkStore.tileSize]), read
  /// before the [Image] mounts so its decode can be sized to the box.
  /// Null until resolved (or when the header is not understood, in
  /// which case the decode stays unbounded — never upscaled).
  (int, int)? _tileSize;
  Timer? _retryTimer;
  bool _retried = false;
  bool _failed = false;

  /// Square-cover wait this tile is parked on (video id), or null.
  /// While parked the tile bones instead of loading a cropped frame;
  /// cleared when the cover lands or the key changes.
  String? _waitingSquareKey;

  /// Square-cover fallback already decided (video id): the resolution
  /// settled with no square art, so this tile shows the raw frame
  /// itself — the square box cover-fits it — instead of parking on a
  /// blank album icon forever. Reset by a new key/URL or a cache clear.
  String? _frameKey;

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
      _tileSize = null;
      _loadedUrl = null;
      _failed = false;
      _waitingSquareKey = null;
      _frameKey = null;
    }
    _maybeLoad();
  }

  @override
  void didUpdateWidget(ArtworkImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.squareCoverKey != widget.squareCoverKey) {
      _retried = false;
      _retryTimer?.cancel();
      _retryTimer = null;
      _waitingSquareKey = null;
      _frameKey = null;
      // The raw frame often swaps under enrichment while the displayed
      // (square) cover stays put: only blank the tile when the
      // effective artwork actually changed. Otherwise _maybeLoad
      // early-returns on the unchanged URL and the tile would shimmer
      // forever with nothing left to load.
      if (_effectiveUrl() != _loadedUrl) {
        _file = null;
        _tileSize = null;
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
  /// cached. While the resolution is in flight a recognizably
  /// non-square frame is held back — true square art must never be
  /// replaced by a client-side crop — and the tile bones until it
  /// lands. When the resolution settles with no square art at all, the
  /// frame is shown itself; the square box cover-fits it.
  String? _effectiveUrl() {
    var u = widget.url;
    if (u != null && u.startsWith('//')) u = 'https:$u';
    final key = widget.squareCoverKey;
    if (key != null && key.isNotEmpty && u != null && u.isNotEmpty) {
      final state = context.read<AppState>();
      final cover = state.cachedSquareCover(key);
      if (cover != null && cover.isNotEmpty) return cover;
      if (_frameKey != key) {
        unawaited(state.ensureSquareCover(key));
        if (_isNonSquareFrame(u)) return null;
      }
    }
    return (u == null || u.isEmpty) ? null : u;
  }

  /// True when [url] is recognizably a non-square frame: a Google
  /// `=w{W}-h{H}` size suffix with unequal sides, or an `i.ytimg.com`
  /// video still (never square). Anything else loads as before — only
  /// proven frames wait for the true square cover.
  bool _isNonSquareFrame(String url) {
    final m = RegExp(r'=w(\d+)-h(\d+)').firstMatch(url);
    if (m != null) return m.group(1) != m.group(2);
    return url.contains('i.ytimg.com/vi/');
  }

  /// The artwork store behind every load.
  ArtworkStore get _art => context.read<AppState>().art;

  /// The cover image decoded for [box] logical pixels of painted width
  /// (the tile's own size, or the expand tile's parent cell).
  Widget _coverImage(File file, double box) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final needed = (box > 0 ? box : widget.size).clamp(1.0, 4096.0);
    // Decode at the painted box in physical pixels: the smallest
    // bitmap whose short side still covers the box under BoxFit.cover,
    // so no upscaling happens on screen. No headroom factor: the
    // filter quality (high) handles sub-pixel softness and the source's
    // own resolution caps the result via allowUpscaling: false.
    // Small headroom (1.5x) over the bare device-pixel box:
    // rounding and the codec's internal resampling can leave the
    // short side a hair under the box, and decoding a bit above the
    // target lets FilterQuality.medium do the final reduction, which
    // reads sharper than a single decode-to-target step. Capped at
    // the source size via allowUpscaling: false, so small files lose
    // nothing.
    final devicePx = (needed * dpr * 3 / 2).ceil();
    final ImageProvider provider;
    if (_tileSize != null) {
      final (tw, th) = _tileSize!;
      final width = (tw >= th)
          ? (devicePx * tw / th).round().clamp(1, tw)
          : devicePx.clamp(1, tw);
      provider = ResizeImage(
        FileImage(file),
        width: width,
        allowUpscaling: false,
      );
    } else {
      provider = FileImage(file);
    }
    // The frame's SizedBox.expand keeps the child bounding regardless
    // of the decoded bitmap's aspect.
    return SizedBox.expand(
      child: Image(
        image: provider,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(Theme.of(context).colorScheme),
      ),
    );
  }

  void _maybeLoad() {
    // Same URL: keep the resolved file (or the pending load). Parent
    // rebuilds must not re-run a builder per frame.
    final u = _effectiveUrl();
    if (u == null) {
      _loadedUrl = null;
      _file = null;
      final key = widget.squareCoverKey;
      final raw = widget.url;
      final squareWait =
          key != null &&
          key.isNotEmpty &&
          raw != null &&
          _isNonSquareFrame(raw);
      _failed = false;
      // Square-cover wait (non-square frame held back above): when the
      // resolution settles empty, fall back to the frame itself rather
      // than blanking the tile for the rest of the session.
      if (squareWait && _waitingSquareKey != key) {
        // `squareWait` already implies a non-null key.
        final kid = key;
        _waitingSquareKey = kid;
        final state = context.read<AppState>();
        unawaited(
          state.ensureSquareCover(kid).then((_) {
            if (!mounted || _waitingSquareKey != kid) return;
            _waitingSquareKey = null;
            final cover = state.cachedSquareCover(kid);
            if (cover == null || cover.isEmpty) {
              // No square art exists for this video — a music video's
              // only art is its 16:9 still: show the frame. The square
              // box cover-fits it (sides cut, never stretched or
              // barred), so the tile gets a real cover instead of a
              // blank album icon.
              _frameKey = kid;
              setState(_maybeLoad);
            }
          }),
        );
      }
      return;
    }
    _waitingSquareKey = null;
    if (u == _loadedUrl) return;
    _loadedUrl = u;
    _failed = false;
    unawaited(
      context
          .read<AppState>()
          .art
          .file(u)
          .then(
            (f) => _onRender(u, f),
            onError: (_) {
              // A failed load behaves like a missing file: placeholder now,
              // one delayed retry (see _maybeRetry).
              if (!mounted || _loadedUrl != u) return;
              _maybeRetry();
              setState(() => _failed = true);
            },
          ),
    );
  }

  /// Shows the resolved file for [u] with a decode sized to the box:
  /// the pixel size is read first (a cheap header read) so the very
  /// first decode is already bounded — a full-res decode would cache,
  /// upload and rasterize 4.6 MB of bitmap for a tile a few hundred
  /// pixels wide. When the header is not understood the tile falls
  /// back to the unbounded decode rather than risk upscaling.
  Future<void> _onRender(String u, File? f) async {
    if (!mounted || _loadedUrl != u) return;
    final dims = f == null ? null : await _art.tileSize(u);
    if (!mounted || _loadedUrl != u) return;
    if (f == null) {
      _maybeRetry();
      // Rebuild to the static placeholder now: without this the tile
      // would keep shimmering until an unrelated rebuild (or the delayed
      // retry) swaps it out.
      setState(() => _failed = true);
      return;
    }
    setState(() {
      _file = f;
      _tileSize = dims;
    });
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

  /// The static album-icon placeholder for a missing/failed tile.
  Widget _placeholder(ColorScheme scheme) => widget.expand
      ? SizedBox.expand(
          child: Container(
            color: scheme.surfaceContainerHigh,
            child: Icon(
              Icons.album_rounded,
              size: widget.iconSize,
              color: scheme.onSurfaceVariant,
            ),
          ),
        )
      : Container(
          width: widget.size,
          height: widget.size,
          color: scheme.surfaceContainerHigh,
          child: Icon(
            Icons.album_rounded,
            size: widget.iconSize,
            color: scheme.onSurfaceVariant,
          ),
        );

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
    Widget frame(Widget child) => widget.circular
        ? ClipOval(
            child: widget.expand
                ? SizedBox.expand(child: child)
                : SizedBox(
                    width: widget.size,
                    height: widget.size,
                    child: child,
                  ),
          )
        : ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: widget.expand
                ? SizedBox.expand(child: child)
                : SizedBox(
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
      // Decode only what the box shows: the bitmap's short side at the
      // box's device pixels, the long side scaled along to keep the
      // aspect (a 16:9 still decodes at width×aspect so its height
      // still reaches the box), never beyond the file's own pixels —
      // `allowUpscaling: false` clamps a target above the source to a
      // natural-size decode, so nothing is invented. The target reads
      // the PAINTED box, not the size prop: expand tiles fill their
      // parent's cell, which can be either side of `size` — a target
      // below the painted box upscales on screen and reads soft.
      child = widget.expand
          ? LayoutBuilder(
              builder: (context, constraints) =>
                  _coverImage(file, constraints.maxWidth),
            )
          : _coverImage(file, widget.size);
    } else if (_failed || (!hasUrl && !ancestorLoading)) {
      // Settled without art (or a failed load): the static album icon.
      child = _placeholder(scheme);
    } else {
      // Art on its way: one bone for the whole tile. Skeletonizer only
      // ever bones text and icons, so the Container+Icon placeholder
      // above would paint a flat box with a lone shimmering glyph; the
      // Bone paints the shimmer across the full tile while any skeleton
      // scope (this tile's or an ancestor's) is enabled.
      child = widget.expand
          ? SizedBox.expand(child: Bone.square(size: widget.size))
          : Bone.square(size: widget.size);
    }
    final result = Skeletonizer(
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
    return widget.expand ? SizedBox.expand(child: result) : result;
  }
}
