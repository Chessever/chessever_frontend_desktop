import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/web/web_url_sync.dart';

Future<void> startWebUrlSync(ProviderContainer container) =>
    WebUrlSync.start(container);
void stopWebUrlSync() => WebUrlSync.stop();
