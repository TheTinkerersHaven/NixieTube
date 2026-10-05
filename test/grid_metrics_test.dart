// Tests for the quick-picks grid metrics shared with the liked-list
// height cut: both sides must agree on the rendered grid height.

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/ui/screens/home_screen.dart'
    show quickPickMetrics, quickPicksHeight;

void main() {
  group('quickPickMetrics', () {
    test('columns clamp to 3..6', () {
      expect(quickPickMetrics(400, 18).cols, 3);
      expect(quickPickMetrics(1200, 18).cols, 6);
      expect(quickPickMetrics(700, 18).cols, 4);
    });

    test('rows cover the shown items', () {
      final m = quickPickMetrics(1200, 18);
      expect(m.rows, 3);
      expect(m.shown, 18);
      expect(quickPickMetrics(1200, 5).rows, 1);
    });

    test('height matches header plus tile grid', () {
      // 1200px grid: 6 cols, 200px tiles, 3 rows -> 56 + 600.
      expect(quickPicksHeight(1200, 18), 56 + 600);
    });
  });
}
