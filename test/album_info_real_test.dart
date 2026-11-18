// Throwaway: raw HTTP status inside a widget test.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/http_client.dart';

void main() {
  testWidgets('raw status in widget test', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('x')));
    late int status;
    late String body;
    late int ms;
    final sw = Stopwatch()..start();
    await tester.runAsync(() async {
      final dio = newResilientClient();
      final r = await dio.get(
        lastfmApiUrl,
        queryParameters: {
          'method': 'album.getInfo',
          'api_key': '38d8a6ea0a40c47f428cbe7b887480f4',
          'artist': 'Daft Punk',
          'album': 'Random Access Memories',
          'autocorrect': '1',
          'format': 'json',
        },
      );
      status = r.statusCode ?? 0;
      body = '${r.data}';
      ms = sw.elapsedMilliseconds;
    });
    debugPrint('STATUS $status in ${ms}ms bodylen=${body.length} head=${body.length > 200 ? body.substring(0, 200) : body}');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
