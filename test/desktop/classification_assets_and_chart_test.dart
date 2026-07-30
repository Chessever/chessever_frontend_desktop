import 'dart:io';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/screens/chessboard/game_review/classification_style.dart';
import 'package:chessever/screens/chessboard/game_review/evaluation_graph_markers.dart';
import 'package:chessever/screens/chessboard/widgets/nag_display.dart';
import 'package:chessever/services/lichess_move_annotations_service.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

/// Report-analysis classification set used on desktop today.
const _reportClassifications = <GameMoveClassification>[
  GameMoveClassification.brilliant,
  GameMoveClassification.missedWin,
  GameMoveClassification.mistake,
  GameMoveClassification.blunder,
  GameMoveClassification.inaccuracy,
  GameMoveClassification.goodMove,
  GameMoveClassification.bestMove,
];

/// First `stop-color` in the SVG is the badge gradient top (source of truth).
Color _gradientTopFromSvg(String assetPath) {
  final body = File(assetPath).readAsStringSync();
  final match = RegExp(r'stop-color="#([0-9A-Fa-f]{6})"').firstMatch(body);
  expect(
    match,
    isNotNull,
    reason: '$assetPath must declare a linearGradient stop-color',
  );
  final hex = int.parse(match!.group(1)!, radix: 16);
  return Color(0xFF000000 | hex);
}

GameReportLine _line({int? cp, int? mate}) => GameReportLine(
  moves: const ['e7e5'],
  depth: 12,
  centipawns: cp,
  mate: mate,
);

GameReportPosition _position({int? cp, int? mate}) =>
    GameReportPosition(fen: '8/8/8/8/8/8/8/8 w - - 0 1', lines: [_line(cp: cp, mate: mate)]);

GameReportMove _move({
  required int ply,
  required bool isWhite,
  GameMoveClassification? classification,
  int? cp,
}) => GameReportMove(
  ply: ply,
  san: isWhite ? 'e4' : 'e5',
  uci: isWhite ? 'e2e4' : 'e7e5',
  isWhite: isWhite,
  classification: classification,
  evaluation: _line(cp: cp ?? 0),
);

void main() {
  group('classification icon asset map', () {
    test('maps every report classification to mobile-aligned SVG path', () {
      final expected = <GameMoveClassification, String>{
        GameMoveClassification.brilliant: 'assets/svgs/brilliant.svg',
        GameMoveClassification.missedWin: 'assets/svgs/missed_win.svg',
        GameMoveClassification.mistake: 'assets/svgs/mistake.svg',
        GameMoveClassification.blunder: 'assets/svgs/blunder.svg',
        GameMoveClassification.inaccuracy: 'assets/svgs/inaccuracy.svg',
        GameMoveClassification.goodMove: 'assets/svgs/good.svg',
        GameMoveClassification.bestMove: 'assets/svgs/best.svg',
      };

      for (final classification in _reportClassifications) {
        final path = classificationIconAsset(classification);
        expect(
          path,
          expected[classification],
          reason: '$classification must resolve via the shipped path map',
        );
        final basename = path.split('/').last;
        // Filenames must omit the token "move" (good.svg not good_move.svg).
        expect(
          basename.split(RegExp(r'[_.]')).contains('move'),
          isFalse,
          reason:
              'classification asset filename must not contain token "move": $path',
        );
      }
    });

    test('good / best / book use short mobile names', () {
      expect(
        moveAnnotationIconAsset(LichessMoveAnnotationType.goodMove),
        'assets/svgs/good.svg',
      );
      expect(
        moveAnnotationIconAsset(LichessMoveAnnotationType.bestMove),
        'assets/svgs/best.svg',
      );
      expect(
        moveAnnotationIconAsset(LichessMoveAnnotationType.bookMove),
        'assets/svgs/book.svg',
      );
      expect(
        moveAnnotationIconAsset(LichessMoveAnnotationType.forced),
        'assets/svgs/forced_move.svg',
      );
    });

    test('every mapped classification asset file exists on disk', () {
      for (final classification in _reportClassifications) {
        final assetPath = classificationIconAsset(classification);
        final file = File(assetPath);
        expect(
          file.existsSync(),
          isTrue,
          reason: 'missing asset for $classification: $assetPath',
        );
        final body = file.readAsStringSync();
        expect(body.contains('<svg'), isTrue);
        expect(
          body.contains('linearGradient') || body.contains('url(#'),
          isTrue,
          reason: '$assetPath should be a self-contained gradient badge',
        );
      }
      for (final path in const [
        'assets/svgs/book.svg',
        'assets/svgs/forced_move.svg',
      ]) {
        expect(File(path).existsSync(), isTrue, reason: 'missing $path');
      }
    });

    test('classificationColor matches icon SVG gradient top', () {
      for (final classification in _reportClassifications) {
        final assetPath = classificationIconAsset(classification);
        final fromIcon = _gradientTopFromSvg(assetPath);
        final fromPalette = classificationColor(classification);
        expect(
          fromPalette,
          fromIcon,
          reason:
              '$classification palette must equal SVG top in $assetPath',
        );
      }
    });

    test('quality NAG text colors track the same classification palette', () {
      expect(
        getNagDisplay(1)!.color,
        moveAnnotationColor(LichessMoveAnnotationType.goodMove),
      );
      expect(
        getNagDisplay(2)!.color,
        moveAnnotationColor(LichessMoveAnnotationType.mistake),
      );
      expect(
        getNagDisplay(3)!.color,
        moveAnnotationColor(LichessMoveAnnotationType.brilliant),
      );
      expect(
        getNagDisplay(4)!.color,
        moveAnnotationColor(LichessMoveAnnotationType.blunder),
      );
      expect(
        getNagDisplay(6)!.color,
        moveAnnotationColor(LichessMoveAnnotationType.inaccuracy),
      );
      expect(
        getNagDisplay(7)!.color,
        moveAnnotationColor(LichessMoveAnnotationType.forced),
      );
    });
  });

  group('buildEvaluationGraphClassificationMarkers', () {
    test('returns one marker per non-null classification in ply order', () {
      final positions = [
        _position(cp: 0),
        _position(cp: 20),
        _position(cp: 15),
        _position(cp: 40),
        _position(cp: -120),
        _position(cp: 250),
      ];
      final moves = [
        _move(
          ply: 1,
          isWhite: true,
          classification: null,
          cp: 20,
        ),
        _move(
          ply: 2,
          isWhite: false,
          classification: null,
          cp: 15,
        ),
        _move(
          ply: 3,
          isWhite: true,
          classification: GameMoveClassification.bestMove,
          cp: 40,
        ),
        _move(
          ply: 4,
          isWhite: false,
          classification: GameMoveClassification.blunder,
          cp: -120,
        ),
        _move(
          ply: 5,
          isWhite: true,
          classification: GameMoveClassification.brilliant,
          cp: 250,
        ),
      ];

      final markers = buildEvaluationGraphClassificationMarkers(
        moves: moves,
        positions: positions,
      );

      expect(markers, hasLength(3));
      expect(
        markers.map((m) => m.classification).toList(),
        [
          GameMoveClassification.bestMove,
          GameMoveClassification.blunder,
          GameMoveClassification.brilliant,
        ],
      );
      expect(markers.map((m) => m.ply).toList(), [3, 4, 5]);
    });

    test('colors resolve through shared classificationColor palette', () {
      final classifications = [
        GameMoveClassification.inaccuracy,
        GameMoveClassification.mistake,
        GameMoveClassification.blunder,
        GameMoveClassification.bestMove,
        GameMoveClassification.brilliant,
        GameMoveClassification.goodMove,
        GameMoveClassification.missedWin,
      ];
      final positions = [
        _position(cp: 0),
        for (var i = 0; i < classifications.length; i++)
          _position(cp: 10 * (i + 1)),
      ];
      final moves = [
        for (var i = 0; i < classifications.length; i++)
          _move(
            ply: i + 1,
            isWhite: i.isEven,
            classification: classifications[i],
            cp: 10 * (i + 1),
          ),
      ];

      final markers = buildEvaluationGraphClassificationMarkers(
        moves: moves,
        positions: positions,
      );

      expect(markers, hasLength(classifications.length));
      for (var i = 0; i < classifications.length; i++) {
        expect(
          markers[i].color,
          classificationColor(classifications[i]),
          reason: '${classifications[i].name} must use shared palette',
        );
        expect(markers[i].classification, classifications[i]);
      }
    });

    test('empty inputs yield no markers', () {
      expect(
        buildEvaluationGraphClassificationMarkers(
          moves: const [],
          positions: [_position(cp: 0)],
        ),
        isEmpty,
      );
      expect(
        buildEvaluationGraphClassificationMarkers(
          moves: [
            _move(
              ply: 1,
              isWhite: true,
              classification: GameMoveClassification.bestMove,
            ),
          ],
          positions: const [],
        ),
        isEmpty,
      );
    });
  });
}
