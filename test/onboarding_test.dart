// The first-run setup: it shows on the first start, walks through
// welcome, sign-in and personalization, and is skipped for good once
// the user is through it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/auth_session.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/mpris.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/onboarding_screen.dart';
import 'package:nixietube/ui/screens/settings_screen.dart';

Future<AppState> _boot() async {
  final dir = Directory.systemTemp.createTempSync('nt-onboarding');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube();
  addTearDown(tube.close);
  final player = PlayerController(engine: FakeEngine(), tube: tube);
  addTearDown(player.dispose);
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    config: SysConfig(configPath: '${dir.path}/config.properties'),
    openUrl: (_) async {},
  );
  addTearDown(state.dispose);
  // The session is read asynchronously at startup; the setup waits for
  // it before deciding.
  await state.loadAuth();
  return state;
}

Future<void> _pump(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: OnboardingScreen())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('walks through the steps and finishes', (tester) async {
    final state = await _boot();
    // A fresh install has to go through the setup.
    expect(state.needsOnboarding, isTrue);

    await _pump(tester, state);
    expect(find.text('Welcome to NixieTube'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.text('Next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Sign in to your account'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.text('Next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Make it yours'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.text('Start listening')));
    await tester.pump();
    expect(state.needsOnboarding, isFalse);
  });

  testWidgets('skipping ends the setup too', (tester) async {
    final state = await _boot();
    await _pump(tester, state);

    await tester.tapAt(tester.getCenter(find.text('Skip setup')));
    await tester.pump();
    expect(state.needsOnboarding, isFalse);
  });

  test('a signed-in account has nothing to set up', () async {
    final state = await _boot();
    // An account that is already signed in never sees the setup.
    state.tube.auth = const AuthSession(cookie: 'SAPISID=abc');
    expect(state.hasCookieSession, isTrue);
    expect(state.needsOnboarding, isFalse);
  });

  test('the setup can be run again on request', () async {
    final state = await _boot();
    // A signed-in account is done with the setup...
    state.tube.auth = const AuthSession(cookie: 'SAPISID=abc');
    state.completeOnboarding();
    expect(state.needsOnboarding, isFalse);

    // ...but it can be put back for a walkthrough.
    state.restartOnboarding();
    expect(state.needsOnboarding, isTrue);
    state.completeOnboarding();
    expect(state.needsOnboarding, isFalse);
  });

  testWidgets('the settings offer the setup again', (tester) async {
    // A tall window: the settings list is long and the section sits at
    // the bottom.
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final dir = Directory.systemTemp.createTempSync('nt-onb-settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = InnerTube();
    addTearDown(tube.close);
    final player = PlayerController(engine: FakeEngine(), tube: tube);
    addTearDown(player.dispose);
    final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
    addTearDown(art.close);
    final state = AppState(
      tube: tube,
      player: player,
      art: art,
      config: SysConfig(configPath: '${dir.path}/config.properties'),
      openUrl: (_) async {},
    );
    addTearDown(state.dispose);
    final mpris = MprisService(controller: player);
    addTearDown(mpris.dispose);
    final discord = DiscordPresence();
    addTearDown(discord.dispose);
    final lastfm = LastFmService(config: state.config);
    addTearDown(lastfm.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: state),
          ChangeNotifierProvider.value(value: mpris),
          ChangeNotifierProvider.value(value: discord),
          ChangeNotifierProvider.value(value: lastfm),
        ],
        child: const MaterialApp(home: Scaffold(body: SettingsScreen())),
      ),
    );
    await tester.pump();

    // The settings list is lazy: scroll the button into view before
    // tapping it (a built widget can still sit below the fold).
    final button = find.text('Run the setup again');
    for (var i = 0; i < 20; i++) {
      if (button.evaluate().isNotEmpty) {
        final rect = tester.getRect(button);
        if (rect.bottom < tester.view.physicalSize.height - 8) break;
      }
      await tester.drag(find.byType(ListView).first, const Offset(0, -400));
      await tester.pump();
    }
    expect(find.text('First-run setup'), findsOneWidget);
    await tester.tapAt(tester.getCenter(button));
    await tester.pump();
    // The setup takes over the window.
    expect(state.needsOnboarding, isTrue);
  });

  testWidgets('the choices are written to the settings', (tester) async {
    final state = await _boot();
    await _pump(tester, state);
    await tester.tapAt(tester.getCenter(find.text('Next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(tester.getCenter(find.text('Next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Switch the personalization step on.
    await tester.tapAt(tester.getCenter(find.text('High contrast')));
    await tester.pump();
    expect(state.config.highContrast, isTrue);
    expect(state.config.getBool('onboarding.done'), isFalse);
  });

  testWidgets('the steps still change with reduced motion on', (tester) async {
    final state = await _boot();
    state.config.reducedMotion = true;
    await _pump(tester, state);

    // A zero-length scroll animation is not allowed: the step must jump
    // instead, or the buttons stop working.
    await tester.tapAt(tester.getCenter(find.text('Next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Sign in to your account'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.text('Next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Make it yours'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.text('Back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Sign in to your account'), findsOneWidget);
  });

  testWidgets('the toggles show the value they set', (tester) async {
    final state = await _boot();
    await _pump(tester, state);
    await tester.tapAt(tester.getCenter(find.text('Next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(tester.getCenter(find.text('Next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The switches follow the settings they write.
    final reduceMotion = find.byType(Switch).first;
    final highContrast = find.byType(Switch).at(1);
    expect(tester.widget<Switch>(reduceMotion).value, isFalse);
    expect(tester.widget<Switch>(highContrast).value, isFalse);

    await tester.tapAt(tester.getCenter(find.text('Reduce motion')));
    await tester.pump();
    expect(tester.widget<Switch>(reduceMotion).value, isTrue);
    expect(state.config.reducedMotion, isTrue);

    await tester.tapAt(tester.getCenter(find.text('High contrast')));
    await tester.pump();
    expect(tester.widget<Switch>(highContrast).value, isTrue);
    expect(state.config.highContrast, isTrue);
  });

  testWidgets('the setup offers the last.fm sign-in too', (tester) async {
    final state = await _boot();
    await _pump(tester, state);
    await tester.tapAt(tester.getCenter(find.text('Next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(tester.getCenter(find.text('Next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The Last.fm row carries the toggle and the sign-in.
    expect(find.text('Last.fm scrobbling'), findsOneWidget);
    expect(find.text('Connect with last.fm'), findsOneWidget);
  });
}
