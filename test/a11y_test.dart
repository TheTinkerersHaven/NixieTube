import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/ui/a11y.dart';

import 'fakes.dart';

void main() {
  testWidgets('motionDuration falls back to full duration without AppState', (
    tester,
  ) async {
    const d = Duration(milliseconds: 300);
    late Duration got;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            got = motionDuration(context, d);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(got, d);
  });

  testWidgets('highContrastOf defaults to false without AppState', (
    tester,
  ) async {
    late bool got;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            got = highContrastOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(got, isFalse);
  });

  testWidgets('motionDuration collapses to zero when reduced motion is on', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('nt-a11y');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = FakeTube();
    addTearDown(tube.close);
    final state = await bootAppState(tester, tube: tube);
    state.config.setBool('a11y.reducedMotion', true);
    const d = Duration(milliseconds: 300);
    late Duration got;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider.value(
          value: state,
          child: Builder(
            builder: (context) {
              got = motionDuration(context, d);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(got, Duration.zero);
  });
}
