// Tests for the metadata helpers: artist fixup, album inference,
// durations, and music/region filters.

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/metadata.dart';
import 'package:nixietube/core/models/models.dart';

void main() {
  group('normalizeArtist', () {
    test('strips topic and vevo suffixes', () {
      expect(normalizeArtist('Daft Punk - Topic'), 'Daft Punk');
      expect(normalizeArtist('AdeleVEVO'), 'Adele');
      expect(normalizeArtist('Glitch Cat'), 'Glitch Cat');
      expect(normalizeArtist('VEVO'), 'VEVO');
    });
  });

  group('fixup', () {
    test('label split and version guard', () {
      // Label upload "Artist - Track" splits.
      expect(fixup('Glitch Cat - PHANTOM-LOCK', 'Glitch Cat', []), (
        artist: 'Glitch Cat',
        title: 'PHANTOM-LOCK',
      ));
      // Version suffix stays put.
      expect(fixup('Song - Live', 'Some Channel', []), (
        artist: 'Some Channel',
        title: 'Song - Live',
      ));
      // Topic channel is authoritative.
      expect(fixup('MAGNUM', 'Ric de Large - Topic', []), (
        artist: 'Ric de Large',
        title: 'MAGNUM',
      ));
      // Distributor channel defers to tags.
      expect(fixup('Deep End', 'Release - Topic', ['Whiney', 'Deep End']), (
        artist: 'Whiney',
        title: 'Deep End',
      ));
    });
  });

  group('hasGenericReleaseArtist', () {
    test('flags empty and placeholder credits only', () {
      Track track(String id, List<String> artists) => Track(
        videoId: id,
        title: 'T',
        artists: artists.map((n) => ArtistRef(n)).toList(),
      );
      expect(hasGenericReleaseArtist(track('a', [])), isTrue);
      expect(hasGenericReleaseArtist(track('b', ['Release'])), isTrue);
      expect(hasGenericReleaseArtist(track('c', ['Boom Kitty'])), isFalse);
      expect(
        hasGenericReleaseArtist(track('d', ['Boom Kitty', 'Release'])),
        isFalse,
      );
    });
  });

  group('albumFromTags', () {
    test('single shape returns the title', () {
      expect(
        albumFromTags('Deep End', 'Whiney', 'Release - Topic', [
          'Whiney',
          'Single',
          'Deep End',
        ]),
        'Deep End',
      );
    });

    test('non-generic owners yield nothing', () {
      expect(albumFromTags('T', 'A', 'Some Label', ['A', 'T']), isNull);
    });
  });

  group('albumKindFromTags', () {
    test('classifies by tokens', () {
      expect(
        albumKindFromTags('T', 'My EP', 'Release - Topic', []),
        ReleaseKind.ep,
      );
      expect(
        albumKindFromTags('Same', 'Same', 'Release - Topic', []),
        ReleaseKind.single,
      );
      expect(
        albumKindFromTags('T', 'Greatest Hits', 'Release - Topic', [
          'Compilation',
        ]),
        ReleaseKind.compilation,
      );
    });
  });

  group('isoDuration', () {
    test('parses ISO-8601', () {
      expect(isoDuration('PT4M13S'), 253);
      expect(isoDuration('PT1H2M3S'), 3723);
      expect(isoDuration('PT25S'), 25);
      expect(isoDuration('PT2M'), 120);
      expect(isoDuration(null), 0);
      expect(isoDuration(''), 0);
      expect(isoDuration('bogus'), 0);
    });
  });

  group('keepTrack', () {
    test('music category and topics pass, region blocks apply', () {
      final music = {
        'snippet': {'categoryId': '10'},
        'topicDetails': <String, dynamic>{},
        'contentDetails': <String, dynamic>{},
      };
      expect(keepTrack(music, 'US'), isTrue);
      final topic = {
        'snippet': <String, dynamic>{},
        'topicDetails': {
          'relevantTopicIds': ['/m/04rlf'],
        },
        'contentDetails': <String, dynamic>{},
      };
      expect(keepTrack(topic, 'US'), isTrue);
      final vlog = {
        'snippet': <String, dynamic>{},
        'topicDetails': {
          'relevantTopicIds': ['/m/02jjt'],
        },
        'contentDetails': <String, dynamic>{},
      };
      expect(keepTrack(vlog, 'US'), isFalse);
      // Category 10 short-circuits before region checks, like Kotlin.
      final blocked = {
        'snippet': {'categoryId': '10'},
        'topicDetails': <String, dynamic>{},
        'contentDetails': {
          'regionRestriction': {
            'blocked': ['US'],
          },
        },
      };
      expect(keepTrack(blocked, 'US'), isTrue);
      final allowed = {
        'snippet': <String, dynamic>{},
        'topicDetails': {
          'relevantTopicIds': ['/m/04rlf'],
        },
        'contentDetails': {
          'regionRestriction': {
            'allowed': ['IT'],
          },
        },
      };
      expect(keepTrack(allowed, 'US'), isFalse);
      expect(keepTrack(allowed, 'IT'), isTrue);
    });
  });
}
