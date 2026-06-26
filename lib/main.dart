import 'package:chessever/desktop/desktop_main.dart';

/// Desktop-only entrypoint. The previous mobile/tablet startup pipeline
/// (Sentry, OneSignal, Clarity, native splash, MyApp shell) has been removed
/// — this repo is a desktop app and runs exclusively through [desktopMain].
Future<void> main(List<String> args) async {
  await desktopMain(initialArguments: args);
}
