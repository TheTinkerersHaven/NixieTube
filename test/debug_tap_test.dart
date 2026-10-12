import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('bare M3ESlider drag', (tester) async {
    var changed = 0.0;
    var ended = 0.0;
    var started = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 100,
            child: M3ESlider(
              value: changed,
              min: 0,
              max: 200000,
              label: 'x',
              onChangeStart: (v) => started = v,
              onChanged: (v) => changed = v,
              onChangeEnd: (v) => ended = v,
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(M3ESlider));
    debugPrint('rect: $rect');
    final center = rect.center;
    final gesture = await tester.startGesture(center);
    await gesture.moveTo(center + const Offset(120, 0));
    debugPrint('after move1: started=$started changed=$changed');
    await gesture.moveTo(center + const Offset(160, 0));
    debugPrint('after move2: changed=$changed');
    await gesture.up();
    debugPrint('after up: changed=$changed ended=$ended');
    await tester.pump();
    debugPrint('after pump: changed=$changed ended=$ended');
  });
}
