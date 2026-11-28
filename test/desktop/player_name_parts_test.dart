import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/board_pgn_paste.dart';
import 'package:chessever/desktop/widgets/default_games_table.dart';
import 'package:chessever/desktop/widgets/desktop_compact_player_identity.dart';
import 'package:chessever/desktop/widgets/desktop_position_games_table.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/desktop/widgets/library/library_table_row_style.dart';
import 'package:chessever/repository/supabase/chess_player/chess_player_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/utils/gamebase_row_player_name.dart';
import 'package:chessever/utils/twic_player_enrichment.dart';

void main() {
  group('position games table names', () {
    // Stored spelling -> what the table shows.
    const cases = <String, String>{
      // Rule 2: a comma ends the surname.
      'Gukesh,D': 'Gukesh,D',
      'Gukesh, D': 'Gukesh,D',
      'Dommaraju, Gukesh': 'Dommaraju,G',
      'Carlsen, Magnus': 'Carlsen,M',
      'Carlsen,M': 'Carlsen,M',
      'Carlsen, Magnus (NOR)': 'Carlsen,M',
      // One stored "D, Gukesh" row: a one-letter surname is never swapped.
      'D, Gukesh': 'D,G',
      // Rule 3: one word with single initials is the surname, either order.
      'Gukesh D': 'Gukesh,D',
      'D Gukesh': 'Gukesh,D',
      'Gukesh D.': 'Gukesh,D',
      'Narayanan S L': 'Narayanan,S',
      'Narayanan S.L.': 'Narayanan,S',
      'Pranesh M': 'Pranesh,M',
      'Vachier-Lagrave M': 'Vachier-Lagrave,M',
      // Rule 1: a federation suffix, a title and spacing are noise.
      'Gukesh D (IND)': 'Gukesh,D',
      'GM Gukesh D': 'Gukesh,D',
      '  Gukesh   D  ': 'Gukesh,D',
      // Rule 4: shown as written, the last word never moved to the front.
      'Erigaisi Arjun': 'Erigaisi Arjun',
      'Ding Liren': 'Ding Liren',
      'Ding Liren (CHN)': 'Ding Liren',
      'Main line': 'Main line',
      'Magnus Carlsen': 'Magnus Carlsen',
      'Leon Luke Mendonca': 'Leon Luke Mendonca',
      'Stockfish 16': 'Stockfish 16',
      // Single words and placeholders.
      'Carlsen': 'Carlsen',
      'Im': 'Im',
      'White': '',
      '?': '',
      '': '',
    };

    for (final entry in cases.entries) {
      test('"${entry.key}" reads "${entry.value}"', () {
        expect(desktopPositionTablePlayerName(entry.key), entry.value);
      });
    }

    test('one player reads the same in every source spelling', () {
      final labels = {
        for (final raw in const [
          'Gukesh,D',
          'Gukesh, D',
          'Gukesh D',
          'D Gukesh',
          'Gukesh D (IND)',
        ])
          desktopPositionTablePlayerName(raw),
      };
      expect(labels, {'Gukesh,D'});
    });
  });

  group('desktopCompactPlayerNameParts', () {
    test('reads the surname and initial by rules 1-3', () {
      final parts = desktopCompactPlayerNameParts('Gukesh D (IND)');
      expect(parts.lastName, 'Gukesh');
      expect(parts.firstInitial, 'D');
      expect(parts.isAsWritten, isFalse);
      expect(parts.name, 'Gukesh D');
      expect(parts.displayLabel, 'Gukesh, D.');
    });

    test('keeps other comma-less names whole for full labels', () {
      final parts = desktopCompactPlayerNameParts('Ding Liren');
      expect(parts.isAsWritten, isTrue);
      expect(parts.name, 'Ding Liren');
      expect(parts.displayLabel, 'Ding Liren');
      // The last-word guess stays on the parts for the labels that have room
      // for one word only: tab titles and the card's single-dot overflow.
      expect(parts.lastName, 'Liren');
    });

    test('drops placeholders unless asked to keep them', () {
      expect(desktopCompactPlayerNameParts('White').lastName, '');
      expect(
        desktopCompactPlayerNameParts('White', keepPlaceholders: true).lastName,
        'White',
      );
    });

    test('game cards read rules 1-3 and show other names as written', () {
      expect(desktopCompactPlayerName('Gukesh,D'), 'Gukesh, D.');
      expect(desktopCompactPlayerName('Gukesh D (IND)'), 'Gukesh, D.');
      expect(desktopCompactPlayerName('Narayanan S L'), 'Narayanan, S.');
      expect(desktopCompactPlayerName('Erigaisi Arjun'), 'Erigaisi Arjun');
      expect(desktopCompactPlayerName('Ding Liren'), 'Ding Liren');
      expect(desktopCompactPlayerName('Hou Yifan'), 'Hou Yifan');
      expect(desktopCompactPlayerName('Magnus Carlsen'), 'Magnus Carlsen');
      expect(desktopCompactPlayerName('GM Magnus Carlsen'), 'Magnus Carlsen');
    });
  });

  group('player-profile games table', () {
    test('formats Surname, I. and keeps unreadable names whole', () {
      expect(defaultGamePlayerName('Gukesh D'), 'Gukesh, D.');
      expect(defaultGamePlayerName('Gukesh,D'), 'Gukesh, D.');
      expect(defaultGamePlayerName('Gukesh D (IND)'), 'Gukesh, D.');
      expect(defaultGamePlayerName('Erigaisi Arjun'), 'Erigaisi Arjun');
      expect(defaultGamePlayerName('Black'), '');
    });
  });

  group('surname-only labels', () {
    test('read rules 1-3 and keep the last word for other names', () {
      expect(desktopPlayerSurname('Gukesh D'), 'Gukesh');
      expect(desktopPlayerSurname('D Gukesh'), 'Gukesh');
      expect(desktopPlayerSurname('Gukesh,D'), 'Gukesh');
      expect(desktopPlayerSurname('Gukesh D (IND)'), 'Gukesh');
      expect(desktopPlayerSurname('Narayanan S L'), 'Narayanan');
      expect(desktopPlayerSurname('Carlsen, Magnus'), 'Carlsen');
      expect(desktopPlayerSurname('Magnus Carlsen'), 'Carlsen');
      expect(desktopPlayerSurname('Leon Luke M'), 'Luke');
      expect(desktopPlayerSurname('Carlsen'), 'Carlsen');
      expect(desktopPlayerSurname('White'), 'White');
      expect(desktopPlayerSurname('   '), '');
    });

    test('drag chips name both surnames', () {
      expect(gameDragLabel('Gukesh D', 'So,W'), 'Gukesh vs So');
      expect(gameDragLabel('Magnus Carlsen', 'Ding Liren'), 'Carlsen vs Liren');
      expect(gameDragLabel('', ''), 'Game');
    });
  });

  group('Library table', () {
    test('reads TWIC "Gukesh,D" as a personal name', () {
      expect(libraryPlayerNameIsPersonal('Gukesh,D'), isTrue);
      expect(libraryStandardTablePlayerName('Gukesh,D'), 'Gukesh, D.');
      expect(libraryStandardTablePlayerName('Carlsen,Magnus'), 'Carlsen, M.');
    });

    test('shows names without one surname as written', () {
      // TWIC "Ding,L" and a broadcast "Ding Liren" never read in two orders.
      expect(libraryStandardTablePlayerName('Ding,L'), 'Ding, L.');
      expect(libraryStandardTablePlayerName('Ding Liren'), 'Ding Liren');
      expect(
        libraryStandardTablePlayerName('Erigaisi Arjun'),
        'Erigaisi Arjun',
      );
      expect(libraryStandardTablePlayerName('Hou Yifan'), 'Hou Yifan');
    });

    test('drops a federation only from a name the rules read', () {
      expect(libraryStandardTablePlayerName('Gukesh D (IND)'), 'Gukesh, D.');
      expect(
        libraryStandardTablePlayerName('Erigaisi Arjun (IND)'),
        'Erigaisi Arjun (IND)',
      );
      expect(
        libraryStandardTablePlayerName('Main Line (with note)'),
        'Main Line (with note)',
      );
    });
  });

  group('clipboard PGN citation', () {
    test('cites FIDE and TWIC spellings alike', () {
      String label(String white, String black) => clipboardPgnSourceLabel('''
[White "$white"]
[Black "$black"]
[Result "1-0"]

1. e4 e5 1-0
''');

      expect(label('Gukesh D', 'So,W'), '1-0 Gukesh,D-So,W');
      expect(label('Gukesh,D', 'So, Wesley'), '1-0 Gukesh,D-So,W');
      expect(
        label('Magnus Carlsen', 'D Gukesh'),
        '1-0 Magnus Carlsen-Gukesh,D',
      );
    });

    test('cites a name without one surname as written', () {
      const pgn = '''
[White "Ding Liren"]
[Black "Gukesh D"]
[WhiteElo "2762"]
[BlackElo "2783"]
[Result "1/2-1/2"]

1. d4 d5 1/2-1/2
''';
      expect(
        clipboardPgnSourceLabel(pgn),
        '½-½ Ding Liren (2762)-Gukesh,D (2783)',
      );
    });
  });

  group('gamebaseRowPlayerName', () {
    test('prefers the FIDE spelling the server sends', () {
      final row = <String, dynamic>{
        'white': 'Dommaraju, Gukesh',
        'whiteCanonicalName': 'Gukesh D',
        'black': 'So,W',
        'blackCanonicalName': null,
      };
      expect(gamebaseRowPlayerName(row, isWhite: true), 'Gukesh D');
      expect(gamebaseRowPlayerName(row, isWhite: false), 'So,W');
      expect(gamebaseRowCanonicalPlayerName(row, isWhite: false), isNull);
    });

    test('falls back to the stored name without the field', () {
      expect(
        gamebaseRowPlayerName(const {'white': ' Gukesh,D '}, isWhite: true),
        'Gukesh,D',
      );
      expect(
        gamebaseRowPlayerName(const {
          'white': '',
          'whiteName': 'Gukesh D',
          'whiteCanonicalName': '  ',
        }, isWhite: true),
        'Gukesh D',
      );
      expect(gamebaseRowPlayerName(const {}, isWhite: false), '');
    });
  });

  group('PlayerCard.canonicalName', () {
    PlayerCard card(String name, {String? canonicalName}) => PlayerCard(
      name: name,
      federation: '',
      title: '',
      rating: 0,
      countryCode: '',
      team: null,
      fideId: 46616543,
      canonicalName: canonicalName,
    );

    test('shows the FIDE spelling and keeps the stored name', () {
      final gukesh = card('Dommaraju, Gukesh', canonicalName: 'Gukesh D');
      expect(gukesh.name, 'Dommaraju, Gukesh');
      expect(gukesh.displayName, 'Gukesh D');
      expect(defaultGamePlayerName(gukesh.displayName), 'Gukesh, D.');
    });

    test('falls back to the stored name without one', () {
      expect(card('Gukesh,D').displayName, 'Gukesh,D');
      expect(card('Gukesh,D', canonicalName: '  ').displayName, 'Gukesh,D');
    });

    test('survives copyWith and chess_players enrichment', () {
      final gukesh = card('Dommaraju, Gukesh', canonicalName: 'Gukesh D');
      expect(gukesh.copyWith(rating: 2783).canonicalName, 'Gukesh D');
      final enriched = enrichPlayerCardFromChessPlayers(gukesh, const {
        46616543: ChessPlayer(fideid: 46616543, name: 'Gukesh D', rating: 2783),
      });
      expect(enriched.name, 'Dommaraju, Gukesh');
      expect(enriched.displayName, 'Gukesh D');
      expect(enriched == gukesh.copyWith(rating: 2783), isTrue);
      expect(gukesh == card('Dommaraju, Gukesh'), isFalse);
    });

    test('game cards show it, the model keeps the stored name', () {
      final game = GamesTourModel(
        gameId: 'g1',
        whitePlayer: card('Dommaraju, Gukesh', canonicalName: 'Gukesh D'),
        blackPlayer: card('So,W'),
        whiteTimeDisplay: '',
        blackTimeDisplay: '',
        whiteClockCentiseconds: 0,
        blackClockCentiseconds: 0,
        gameStatus: GameStatus.draw,
        roundId: 'r1',
        tourId: 't1',
      );
      final data = GameCardData.fromGamesTourModel(game);
      expect(data.whiteName, 'Gukesh D');
      expect(data.blackName, 'So,W');
      expect(game.whitePlayer.name, 'Dommaraju, Gukesh');
    });
  });
}
