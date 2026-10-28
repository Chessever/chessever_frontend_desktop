import 'package:flutter/material.dart';

/// JavaScript fallback for browsers without WebAssembly GC. It must not import
/// the app: dartchess does not compile to JavaScript.
Future<void> runChessEverWeb() async {
  runApp(const _UnsupportedBrowserApp());
}

class _UnsupportedBrowserApp extends StatelessWidget {
  const _UnsupportedBrowserApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ChessEver',
      home: Scaffold(
        backgroundColor: const Color(0xFF0F0F0F),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This browser cannot run ChessEver.',
                    style: TextStyle(
                      color: Color(0xFFF2F2F2),
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Open app.chessever.com in a current version of Chrome, '
                    'Edge, Firefox or Safari, or download the desktop app '
                    'from chessever.com.',
                    style: TextStyle(
                      color: Color(0xFFA6A6A6),
                      fontSize: 15,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
