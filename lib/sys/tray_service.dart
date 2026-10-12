// System tray integration (desktop): tray icon with transport
// controls, window show/hide on click, and quit. The window close
// button hides to the tray instead of quitting; Quit lives in the
// tray menu (and MPRIS) so playback survives closing the window.
//
// Resource-light by design: the cookie icon re-renders only when
// the theme colors move, and the Play label plus tooltip update only
// when the track or play state changes — never on progress ticks.
// Controller calls are safe no-ops without a loaded track, so menu
// items stay live instead of churning enabled states.

import 'dart:async';
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart' show Color, ColorScheme;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/models/models.dart';
import '../core/player/player_controller.dart';
import '../core/player/player_state.dart';
import '../ui/theme.dart' show buildTheme;
import 'tray_icon.dart' show renderTrayIcon;

/// Play/Pause menu label for [playing].
String trayPlayPauseLabel(bool playing) => playing ? 'Pause' : 'Play';

/// Tooltip for [track] (`Title — artists`), or the app name.
String trayTooltipFor(Track? track) {
  if (track == null) return 'NixieTube';
  final artists = track.artistNames().trim();
  if (artists.isEmpty) return track.title;
  return '${track.title} — $artists';
}

/// Menu refresh identity: track, title, or play state changed.
/// Position-only ticks map to the same key, so nothing native is
/// touched for progress.
class TrayMenuKey {
  const TrayMenuKey({
    required this.playing,
    required this.videoId,
    required this.title,
  });

  factory TrayMenuKey.of(PlayerState s) => TrayMenuKey(
    playing: s.playing,
    videoId: s.current?.videoId,
    title: s.current?.title,
  );

  final bool playing;
  final String? videoId;
  final String? title;

  @override
  bool operator ==(Object other) =>
      other is TrayMenuKey &&
      other.playing == playing &&
      other.videoId == videoId &&
      other.title == title;

  @override
  int get hashCode => Object.hash(playing, videoId, title);
}

/// System tray integration: transport menu, show/hide and quit,
/// driven by player states. Construct, then [start]; [dispose]
/// tears everything down. All native calls are best-effort so the
/// tray can never break startup.
class TrayService with WindowListener {
  TrayService({
    required PlayerController controller,
    required Future<void> Function() onQuit,
    required ValueListenable<ColorScheme?> scheme,
  }) {
    _controller = controller;
    _onQuit = onQuit;
    _scheme = scheme;
  }

  late final PlayerController _controller;
  late final Future<void> Function() _onQuit;
  late final ValueListenable<ColorScheme?> _scheme;

  StreamSubscription<PlayerState>? _sub;
  TrayIcon? _icon;
  Menu? _menu;
  MenuItem? _playPauseItem;
  ListenerId? _iconListenerId;
  final Map<MenuItem, ListenerId> _itemListeners = {};
  TrayMenuKey? _lastKey;
  Color? _lastIconBg;
  Color? _lastIconFg;
  bool _started = false;

  /// Renders the cookie icon for [scheme] (tray + window icon),
  /// skipping redundant native sets when the colors didn't move.
  /// Rendered large: the compositor downscales for the tray while
  /// the window icon stays sharp.
  Future<void> _renderIcon(ColorScheme scheme) async {
    if (scheme.primary == _lastIconBg &&
        scheme.onPrimary == _lastIconFg &&
        _icon != null) {
      return;
    }
    _lastIconBg = scheme.primary;
    _lastIconFg = scheme.onPrimary;
    try {
      final bytes = await renderTrayIcon(
        background: scheme.primary,
        foreground: scheme.onPrimary,
        size: 256,
      );
      final file = File('${Directory.systemTemp.path}/nixietube/tray-icon.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      final art = Image.fromFile(file.path);
      _icon?.icon = art;
      await windowManager.setIcon(file.path);
    } catch (_) {}
  }

  /// Current scheme, falling back to the built-in one before the
  /// themed shell publishes (matches MaterialApp's own fallback).
  ColorScheme get _effectiveScheme => _scheme.value ?? buildTheme().colorScheme;

  Future<void> start() async {
    if (_started) return;
    if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      return;
    }
    _started = true;
    try {
      if (!TrayManager.instance.isSupported()) return;
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      final icon = TrayIcon.create();
      if (icon == null) return;
      _icon = icon;
      await _renderIcon(_effectiveScheme);
      icon.setTooltip('NixieTube');
      icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      final menu = Menu.create();
      if (menu == null) return;
      _menu = menu;
      MenuItem? add(String label, void Function() action) {
        final item = MenuItem.createWithLabelAndType(
          label,
          MenuItemType.normal,
        );
        if (item == null) return null;
        menu.addItem(item);
        _itemListeners[item] = item.addListener((event) {
          if (event is MenuItemClickedEvent && event.itemId == item.id) {
            action();
          }
        });
        return item;
      }

      _playPauseItem = add('Play', () => _controller.togglePlayPause());
      add('Previous', () => _controller.previous());
      add('Next', () => _controller.next());
      menu.addSeparator();
      add('Show / Hide', () => toggleWindow());
      add('Quit', () => _onQuit());
      icon.setContextMenu(menu);
      _iconListenerId = icon.addListener((event) {
        switch (event) {
          case TrayIconClickedEvent():
            toggleWindow();
          case TrayIconRightClickedEvent():
            icon.openContextMenu();
          case TrayIconDoubleClickedEvent():
            break;
        }
      });
      windowManager.addListener(this);
      _scheme.addListener(_onScheme);
      _sub = _controller.states.listen(_onState);
      _onState(_controller.state);
    } catch (_) {
      // Best-effort: the tray must never break startup.
    }
  }

  void _onScheme() {
    unawaited(_renderIcon(_effectiveScheme));
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    try {
      _scheme.removeListener(_onScheme);
      windowManager.removeListener(this);
      final icon = _icon;
      if (icon != null) {
        if (_iconListenerId != null) {
          icon.removeListener(_iconListenerId!);
        }
        icon.setContextMenu(null);
        icon.dispose();
      }
      for (final entry in _itemListeners.entries) {
        try {
          entry.key.removeListener(entry.value);
        } catch (_) {}
        try {
          entry.key.dispose();
        } catch (_) {}
      }
      _itemListeners.clear();
      _menu?.dispose();
    } catch (_) {}
    _icon = null;
    _menu = null;
    _playPauseItem = null;
  }

  void _onState(PlayerState s) {
    final key = TrayMenuKey.of(s);
    if (key == _lastKey) return;
    _lastKey = key;
    try {
      _playPauseItem?.label = trayPlayPauseLabel(key.playing);
      _icon?.setTooltip(trayTooltipFor(s.current));
    } catch (_) {}
  }

  /// Shows the window when hidden, hides it when visible.
  Future<void> toggleWindow() async {
    try {
      if (await windowManager.isVisible()) {
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    } catch (_) {}
  }

  @override
  void onWindowClose() {
    // Close hides to the tray; Quit stays in the tray menu.
    unawaited(windowManager.hide());
  }
}
