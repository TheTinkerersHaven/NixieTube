// The script the solver hands to the engine. The pre-solved artifact is the
// whole player, so it must travel once per version: the first solve ships it,
// a later solve for the same version carries only the challenges, and a
// document that lost the compiled copy says so instead of failing the track.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/js_challenge_solver.dart';

/// A stand-in for a published artifact, with the quotes and newlines a real
/// one has, so the escaping is part of what is checked.
final _artifact =
    'if (typeof globalThis.XMLHttpRequest === "undefined") {}\n'
    '${'var a = "x";\n' * 400}'
    '_result.n = n;\n'
    '_result.sig = sig;';

const _sig = ['s-challenge'];
const _n = ['n-challenge'];

void main() {
  test('the first solve ships the artifact and compiles it once', () {
    final script = presolvedSolveScript(
      playerId: 'b485e332',
      preprocessed: _artifact,
      sigChallenges: _sig,
      nChallenges: _n,
    );

    expect(script, contains('const source = ${jsonEncode(_artifact)};'));
    expect(script, contains("Function('globalThis', '_result', source)"));
    expect(script, contains('"s-challenge"'));
    expect(script, contains('"n-challenge"'));
    // The compiled entry points are kept on window, keyed by version.
    expect(script, contains('window.__jscPlayers'));
    expect(script, contains('"b485e332"'));
  });

  test('a later solve for the same version carries no artifact', () {
    final warm = presolvedSolveScript(
      playerId: 'b485e332',
      preprocessed: null,
      sigChallenges: _sig,
      nChallenges: _n,
    );

    expect(warm, isNot(contains('var a = ')));
    expect(warm, contains('const source = null;'));
    // Without the source the script reports a cold engine instead of
    // throwing, so the caller can pay for the compile once more.
    expect(warm, contains("return JSON.stringify({type: 'cold'})"));
    expect(warm.length, lessThan(2048));
  });

  test('the long path carries the artifact once, and only the artifact', () {
    final cold = presolvedSolveScript(
      playerId: 'b485e332',
      preprocessed: _artifact,
      sigChallenges: _sig,
    );
    final warm = presolvedSolveScript(
      playerId: 'b485e332',
      sigChallenges: _sig,
    );

    // Nothing but the source differs between the two shapes.
    expect(cold.length - warm.length, jsonEncode(_artifact).length - 4);
  });

  test('each player version is its own cache entry', () {
    final first = presolvedSolveScript(
      playerId: 'b485e332',
      sigChallenges: _sig,
    );
    final second = presolvedSolveScript(
      playerId: 'c0ffee42',
      sigChallenges: _sig,
    );

    expect(first, contains('"b485e332"'));
    expect(first, isNot(contains('"c0ffee42"')));
    expect(second, contains('"c0ffee42"'));
  });

  test('a solve with nothing to answer does not reach the engine', () async {
    // No engine is installed in the test binding: this only passes if the
    // solver returns before asking for one.
    expect(await JsChallengeSolver().solve(), isEmpty);
  });
}
