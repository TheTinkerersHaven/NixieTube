// Tests for the navigation stack the shell turns into routes.
//
// The stack is the single source of truth: the app pushes and pops it,
// and the system's back button or gesture pops a route and reports that
// pop back through [NavigationState.popped]. Both directions have to land
// on the same stack.

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/ui/state/navigation_state.dart';

const _artist = BrowseItem(
  title: 'Artist',
  subtitle: '',
  browseId: 'UC123',
  thumbnails: [],
);

const _album = BrowseItem(
  title: 'Album',
  subtitle: '',
  browseId: 'MPRE456',
  thumbnails: [],
);

void main() {
  test('starts on home as the only page', () {
    final nav = NavigationState();
    expect(nav.screen, Screen.home);
    expect(nav.canGoBack, isFalse);
    expect(nav.pages.map((e) => e.screen), [Screen.home]);
    expect(nav.parentScreen, isNull);
  });

  test('a push becomes a page and back returns to the one below', () {
    final nav = NavigationState();
    expect(nav.go(Screen.search), isTrue);
    expect(nav.screen, Screen.search);
    expect(nav.canGoBack, isTrue);
    expect(nav.pages.length, 2);
    expect(nav.pages.first.id, isNot(nav.pages.last.id));

    expect(nav.goBack(), isTrue);
    expect(nav.screen, Screen.home);
    expect(nav.canGoBack, isFalse);
    expect(nav.pages.length, 1);
  });

  test('the page list only changes when the stack does', () {
    final nav = NavigationState();
    final before = nav.pages;
    nav.go(Screen.library);
    expect(identical(nav.pages, before), isFalse);
    final after = nav.pages;
    // Reading it again hands out the same snapshot, so selecting on it in
    // the shell does not rebuild on every player tick.
    expect(identical(nav.pages, after), isTrue);
  });

  test('a page the navigator removed is dropped from the stack', () {
    final nav = NavigationState();
    nav.go(Screen.search);
    nav.go(Screen.detail, detail: _artist);
    final artistPage = nav.pages.last;

    // What a system back gesture does: the route pops, and the pop comes
    // back here.
    expect(nav.popped(artistPage.id), isTrue);
    expect(nav.screen, Screen.search);

    // A page the app popped itself is already gone, so the navigator's
    // report of that pop must be a no-op.
    final searchPage = nav.pages.last;
    expect(nav.goBack(), isTrue);
    expect(nav.popped(searchPage.id), isFalse);
    expect(nav.screen, Screen.home);
  });

  test('the page showing now is not pushed again', () {
    final nav = NavigationState();
    expect(nav.go(Screen.home), isFalse);
    expect(nav.pages.length, 1);
    expect(nav.go(Screen.settings), isTrue);
    expect(nav.go(Screen.settings), isFalse);
    expect(nav.pages.length, 2);

    // Every browse target is its own page, even on the same screen.
    expect(nav.go(Screen.detail, detail: _artist), isTrue);
    expect(nav.go(Screen.detail, detail: _artist), isFalse);
    expect(nav.go(Screen.detail, detail: _album), isTrue);
    expect(nav.pages.length, 4);
  });

  test('the parent screen skips pushed pages', () {
    final nav = NavigationState();
    nav.go(Screen.library);
    nav.go(Screen.detail, detail: _artist);
    nav.go(Screen.settings);
    expect(nav.screen, Screen.settings);
    expect(nav.parentScreen, Screen.library);
  });

  test('the stack is capped so mounted pages stay bounded', () {
    final nav = NavigationState();
    for (var i = 0; i < NavigationState.maxDepth + 6; i++) {
      nav.go(Screen.detail, detail: BrowseItem(
        title: 'Album $i',
        subtitle: '',
        browseId: 'MPRE$i',
        thumbnails: const [],
      ));
    }
    expect(nav.pages.length, NavigationState.maxDepth);
    expect(nav.screen, Screen.detail);
  });
}
