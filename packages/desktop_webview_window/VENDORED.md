# Vendored `desktop_webview_window` 0.3.0

Source: https://github.com/MixinNetwork/flutter-plugins/tree/main/packages/desktop_webview_window
License: Apache-2.0 (see LICENSE). Original copyright retained.

Vendored because the login webview kept segfaulting the whole app
after Google sign-in, and the crashes are all NULL-dereferences in
this package's Linux native code. Upstream 0.3.0 is the latest
release, so the fixes live here until they land upstream.

Linux fixes in `linux/webview_window.cc` (all marked with comments):

1. `DecidePolicy`: `webkit_uri_request_get_uri()` returns NULL for
   blank/empty navigations — exactly the blank white page at the end
   of Google's login redirect chain. NULL went straight into
   `fl_value_new_string()` → crash. Now guarded.
2. `EvaluateJavaScript` finish callback: `error` itself may be NULL
   when `js_result` is NULL (evaluate racing a new navigation).
   `error->message` → crash. Now guarded.
3. `GetAllCookies`: `soup_cookie_get_expires()` returns NULL for
   session-only cookies (Google login sets a handful), and the
   name/value/domain/path getters may return NULL for malformed
   cookies. All guarded.

4. `getAllCookies` is now async (`GetAllCookiesAsync`): the old
   path ran `get_cookies_sync`, which blocks the UI thread on a
   nested `g_main_loop_run`. On busy pages (heavy YTM, redirect
   chains) the cookie round-trip stalls → the whole app hangs, the
   Dart timeout can't cancel native code, and closing the window
   mid-wait use-after-frees → hang-then-crash. The async version
   responds from the cookie callback; timeouts work again.
5. Window `destroy` handler use-after-free (the close crash): the
   handler invoked `on_close_callback_` first, which erases the
   window from the plugin map and destroys it, then kept using
   `window->method_channel_` → segfault in
   `g_type_check_instance_cast` on every close (confirmed via
   coredump stack trace). Now it notifies `onWindowClose` first
   and erases last.
6. EGL teardown freeze (`eglMakeCurrent failed` spam, app frozen
   after the login window closes): the window hosted a second
   Flutter engine for its title bar, defaulting to Impeller while
   the main app runs Skia — two renderers fighting over one EGL
   display — plus WebKit's own accelerated compositing. The
   title-bar engine is now skipped for `titleBarHeight <= 0` (the
   app passes 0 and gets system decorations), and the runner sets
   `WEBKIT_DISABLE_COMPOSITING_MODE=1` at process start so WebKit
   stays off EGL too.
