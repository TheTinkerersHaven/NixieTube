// Desktop Now Playing view: split view with transport column on the left
// and tabs (Up next / Lyrics / Related) on the right.

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../../core/player/player_state.dart';
import '../app_state.dart';
import 'now_playing_screen.dart';

/// Desktop split view for Now Playing.
class NowPlayingDesktop extends StatelessWidget {
  const NowPlayingDesktop({
    super.key,
    required this.track,
    required this.signedIn,
    required this.libraryAvailable,
    required this.hasQueue,
    required this.sleepMode,
    required this.sleepEndsAt,
  });

  final Track track;
  final bool signedIn;
  final bool libraryAvailable;
  final bool hasQueue;
  final SleepTimerMode sleepMode;
  final int? sleepEndsAt;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
              tooltip: 'Close',
              onPressed: context.read<AppState>().closeNow,
            ),
            Expanded(
              child: Text(
                'Now playing',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            M3EPopupMenuButton<NowMenuAction>(
              tooltip: 'More actions',
              style: const M3EMenuStyle(maxWidth: 360),
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (action) =>
                  unawaited(handleNowMenu(context, action, track)),
              itemBuilder: (context) => [
                const M3EPopupMenuItem<NowMenuAction>(
                  value: NowMenuAction.shareLink,
                  child: Row(
                    children: [
                      Icon(Icons.link_rounded),
                      SizedBox(width: 12),
                      Text('Share link'),
                    ],
                  ),
                ),
                const M3EPopupMenuItem<NowMenuAction>(
                  value: NowMenuAction.openYoutube,
                  child: Row(
                    children: [
                      Icon(Icons.open_in_new_rounded),
                      SizedBox(width: 12),
                      Text('Open in YouTube'),
                    ],
                  ),
                ),
                if (signedIn && libraryAvailable)
                  M3EPopupMenuItem<NowMenuAction>(
                    onTap: () => context
                        .read<AppState>()
                        .openPlaylistDialog(track),
                    child: const Row(
                      children: [
                        Icon(Icons.playlist_add_rounded),
                        SizedBox(width: 12),
                        Text('Add to playlist'),
                      ],
                    ),
                  ),
                if (hasQueue)
                  const M3EPopupMenuItem<NowMenuAction>(
                    value: NowMenuAction.clearUpNext,
                    child: Row(
                      children: [
                        Icon(Icons.delete_sweep_outlined),
                        SizedBox(width: 12),
                        Text('Clear up next'),
                      ],
                    ),
                  ),
                M3EPopupMenuItem<NowMenuAction>(
                  value: NowMenuAction.sleepTimer,
                  child: Row(
                    children: [
                      Icon(
                        sleepMode != SleepTimerMode.off
                            ? Icons.bedtime_rounded
                            : Icons.bedtime_outlined,
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          sleepMenuLabel(sleepMode, sleepEndsAt),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final rawSize = [
                constraints.maxWidth * 0.44,
                (constraints.maxHeight - 320)
                    .clamp(180.0, double.infinity)
                    .toDouble(),
                360.0,
              ].reduce((a, b) => a < b ? a : b);
              final artSize = ((rawSize / 32).round() * 32)
                  .clamp(64, 360)
                  .toDouble();
              return Row(
                children: [
                  Expanded(
                    child: RepaintBoundary(
                      child: TransportColumn(
                        track: track,
                        artSize: artSize,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  const Expanded(
                    child: RepaintBoundary(child: TabsColumn()),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
