// Behavior tests for the shared seek slider: tapping a
// point glides the thumb to it, dragging snaps to the
// finger instantly, and a song ending sweeps the thumb
// from the end back to the start instead of teleporting.

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/widgets/seek_slider.dart';

class _FakeEngine implements PlayerEngine {
  int position = 0;
  bool playing = false;

  @override
  Future<String?> play(String url) async {
    playing = true;
    return null;
  }

  @override
  Future<void> pause() async {
    playing = false;
  }

  @override
  Future<void> resume() async {
    playing = true;
  }

  @override
  Future<void> stop() async {
    playing = false;
  }

  @override
  Future<void> seekTo(int ms) async {
    position = ms;
  }

  @override
  Future<void> setVolume(int volume) async {}

  @override
  int positionMs() => position;

  @override
  int durationMs() => 200000;

  @override
  bool isPlaying() => playing;

  @override
  Future<void> release() async {}

  @override
  void addListener(PlayerEngineListener listener) {}
}

/// InnerTube stub: the real client schedules network
/// retries whose timers outlive the test.
class _QuietTube extends InnerTube {
  @override
  Future<Track> enrichTrack(Track track) async => track;

  @override
  Future<RatingStatus> rating(String videoId) async => RatingStatus.unknown;
}

const _t1 = Track(videoId: 'v1', title: 'One', durationSec: 200);

/// Pumps a 400px-wide SeekSlider over a fresh AppState with
/// one loaded track (200s), returning the state and the
/// controllable engine.
Future<({AppState state, _FakeEngine engine, PlayerController player})>
_setupSlider(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('nt-seek-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = _QuietTube();
  addTearDown(tube.close);
  final engine = _FakeEngine();
  final player = PlayerController(
    engine: engine,
    tube: tube,
    resolveStream: (id) async =>
        ResolvedStream(url: 'https://x/$id', bitrate: 1),
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  final oauth = GoogleOAuth();
  addTearDown(oauth.close);
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    oauth: oauth,
    config: SysConfig(configPath: '${dir.path}/config.properties'),
    openUrl: (_) async {},
  );
  addTearDown(state.dispose);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 100,
              child: SeekSlider(state: state),
            ),
          ),
        ),
      ),
    ),
  );
  state.playSongs([_t1], 0);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return (state: state, engine: engine, player: player);
}

double _sliderValue(WidgetTester tester) =>
    tester.widget<M3ESlider>(find.byType(M3ESlider)).value;

/// Pumps in 10ms steps until [check] passes or the budget
/// runs out, returning whether it ever did. Animation
/// controllers lag a pump behind the clock in widget tests,
//  so mid-flight values are sampled rather than assumed.
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function(double value) check, {
  int steps = 60,
}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (check(_sliderValue(tester))) return true;
  }
  return false;
}

void main() {
  testWidgets('tapping a point glides the thumb to it', (tester) async {
    final r = await _setupSlider(tester);
    final rect = tester.getRect(find.byType(M3ESlider));
    // Tap ~70% across: 140s of the 200s track.
    await tester.tapAt(rect.center + Offset(rect.width * 0.2, 0));
    // The thumb passes through the middle of the track on
    // its way to the tapped point (a teleport would not).
    expect(await _pumpUntil(tester, (v) => v > 20000 && v < 135000), isTrue);
    await tester.pumpAndSettle();
    // The tap lands 20% past center; the M3E slider
    // insets the track by the thumb radius on each
    // side, so map the offset through the same math.
    const margin = M3ESliderDefaults.thumbRadius;
    final fraction =
        ((rect.center.dx + rect.width * 0.2 - rect.left - margin) /
                (rect.width - 2 * margin))
            .clamp(0.0, 1.0);
    final expected = fraction * 200000;
    expect(_sliderValue(tester), closeTo(expected, 0.5));
    expect(r.state.player.state.positionMs, expected.round());
    r.player.dispose();
    await tester.pump();
  });

  testWidgets('dragging snaps to the finger instantly', (tester) async {
    final r = await _setupSlider(tester);
    final rect = tester.getRect(find.byType(M3ESlider));
    final center = rect.center;
    final gesture = await tester.startGesture(center);
    addTearDown(gesture.removePointer);
    // A real drag streams updates every frame: the first
    // one may begin a glide, the rest snap to the finger
    // and cancel it.
    await gesture.moveTo(center + const Offset(30, 0));
    await gesture.moveTo(center + const Offset(60, 0));
    await gesture.moveTo(center + const Offset(120, 0));
    await gesture.moveTo(center + const Offset(160, 0));
    await gesture.up();
    await tester.pump();
    // ~92% across: the finger's final position, no glide.
    final value = _sliderValue(tester);
    expect(value, greaterThan(160000));
    expect(value, lessThan(200000));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_sliderValue(tester), closeTo(value, 1));
    expect(r.state.player.state.positionMs, closeTo(value, 1));
    r.player.dispose();
    await tester.pump();
  });

  testWidgets('a finished song sweeps the thumb back to the start', (
    tester,
  ) async {
    final r = await _setupSlider(tester);
    // The fresh-start hold releases once the engine restarts near 0.
    r.engine.position = 500;
    await tester.pump(const Duration(milliseconds: 600));
    // Near the end of the track…
    r.engine.position = 198000;
    await tester.pump(const Duration(milliseconds: 600));
    expect(_sliderValue(tester), closeTo(198000, 1000));
    // …then the position resets (track ended / repeat).
    r.engine.position = 0;
    await tester.pump(const Duration(milliseconds: 500));
    // The thumb glides back through the middle of the
    // track instead of teleporting to 0.
    expect(await _pumpUntil(tester, (v) => v > 50000 && v < 150000), isTrue);
    await tester.pumpAndSettle();
    expect(_sliderValue(tester), lessThan(1));
    r.player.dispose();
    await tester.pump();
  });
}
