// Helpers behind the song-info rows: the YTM plays label keeps only the
// count when the tracker string appends a word ("653M plays" → "653M"),
// and the compact K/M formatter agrees with the Likes row.

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/ui/widgets/song_info.dart' show playsLabel, compactCount;

void main() {
  group('playsLabel', () {
    test('drops the trailing word from display strings', () {
      expect(playsLabel('653M plays'), '653M');
      expect(playsLabel('1,234,567 views'), '1,234,567');
      expect(playsLabel('2K'), '2K');
      expect(playsLabel('653M'), '653M');
    });

    test('keeps localized or unparsable strings verbatim', () {
      expect(playsLabel('No views'), 'No views');
      expect(playsLabel('1,2 Mio. Aufrufe'), '1,2 Mio.');
      expect(playsLabel('1,7 mln riproduzioni'), '1,7 mln');
      expect(playsLabel(''), '');
      expect(playsLabel('  '), '');
    });
  });

  group('compactCount', () {
    test('large counts compact as K/M', () {
      expect(compactCount(500), '500');
      expect(compactCount(1500), '1.5K');
      expect(compactCount(150000), '150K');
      expect(compactCount(653123456), '653M');
      expect(compactCount(-1), '');
    });
  });
}
