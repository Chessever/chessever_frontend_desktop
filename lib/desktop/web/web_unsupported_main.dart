import 'package:flutter/widgets.dart';

/// dart2js entrypoint behind lib/main_web.dart.
///
/// The browser app needs WebAssembly GC (see lib/main_web.dart), so the
/// JavaScript fallback only explains which browsers work. It uses nothing but
/// the widgets layer to keep the fallback bundle small.
Future<void> webMain() async {
  runApp(const _UnsupportedBrowserApp());
}

class _UnsupportedBrowserApp extends StatelessWidget {
  const _UnsupportedBrowserApp();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF0C0C0E),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'ChessEver on the web needs a recent Chrome or Edge.\n'
            'You can also download the desktop app from chessever.com.',
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
            style: TextStyle(
              color: Color(0xFFFFFFFF),
              fontSize: 16,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}
