// MusicBrainz probe: query the web service and print what it returns.
//
// A small CLI for exploring the API without opening the app:
//
//   dart run tool/musicbrainz_probe.dart --artist "Daft Punk" --album "Random Access Memories"
//   dart run tool/musicbrainz_probe.dart --artist "Daft Punk" --album "Random Access Memories" --group
//   dart run tool/musicbrainz_probe.dart --id 4f6b1a7c-... --group
//   dart run tool/musicbrainz_probe.dart --artist "Daft Punk" --album "Random Access Memories" --raw
//
// Options:
//   --artist <name>   Artist credit to search for.
//   --album <title>   Release or release-group title to search for.
//   --id <mbid>       Look up one release (or release-group with --group).
//   --group           Search release groups instead of releases.
//   --limit <n>       Search results to request (default 5).
//   --raw             Print only the JSON response.
//
// MusicBrainz asks for at most one request per second and answers 503
// when it is busy; wait a moment and run the same command again.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

const _baseUrl = 'https://musicbrainz.org/ws/2/';
// MusicBrainz requires a descriptive User-Agent with contact details.
const _userAgent =
    'NixieTube/0.4.6 (https://github.com/TheTinkerersHaven/NixieTube)';

Future<void> main(List<String> args) async {
  final options = _Options();
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--artist':
        options.artist = args[++i];
      case '--album':
        options.album = args[++i];
      case '--id':
        options.id = args[++i];
      case '--limit':
        options.limit = int.tryParse(args[++i]) ?? options.limit;
      case '--group':
        options.group = true;
      case '--raw':
        options.raw = true;
      case '--help':
      case '-h':
        _usage();
        return;
      default:
        stderr.writeln('Unknown argument: $arg');
        _usage();
        exit(64);
    }
  }

  final uri = _buildUri(options);
  if (uri == null) {
    _usage();
    exit(64);
  }

  final dio = Dio(
    BaseOptions(validateStatus: (_) => true, responseType: ResponseType.plain),
  );
  stdout.writeln('GET $uri');
  try {
    final res = await dio.getUri(
      uri,
      options: Options(headers: {'User-Agent': _userAgent}),
    );
    stdout.writeln('HTTP ${res.statusCode}');
    final body = res.data?.toString() ?? '';
    if (body.isEmpty) {
      stderr.writeln('(empty response body)');
      exit(1);
    }
    final decoded = jsonDecode(body);
    if (options.raw) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(decoded));
      return;
    }
    _printSummary(decoded, options.group);
    stdout.writeln();
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(decoded));
  } on DioException catch (e) {
    stderr.writeln('Request failed: ${e.message}');
    exit(1);
  } on FormatException catch (e) {
    stderr.writeln('Response was not JSON: ${e.message}');
    exit(1);
  }
}

class _Options {
  String? artist;
  String? album;
  String? id;
  int limit = 5;
  bool group = false;
  bool raw = false;
}

Uri? _buildUri(_Options options) {
  final kind = options.group ? 'release-group' : 'release';
  if (options.id != null && options.id!.trim().isNotEmpty) {
    return Uri.parse('$_baseUrl$kind/${options.id!.trim()}').replace(
      queryParameters: {
        'inc': options.group ? 'artists' : 'labels+release-groups',
        'fmt': 'json',
      },
    );
  }
  final artist = options.artist?.trim() ?? '';
  final album = options.album?.trim() ?? '';
  if (artist.isEmpty || album.isEmpty) return null;
  final field = options.group ? 'releasegroup' : 'release';
  return Uri.parse('$_baseUrl$kind/').replace(
    queryParameters: {
      'query': '$field:"${_escape(album)}" AND artist:"${_escape(artist)}"',
      'fmt': 'json',
      'limit': '${options.limit}',
    },
  );
}

String _escape(String value) =>
    value.replaceAll('\\', r'\\').replaceAll('"', r'\"');

void _usage() {
  stdout.writeln(
    'Usage: dart run tool/musicbrainz_probe.dart '
    '--artist <name> --album <title> [--group] [--limit <n>] [--raw]',
  );
  stdout.writeln(
    '   or: dart run tool/musicbrainz_probe.dart --id <mbid> [--group] [--raw]',
  );
}

void _printSummary(Object? decoded, bool group) {
  if (decoded is! Map) return;
  final error = decoded['error'];
  if (error is String && error.isNotEmpty) {
    stdout.writeln('error: $error');
    return;
  }
  final count = decoded['count'];
  if (count != null) stdout.writeln('count: $count');
  final list = group ? decoded['release-groups'] : decoded['releases'];
  if (list is List) {
    for (var i = 0; i < list.length; i++) {
      _printOne(list[i], group, i + 1);
    }
    return;
  }
  // Direct lookup: the response is the object itself.
  _printOne(decoded, group, null);
}

void _printOne(Object? raw, bool group, int? index) {
  if (raw is! Map) return;
  final prefix = index == null ? '' : '$index. ';
  final title = _s(raw['title']);
  final id = _s(raw['id']);
  final score = raw['score'];
  final parts = <String>[
    if (_s(raw['date']).isNotEmpty) _s(raw['date']),
    if (_s(raw['country']).isNotEmpty) _s(raw['country']),
    if (_s(raw['status']).isNotEmpty) _s(raw['status']),
  ];
  final labels = _labels(raw['label-info']);
  if (labels.isNotEmpty) parts.add(labels.join(', '));
  if (group) {
    final types = <String>[
      if (_s(raw['primary-type']).isNotEmpty) _s(raw['primary-type']),
      ..._strings(raw['secondary-types']),
    ];
    if (types.isNotEmpty) parts.add(types.join(' · '));
    if (_s(raw['first-release-date']).isNotEmpty) {
      parts.add('first release ${_s(raw['first-release-date'])}');
    }
  } else {
    final rg = raw['release-group'];
    if (rg is Map) {
      final type = _s(rg['primary-type']);
      if (type.isNotEmpty) parts.add(type);
      final first = _s(rg['first-release-date']);
      if (first.isNotEmpty) parts.add('first release $first');
    }
  }
  final disambiguation = _s(raw['disambiguation']);
  if (disambiguation.isNotEmpty) parts.add('“$disambiguation”');
  if (score != null) parts.add('score $score');
  if (id.isNotEmpty) parts.add(id);
  stdout.writeln('$prefix$title — ${parts.join(' · ')}');
}

String _s(Object? value) => value is String ? value : '';

List<String> _strings(Object? value) {
  if (value is! List) return const [];
  return value.whereType<String>().where((s) => s.isNotEmpty).toList();
}

List<String> _labels(Object? value) {
  if (value is! List) return const [];
  final out = <String>[];
  for (final raw in value) {
    if (raw is! Map) continue;
    final label = raw['label'];
    if (label is Map && label['name'] is String) {
      final name = (label['name'] as String).trim();
      if (name.isNotEmpty) out.add(name);
    }
  }
  return out;
}
