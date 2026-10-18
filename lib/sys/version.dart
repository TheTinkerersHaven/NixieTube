/// The app version and build number, embedded at compile time via
/// `--dart-define=APP_VERSION=0.2.0+3` (CI does this from pubspec.yaml).
///
/// Falls back to a placeholder when undefined (local `flutter run`).
const String appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.0.0+unknown',
);

/// Human-readable short form for display in settings.
String get appVersionLabel => 'NixieTube $appVersion';
