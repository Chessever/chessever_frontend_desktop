import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Which desktop engine this provider container belongs to.
///
/// The primary window hosts the shell, the sidebar and every account surface
/// (sign-in, reminders, purchase). Detached board windows and the
/// picture-in-picture engine only render a board, so anything that interrupts
/// the user about their account must stay in [main].
enum DesktopWindowRole { main, detached }

/// Defaults to [DesktopWindowRole.main]. `desktop_main.dart` overrides it to
/// [DesktopWindowRole.detached] in the container it builds for board windows.
final desktopWindowRoleProvider = Provider<DesktopWindowRole>(
  (ref) => DesktopWindowRole.main,
);
