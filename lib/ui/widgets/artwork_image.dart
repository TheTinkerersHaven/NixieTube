// Cached artwork image with the Kotlin `Artwork(url)` semantics: square
// art fills the tile (the store pre-crops every cover to 1:1, mirroring the
// manual center-crop blit), and a missing URL renders the album placeholder
// instead of an empty box.

import 'dart:async';
import 'dart:io' show File;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';

/// Square artwork tile backed by the shared [ArtworkStore] disk cache.
/// Stateful so the backing future survives parent rebuilds.
class ArtworkImage extends StatefulWidget {
  const ArtworkImage(
    this.url, {
    super.key,
    this.size = 48,
    this.radius = cardRadius,
    this.circular = false,
    this.iconSize = 24,
  });

  final String? url;
  final double size;
  final double radius;
  final bool circular;
  final double iconSize;

  @override
  State<ArtworkImage> createState() => _ArtworkImageState();
}

class _ArtworkImageState extends State<ArtworkImage> {
  String? _loadedUrl;
  File? _file;
  Timer? _retryTimer;
  bool _retried = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeLoad();
  }

  @override
  void didUpdateWidget(ArtworkImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _retried = false;
      _retryTimer?.cancel();
      _retryTimer = null;
      _file = null;
      setState(_maybeLoad);
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  void _maybeLoad() {
    var u = widget.url;
    if (u != null && u.startsWith('//')) u = 'https:$u';
    if (u == null || u.isEmpty) {
      _loadedUrl = null;
      _file = null;
      return;
    }
    // Same URL: keep the resolved file (or the pending load). Parent
    // rebuilds must not re-run a builder per frame.
    if (u == _loadedUrl) return;
    _loadedUrl = u;
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
              return;
            }
            setState(() => _file = f);
          },
          onError: (_) {
            // A failed load behaves like a missing file: placeholder now,
            // one delayed retry (see _maybeRetry).
            if (!mounted || _loadedUrl != u) return;
            _maybeRetry();
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
      setState(_maybeLoad);
    });
  }

  @override
  Widget build(BuildContext context) {
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
    if (file == null) return frame(placeholder());
    return frame(
      Image.file(
        file,
        width: widget.size,
        height: widget.size,
        // Decode at display size: a 48px row must not decode 540px.
        cacheWidth: widget.size.toInt().clamp(1, 1 << 15),
        cacheHeight: widget.size.toInt().clamp(1, 1 << 15),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, _, _) => placeholder(),
      ),
    );
  }
}
