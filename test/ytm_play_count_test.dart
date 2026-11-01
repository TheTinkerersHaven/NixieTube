// YTM play-count cache: one fetch per track per session, the count is
// remembered, failed fetches stay uncached and refetch on the next ask.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeTube tube;

  setUp(() {
    tube = FakeTube();
    addTearDown(tube.close);
  });

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(const Placeholder());
  }

  testWidgets('caches after the first fetch', (tester) async {
    tube.nextViewCount = 1234567;
    final state = await bootAppState(tester, tube: tube);
    await pumpShell(tester);
    expect(tube.viewCountCalls, 0);
    expect(await state.fetchYtmPlayCount('vid1'), 1234567);
    expect(tube.viewCountCalls, 1);
    expect(state.ytmPlayCount('vid1'), 1234567);
    // Second and concurrent ask come from the cache.
    expect(await state.fetchYtmPlayCount('vid1'), 1234567);
    expect(await state.fetchYtmPlayCount('vid1'), 1234567);
    expect(tube.viewCountCalls, 1);
  });

  testWidgets('a failed fetch stays uncached and refetches', (tester) async {
    tube.nextViewCount = null;
    final state = await bootAppState(tester, tube: tube);
    await pumpShell(tester);
    expect(await state.fetchYtmPlayCount('vid2'), 0);
    expect(state.ytmPlayCount('vid2'), isNull);
    tube.nextViewCount = 42;
    expect(await state.fetchYtmPlayCount('vid2'), 42);
    expect(tube.viewCountCalls, 2);
  });

  testWidgets('a zero count is not cached either', (tester) async {
    tube.nextViewCount = 0;
    final state = await bootAppState(tester, tube: tube);
    await pumpShell(tester);
    expect(await state.fetchYtmPlayCount('vid3'), 0);
    expect(state.ytmPlayCount('vid3'), isNull);
  });

  testWidgets('only the requested track is cached', (tester) async {
    tube.nextViewCount = 7;
    final state = await bootAppState(tester, tube: tube);
    await pumpShell(tester);
    expect(await state.fetchYtmPlayCount('a'), 7);
    tube.nextViewCount = 9;
    expect(await state.fetchYtmPlayCount('b'), 9);
    expect(state.ytmPlayCount('a'), 7);
  });
}
