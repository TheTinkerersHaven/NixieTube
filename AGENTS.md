# NixieTube — agent operating rules

## Git: the user owns commits, tags, and pushes

The agent must **never** commit, push, tag, or force-push on the user's behalf. All changes stay **uncommitted on the working tree** until the user explicitly asks to commit.

- `git commit`, `git tag`, `git push`, `git push --tags`, and any force-push are user-only operations.
- When the user does commit, sign-offs/gpg signing are handled by the user (`git -c commit.gpgsign=false` or their own signing setup); the agent must not add `-c commit.gpgsign=false` or otherwise circumvent the user's signing flow.
- **Never force-push remote tags.**
- Before any release: the user decides when the tree is clean, what goes into the commit, the tag name, and when to push.

## Everything else

- `flutter analyze` clean, affected tests green, `flutter build linux --release` succeeds before a release is considered done.
- M3 (`useMaterial3: true`); M3E components throughout; no hardcoding user-facing content except explicitly requested section names.
- Two-login model: 1. Google OAuth, 2. browser cookie; per-session sign-out.
- Square thumbnails must use YouTube's own square art — no client-side auto-crop and no bar trimming; the store never crops (whole-frame decode).
- Keep resource usage minimal; verify via execution, not speculation.
- Check whether an existing dependency already implements a feature before hand-rolling it.
- Prefer `dart pub global run dartdoc` with 9.0.0 pinned for `dart doc`.
- Test gotchas: M3E buttons need `tapAt(getCenter(...))`; skeletonizer widget tests use bounded pumps (never `pumpAndSettle`); `testWidgets` fails on stray timers and the pending-timer check runs **before** `addTearDown`; real `dart:io` futures never complete under FakeAsync; this suite uses real short delays in plain `test()` (no `fake_async`); `mockDio` builds on `newHttpClient()` so injected dios have no retry interceptor.

## When the user says "release"

1. The user reviews the diff and decides what is included.
2. The user commits (signed as they prefer).
3. The user tags (e.g. `v0.1.x`) and pushes; the agent may be asked to draft release notes but must not execute the push or tag itself.
