import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/engine/game_report_book_lookup.dart';
import 'package:chessever/desktop/services/play/engine_installer.dart';
import 'package:chessever/desktop/services/play/play_live_move_classifier.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';

/// The report's verdict on every move of one Play tab's game, judged while
/// the game is played. It lives while the tab has a game (its engine is
/// closed when the game is cleared), so a hidden tab keeps its marks and
/// does not search the game again when it comes back.
final playLiveMoveJudgementsProvider = StateNotifierProvider.autoDispose.family<
  PlayLiveMoveClassifier,
  PlayLiveMoveJudgements,
  String
>((ref, tabId) {
  // Move marks are a help module: off, nothing is searched and no mark is
  // shown. Turning them on mid-game judges the game so far, then follows it.
  final liveHelp = ref.watch(
    playHelpModulesProvider.select((m) => m.moveMarks),
  );
  PlayLiveUciEvaluator? engine;
  final classifier = PlayLiveMoveClassifier(
    openEvaluator: () async {
      if (!liveHelp) return null;
      final path = _stockfishPath(ref, tabId);
      if (path == null) return null;
      engine = await PlayLiveUciEvaluator.open(
        path,
        arguments: engineLaunchArguments(BotEngineKind.stockfish, path, 0),
        workingDirectory: engineWorkingDirectory(path),
      );
      return engine?.evaluate;
    },
    closeEvaluator: () async => engine?.close(),
    bookLookup: gamebaseBookLookup(ref.read(gamebaseRepositoryProvider)),
  );
  // Alive for as long as the tab has a game, watched or not: the shell
  // unmounts hidden tabs, and coming back must not search the game again.
  final keepAlive = ref.keepAlive();
  ref.listen<bool>(
    playSessionArgsByTabIdProvider.select((m) => m.containsKey(tabId)),
    (_, hasGame) {
      if (!hasGame) keepAlive.close();
    },
    fireImmediately: true,
  );
  if (!liveHelp) return classifier;
  ref.listen<PlaySessionState>(playSessionProviderFor(tabId), (previous, next) {
    if (previous != null &&
        identical(previous.history, next.history) &&
        previous.startingFen == next.startingFen) {
      return;
    }
    classifier.sync(playLiveClassifierGame(next.startingFen, next.history));
  }, fireImmediately: true);
  return classifier;
});

/// Stockfish for judging moves: the installed one, else the bot's own when
/// the bot is Stockfish. Leela and Maia are never used to judge: the report
/// is Stockfish's.
String? _stockfishPath(Ref ref, String tabId) {
  final install = ref.read(engineInstallProvider(BotEngineKind.stockfish));
  if (engineReady(install)) return install.binaryPath;
  final args = ref.read(playSessionArgsByTabIdProvider)[tabId];
  if (args != null &&
      args.config.engine == BotEngineKind.stockfish &&
      args.engineBinaryPath.trim().isNotEmpty) {
    return args.engineBinaryPath;
  }
  return null;
}
