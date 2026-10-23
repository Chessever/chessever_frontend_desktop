import 'package:flutter/foundation.dart';

import 'package:chessever/utils/platform/io_platform.dart';

/// Whether shortcuts and their labels follow macOS conventions (⌘ rather than
/// Ctrl). Natively this is the host OS; in a browser tab it is the visitor's
/// operating system, which Flutter derives from the user agent.
bool get desktopUsesMacKeyConventions =>
    kIsWeb ? defaultTargetPlatform == TargetPlatform.macOS : Platform.isMacOS;
