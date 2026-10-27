import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/volume_slider.dart';

import 'fakes.dart';

void main() {
  testWidgets('VolumeSlider renders at the current player volume',
      (tester) async {
    final tube = FakeTube();
    addTearDown(tube.close);
    final state = await bootAppState(tester, tube: tube);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: ChangeNotifierProvider.value(
            value: state,
            child: VolumeSlider(state: state),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(VolumeSlider), findsOneWidget);
  });
}
