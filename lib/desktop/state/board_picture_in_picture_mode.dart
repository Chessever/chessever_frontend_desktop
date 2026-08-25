import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Whether the current secondary Board window is the compact, always-on-top
/// picture-in-picture surface.
///
/// The primary application window keeps the default `false`. A PiP window owns
/// a separate [ProviderContainer], so enabling this there cannot collapse the
/// board layout in the main window.
final boardPictureInPictureModeProvider = StateProvider<bool>((ref) => false);
