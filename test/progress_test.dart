// Tests for the progress/update classifier driving the rebuild split:
// pure position ticks must not rebuild screens, everything else must.

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/ui/app_state.dart'
    show isProgressOnlyUpdate, queueSignature;

const _t1 = Track(videoId: 'v1', title: 'One');
const _t2 = Track(videoId: 'v2', title: 'Two');

PlayerState _state({
  Track? current,
  bool playing = true,
  bool loading = false,
  int positionMs = 1000,
  int durationMs = 200000,
  List<Track> queue = const [_t1, _t2],
}) =>
    PlayerState(
      current: current ?? _t1,
      playing: playing,
      loading: loading,
      positionMs: positionMs,
      durationMs: durationMs,
      queue: queue,
    );

void main() {
  group('isProgressOnlyUpdate', () {
    test('identical snapshots are progress-only', () {
      expect(isProgressOnlyUpdate(_state(), _state()), isTrue);
    });

    test('position-only movement is progress-only', () {
      expect(
          isProgressOnlyUpdate(
              _state(positionMs: 1000), _state(positionMs: 1500)),
          isTrue);
    });

    test('transport changes are real', () {
      final base = _state();
      expect(isProgressOnlyUpdate(base, _state(playing: false)), isFalse);
      expect(isProgressOnlyUpdate(base, _state(loading: true)), isFalse);
      expect(
          isProgressOnlyUpdate(
              base, _state(current: _t2, positionMs: 0)),
          isFalse);
    });

    test('duration latch and seeks are real', () {
      final base = _state(durationMs: 0);
      expect(
          isProgressOnlyUpdate(base, _state(durationMs: 200000)),
          isFalse);
    });

    test('rating changes are real', () {
      final base = _state();
      final liked = _t1.copyWith(rating: RatingStatus.like);
      expect(
          isProgressOnlyUpdate(
              base, _state(current: liked, queue: [liked, _t2])),
          isFalse);
    });

    test('queue edits are real', () {
      final base = _state();
      expect(
          isProgressOnlyUpdate(
              base, _state(queue: [_t1, _t2, _t1])),
          isFalse);
    });
  });

  group('queueSignature', () {
    test('stable for equal queues, differs on edit', () {
      expect(queueSignature([_t1, _t2]),
          queueSignature([_t1, _t2]));
      expect(queueSignature([_t1, _t2]),
          isNot(queueSignature([_t1])));
    });
  });
}
