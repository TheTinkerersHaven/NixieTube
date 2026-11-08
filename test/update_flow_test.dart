// The update banner and the App updates card share one check: tapping
// Install must land on the section with the release already in hand,
// instead of asking for a second scan.

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:nixietube/main.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/mpris.dart';
import 'package:nixietube/sys/updater.dart';
import 'package:nixietube/ui/app_state.dart';

const _info = UpdateInfo(
  version: '9.9.9',
  downloadUrl: 'https://example.com/NixieTube-x86_64.AppImage',
  body: '',
);

class _FakeUpdater extends Updater {
  _FakeUpdater(this.info);

  final UpdateInfo? info;
  int checks = 0;
  UpdateInfo? applied;

  @override
  Future<UpdateInfo?> checkForUpdates() async {
    checks++;
    return info;
  }

  @override
  Future<String?> applyUpdate(UpdateInfo info) async {
    applied = info;
    return '/tmp/NixieTube.AppImage';
  }
}

/// Boots the app shell with a fake updater and registers the usual
/// teardowns.
Future<(AppState, _FakeUpdater)> _pumpApp(WidgetTester tester) async {
  final updater = _FakeUpdater(_info);
  final state = await bootAppState(tester, tube: FakeTube(), updater: updater);
  final mpris = MprisService(controller: state.player);
  addTearDown(mpris.dispose);
  final discord = DiscordPresence();
  addTearDown(discord.dispose);
  final lastfm = LastFmService(config: state.config);
  addTearDown(lastfm.dispose);
  await tester.pumpWidget(
    NixieTubeApp(state: state, mpris: mpris, discord: discord, lastfm: lastfm),
  );
  await tester.pump();
  return (state, updater);
}

/// Taps a control through its text; M3E buttons need the position
/// rather than the widget finder.
Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.tapAt(tester.getCenter(find.text(text)));
}

void main() {
  testWidgets('Install on the banner lands on App updates without a rescan', (
    tester,
  ) async {
    final (state, updater) = await _pumpApp(tester);
    await state.checkForUpdates();
    await tester.pump();

    expect(updater.checks, 1);
    expect(find.text('Version 9.9.9 is available.'), findsOneWidget);

    await _tapText(tester, 'Install');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 500));

    expect(state.screen, Screen.settings);
    // The startup result is reused: no second scan, and the section is
    // already in view.
    expect(updater.checks, 1);
    expect(state.focusAppUpdates, isFalse);
    expect(find.text('Version 9.9.9 is available.'), findsOneWidget);
    final title = tester.getRect(find.text('App updates'));
    expect(title.top, lessThan(300));
  });

  testWidgets('The updates card only rescans when asked', (tester) async {
    final (state, updater) = await _pumpApp(tester);
    await state.checkForUpdates();
    await tester.pump();
    state.openAppUpdates();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 500));
    expect(updater.checks, 1);

    await _tapText(tester, 'Check for updates');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(updater.checks, 2);
    expect(find.text('Version 9.9.9 is available.'), findsOneWidget);
  });

  testWidgets('Install update from the card applies the release', (
    tester,
  ) async {
    final (state, updater) = await _pumpApp(tester);
    await state.checkForUpdates();
    await tester.pump();
    state.openAppUpdates();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 500));

    await _tapText(tester, 'Install update');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(updater.applied, same(_info));
    expect(
      find.text('Update installed. Restart NixieTube to use the new version.'),
      findsOneWidget,
    );
  });
}
