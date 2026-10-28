/// The browser cannot launch Explorer; callers fall back to their non-Windows
/// path.
bool executeWindowsShellOpen({
  required String executable,
  required String parameters,
}) => false;
