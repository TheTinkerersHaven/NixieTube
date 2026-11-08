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
import 'dart:io' show File, Platform;

import 'paths.dart' show cacheDir;
import 'log.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart' show Color, ColorScheme;
import 'package:nativeapi/nativeapi.dart'
    show
        Application,
        ListenerId,
        Window,
        WindowCloseRequestedEvent,
        WindowEvent;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart' show WindowManager;

import '../core/models/models.dart';
import '../core/player/player_controller.dart';
import '../core/player/player_state.dart';
import '../ui/theme.dart' show buildTheme;
import 'tray_icon.dart' show renderTrayIcon;
import 'updater.dart' show Updater;

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
const _log = TaggedLog('tray');

class TrayService {
  TrayService({
    required PlayerController controller,
    required Future<void> Function() onQuit,
    required ValueListenable<ColorScheme?> scheme,
    Updater? updater,
  }) {
    _controller = controller;
    _onQuit = onQuit;
    _scheme = scheme;
    _updater = updater ?? Updater();
  }

  late final PlayerController _controller;
  late final Future<void> Function() _onQuit;
  late final ValueListenable<ColorScheme?> _scheme;
  late final Updater _updater;

  StreamSubscription<PlayerState>? _sub;
  TrayIcon? _icon;
  Menu? _menu;
  MenuItem? _playPauseItem;
  ListenerId? _iconListenerId;
  Window? _window;
  ListenerId? _windowListenerId;
  final Map<MenuItem, ListenerId> _itemListeners = {};
  TrayMenuKey? _lastKey;
  Color? _lastIconBg;
  Color? _lastIconFg;
  bool? _lastIconPlaying;
  bool _started = false;

  /// Renders the cookie icon for [scheme] (tray + window icon),
  /// skipping redundant native sets when neither the colors nor the
  /// transport state moved. Rendered large: the compositor downscales
  /// for the tray while the window icon stays sharp.
  Future<void> _renderIcon(ColorScheme scheme, {required bool playing}) async {
    if (scheme.primary == _lastIconBg &&
        scheme.onPrimary == _lastIconFg &&
        playing == _lastIconPlaying &&
        _icon != null) {
      return;
    }
    _lastIconBg = scheme.primary;
    _lastIconFg = scheme.onPrimary;
    _lastIconPlaying = playing;
    _log.d(
      '[tray] rendering icon primary=#${scheme.primary.toARGB32().toRadixString(16).padLeft(8, '0')} playing=$playing',
    );
    try {
      final bytes = await renderTrayIcon(
        background: scheme.primary,
        foreground: scheme.onPrimary,
        playing: playing,
        size: 256,
      );
      final file = File('${cacheDir().path}/tray-icon.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      final art = Image.fromFile(file.path);
      _icon?.icon = art;
      Application.instance.setIcon(file.path);
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
      final icon = TrayIcon.create();
      if (icon == null) return;
      _icon = icon;
      await _renderIcon(_effectiveScheme, playing: _controller.state.playing);
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
      add('Check for updates', () => unawaited(_checkForUpdates()));
      add('Show / Hide', () => toggleWindow());
      add('Quit', () => _onQuit());
      icon.setContextMenu(menu);
      _iconListenerId = icon.addListener((event) {
        switch (event) {
          case TrayIconClickedEvent():
            unawaited(toggleWindow());
          case TrayIconRightClickedEvent():
            icon.openContextMenu();
          case TrayIconDoubleClickedEvent():
            break;
        }
      });
      final window = WindowManager.instance.getCurrent();
      if (window != null) {
        _window = window;
        _windowListenerId = window.addListener(_onWindowEvent);
      }
      _scheme.addListener(_onScheme);
      _sub = _controller.states.listen(_onState);
      _onState(_controller.state);
    } catch (_) {
      // Best-effort: the tray must never break startup.
    }
  }

  void _onScheme() {
    unawaited(
      _renderIcon(_effectiveScheme, playing: _controller.state.playing),
    );
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    try {
      _scheme.removeListener(_onScheme);
      final listenerId = _windowListenerId;
      final window = _window;
      if (window != null && listenerId != null) {
        window.removeListener(listenerId);
      }
      _windowListenerId = null;
      _window = null;
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
    final playingFlipped = _lastKey != null && key.playing != _lastKey!.playing;
    _lastKey = key;
    try {
      _playPauseItem?.label = trayPlayPauseLabel(key.playing);
      // Some hosts snapshot the menu at open time: re-setting it
      // pushes the flipped Play/Pause label through. Only on flips,
      // so an open menu never flickers on track-only changes.
      if (playingFlipped) {
        final icon = _icon;
        final menu = _menu;
        if (icon != null && menu != null) icon.setContextMenu(menu);
      }
      _icon?.setTooltip(trayTooltipFor(s.current));
    } catch (_) {}
    // The center glyph mirrors the transport state; the dedupe
    // inside skips track-only changes.
    unawaited(_renderIcon(_effectiveScheme, playing: key.playing));
  }

  /// Shows the window when hidden, hides it when visible.
  Future<void> toggleWindow() async {
    try {
      final window = _window;
      if (window == null) return;
      if (window.isVisible) {
        window.hide();
      } else {
        window.show();
        window.focus();
      }
    } catch (_) {}
  }

  /// Close hides to the tray; Quit stays in the tray menu.
  void _onWindowEvent(WindowEvent event) {
    if (event is WindowCloseRequestedEvent) {
      event.request.cancel();
      _window?.hide();
    }
  }

  /// Checks GitHub for a newer release and, if found, downloads and
  /// atomically replaces the running AppImage. Silent on outcome — the
  /// update takes effect on the next launch. Best-effort: a failure is
  /// logged and the tray keeps working.
  Future<void> _checkForUpdates() async {
    final info = await _updater.checkForUpdates();
    if (info == null) return;
    await _updater.applyUpdate(info);
  }
}
