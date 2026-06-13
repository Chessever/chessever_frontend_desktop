import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/library_import_buffer.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';

/// Inline preview surfaced inside the Library pane while a PGN import is
/// staged in [libraryImportBufferProvider]. Mirrors the role of the mobile
/// `PgnImportPreviewScreen` (a pushed full-screen route) — but on desktop
/// we fold it into the existing pane so the user keeps their library
/// context while choosing what to do with the imported games.
class LibraryPgnPreviewPanel extends HookConsumerWidget {
  const LibraryPgnPreviewPanel({super.key, required this.buffer});

  final LibraryImportBuffer buffer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchController = useTextEditingController();
    final query = useState<String>('');

    final filtered = useMemoized<List<({ChessGame game, int index})>>(() {
      final q = query.value.trim().toLowerCase();
      final out = <({ChessGame game, int index})>[];
      for (var i = 0; i < buffer.games.length; i++) {
        final g = buffer.games[i];
        if (q.isEmpty || _matches(g, q)) {
          out.add((game: g, index: i));
        }
      }
      return out;
    }, [buffer.games, query.value]);

    Future<void> onSave() async {
      final outcome = await showLibrarySaveToFolderDialog(
        context: context,
        ref: ref,
        games: buffer.games,
        suggestedFolderId: buffer.suggestedFolderId,
        sourceLabel: buffer.sourceLabel,
      );
      if (outcome != null && outcome.didSave) {
        if (!context.mounted) return;
        ref.read(libraryImportBufferProvider.notifier).clear();
        showDesktopToast(context, outcome.toToastMessage());
      }
    }

    void onOpenOnBoard(ChessGame game, {bool focus = true}) {
      final pgn = exportGameToPgn(game).trim();
      if (pgn.isEmpty) return;
      openBoardGameTab(
        ref,
        _boardArgsFor(
          game,
          label: _titleFor(game),
          pgn: pgn,
          databaseTitle: buffer.sourceLabel,
          databaseGames: _summariesFromGames(
            _previewBoardContextGames(game, buffer.games),
          ),
        ),
        reuseExisting: false,
        focus: focus,
      );
    }

    void onDiscard() {
      ref.read(libraryImportBufferProvider.notifier).clear();
    }

    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        color: kBackgroundColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              source: buffer.sourceLabel,
              gameCount: buffer.games.length,
              onSave: onSave,
              onDiscard: onDiscard,
            ),
            const FDivider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: DesktopSearchField(
                controller: searchController,
                hintText: 'Search white, black, event, opening…',
                onChanged: (v) => query.value = v,
                onClear: () => query.value = '',
              ),
            ),
            Expanded(
              child:
                  filtered.isEmpty
                      ? const _EmptyMatch()
                      : ListView.builder(
                        physics: const DesktopScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final entry = filtered[i];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: DesktopGameCard(
                              data: GameCardData.fromChessGame(
                                entry.game,
                                subtitle: _subtitleFor(entry.game),
                              ),
                              onTap: () => onOpenOnBoard(entry.game),
                              dragPayload: GameTabDragPayload(
                                id: entry.game.gameId,
                                label: _titleFor(entry.game),
                                spawn:
                                    (_, {required focus}) async =>
                                        onOpenOnBoard(entry.game, focus: focus),
                              ),
                              layout: DesktopCardLayout.list,
                            ),
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }

  static bool _matches(ChessGame game, String q) {
    final md = game.metadata;
    final fields = [
      md['White'],
      md['Black'],
      md['Event'],
      md['Site'],
      md['Opening'],
      md['ECO'],
      md['Round'],
    ];
    for (final f in fields) {
      if (f is String && f.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  static String _titleFor(ChessGame game) {
    final w = (game.metadata['White']?.toString().trim() ?? '');
    final b = (game.metadata['Black']?.toString().trim() ?? '');
    return '${w.isEmpty ? 'White' : w} vs ${b.isEmpty ? 'Black' : b}';
  }

  static String? _subtitleFor(ChessGame game) {
    final ev = game.metadata['Event']?.toString().trim() ?? '';
    final round = game.metadata['Round']?.toString().trim() ?? '';
    final date = game.metadata['Date']?.toString().trim() ?? '';
    final parts = <String>[];
    if (ev.isNotEmpty) parts.add(ev);
    if (round.isNotEmpty && round != '?') parts.add('Round $round');
    if (date.isNotEmpty && date != '????.??.??') parts.add(date);
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

BoardTabGameArgs _boardArgsFor(
  ChessGame game, {
  required String label,
  required String pgn,
  String databaseTitle = '',
  List<TournamentGameSummary> databaseGames = const <TournamentGameSummary>[],
}) {
  final md = game.metadata;
  String s(String key) => (md[key]?.toString() ?? '').trim();
  int rating(String key) => int.tryParse(s(key)) ?? 0;
  int? fideId(String key) {
    final value = rating(key);
    return value > 0 ? value : null;
  }

  return BoardTabGameArgs(
    pgn: pgn,
    label: label,
    whiteName: s('White'),
    blackName: s('Black'),
    whiteFederation:
        s('WhiteFederation').isNotEmpty ? s('WhiteFederation') : s('WhiteFed'),
    blackFederation:
        s('BlackFederation').isNotEmpty ? s('BlackFederation') : s('BlackFed'),
    whiteTitle: s('WhiteTitle'),
    blackTitle: s('BlackTitle'),
    whiteRating: rating('WhiteElo'),
    blackRating: rating('BlackElo'),
    whiteFideId: fideId('WhiteFideId'),
    blackFideId: fideId('BlackFideId'),
    fenSeed: game.startingFen,
    databaseTitle: databaseTitle,
    databaseGames:
        databaseGames.isEmpty ? [_summaryFromGame(game)] : databaseGames,
    gameListSelectedId: game.gameId,
  );
}

List<TournamentGameSummary> _summariesFromGames(List<ChessGame> games) {
  return [for (final game in games) _summaryFromGame(game)];
}

const int _kPreviewBoardContextRadius = 100;

List<ChessGame> _previewBoardContextGames(
  ChessGame selected,
  List<ChessGame> games,
) {
  if (games.isEmpty) return <ChessGame>[selected];

  final selectedIndex = games.indexWhere(
    (game) => game.gameId == selected.gameId,
  );
  if (selectedIndex < 0) return <ChessGame>[selected];

  final start =
      selectedIndex - _kPreviewBoardContextRadius < 0
          ? 0
          : selectedIndex - _kPreviewBoardContextRadius;
  final end =
      selectedIndex + _kPreviewBoardContextRadius + 1 > games.length
          ? games.length
          : selectedIndex + _kPreviewBoardContextRadius + 1;
  return games.sublist(start, end);
}

TournamentGameSummary _summaryFromGame(ChessGame game) {
  final md = game.metadata;
  String s(String key) => (md[key]?.toString() ?? '').trim();
  int rating(String key) => int.tryParse(s(key)) ?? 0;
  int? fideId(String key) {
    final value = rating(key);
    return value > 0 ? value : null;
  }

  final pgn = exportGameToPgn(game).trim();
  final lastFen =
      game.mainline.isNotEmpty ? game.mainline.last.fen : game.startingFen;
  return TournamentGameSummary(
    id: game.gameId,
    name: LibraryPgnPreviewPanel._titleFor(game),
    whitePlayer: s('White'),
    blackPlayer: s('Black'),
    whiteFederation:
        s('WhiteFederation').isNotEmpty ? s('WhiteFederation') : s('WhiteFed'),
    blackFederation:
        s('BlackFederation').isNotEmpty ? s('BlackFederation') : s('BlackFed'),
    whiteTitle: s('WhiteTitle'),
    blackTitle: s('BlackTitle'),
    whiteRating: rating('WhiteElo'),
    blackRating: rating('BlackElo'),
    whiteFideId: fideId('WhiteFideId'),
    blackFideId: fideId('BlackFideId'),
    hasPgn: pgn.isNotEmpty,
    pgn: pgn.isEmpty ? null : pgn,
    fen: lastFen,
    roundLabel: s('Round'),
    status: _statusFromResult(s('Result')),
    openingName: s('Opening').isNotEmpty ? s('Opening') : s('ECO'),
    hasStarted: game.mainline.isNotEmpty,
  );
}

GameStatus _statusFromResult(String result) {
  switch (result.replaceAll('½', '1/2').trim()) {
    case '1-0':
      return GameStatus.whiteWins;
    case '0-1':
      return GameStatus.blackWins;
    case '1/2-1/2':
      return GameStatus.draw;
    case '*':
      return GameStatus.ongoing;
    default:
      return GameStatus.unknown;
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.source,
    required this.gameCount,
    required this.onSave,
    required this.onDiscard,
  });

  final String source;
  final int gameCount;
  final VoidCallback onSave;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kPrimaryColor.withValues(alpha: 0.35)),
            ),
            child: const Icon(
              Icons.file_download_outlined,
              size: 18,
              color: kPrimaryColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Import preview',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$gameCount '
                  '${gameCount == 1 ? 'game' : 'games'} from $source — '
                  'click a row to play through, save to add into a folder.',
                  style: const TextStyle(color: kLightGreyColor, fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          DesktopDialogButton(
            label: 'Discard',
            tooltip: 'Discard preview',
            onPress: onDiscard,
          ),
          const SizedBox(width: 8),
          DesktopDialogButton(
            label: 'Save to folder...',
            tone: DesktopDialogButtonTone.primary,
            icon: Icons.save_alt_rounded,
            onPress: onSave,
          ),
        ],
      ),
    );
  }
}

class _EmptyMatch extends StatelessWidget {
  const _EmptyMatch();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 28, color: kLightGreyColor),
            SizedBox(height: 12),
            Text(
              'No imported games match the search.',
              style: TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
