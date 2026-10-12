#include <glib.h>

#include "my_application.h"

int main(int argc, char** argv) {
  // Keep WebKitGTK off EGL: its accelerated compositing fights the
  // Flutter engines over the EGL display (eglMakeCurrent spam and
  // freezes), and a login page doesn't need compositing. Read by
  // WebKit at first-context creation, so process start is the place.
  g_setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "1", TRUE);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
