// The vendored EJS bundle carries one local change, and this test keeps it
// from being lost when the bundle is regenerated.
//
// astring's writer appends every printed token with `output += chunk`.
// That is free on V8/JavaScriptCore, which build a cons-string per append
// and flatten once, but QuickJS has no ropes: `JS_ConcatString1` allocates
// exactly `len1 + len2` and memcpys both halves, so the printer goes
// quadratic. One player is 1.38 M appends averaging 2.8 bytes — about
// 2.5 TB of copying, i.e. minutes, which is what made the on-device AST
// pass unusable. With the chunks joined once it is linear: 0.8 s for the
// same player instead of several minutes, on the same engine.
//
// The four edits, applied to assets/js/yt.solver.lib.js (astring's writer):
//
//   1.  write(e){this.output+=e}                    ->  write(e){this.chunks.push(e)}
//   2.  this.writeComments=!!t.comments&&t.comments,  ->  ...,this.chunks=[],
//   3.  toString(){return this.output}}              ->  toString(){return this.chunks.join("")}}
//   4.  return r.generator[e.type](e,r),r.output}}    ->  return r.generator[e.type](e,r),r.chunks.join("")}}
//
// Edit 4 is what actually matters (it is what `generate` returns); 1-3 keep
// `toString()` consistent with it. Stream and source-map output modes keep
// their own `output` field and are untouched — the solver only uses the
// plain mode.
//
// The printed script is byte-identical to the unpatched bundle's, so
// published pre-solved artifacts stay valid.

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'astring buffers its output instead of concatenating per token',
    () async {
      final bundle = await rootBundle.loadString('assets/js/yt.solver.lib.js');

      expect(
        bundle,
        contains('write(e){this.chunks.push(e)}'),
        reason:
            'the writer patch was lost (regenerated bundle?): re-apply the '
            'four edits in this test\'s header, or the printer is quadratic on '
            'engines without rope strings',
      );
      expect(bundle, contains('this.chunks=[]'));
      expect(bundle, contains('r.chunks.join("")}'));
      expect(
        bundle,
        isNot(contains('write(e){this.output+=e}')),
        reason: 'the token-by-token concatenation is back',
      );
    },
  );
}
