import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/time_control_classifier.dart';

void main() {
  group('classifyPgnTimeControlCategory', () {
    test('preserves generic gamebase effective seconds boundaries', () {
      expect(classifyPgnTimeControlCategory('30'), 'blitz');
      expect(classifyPgnTimeControlCategory('60'), 'blitz');
      expect(classifyPgnTimeControlCategory('60+1'), 'blitz');
      expect(classifyPgnTimeControlCategory('120'), 'blitz');
      expect(classifyPgnTimeControlCategory('180'), 'blitz');
      expect(classifyPgnTimeControlCategory('300+2'), 'blitz');
      expect(classifyPgnTimeControlCategory('600+0'), 'blitz');
      expect(classifyPgnTimeControlCategory('601+0'), 'rapid');
      expect(classifyPgnTimeControlCategory('900+10'), 'rapid');
      expect(classifyPgnTimeControlCategory('3600'), 'rapid');
      expect(classifyPgnTimeControlCategory('5400+30'), 'classical');
      expect(
        classifyPgnTimeControlCategory('40/7200:20/3600:900+30'),
        'classical',
      );
    });

    test('uses Chess.com effective-clock speed boundaries', () {
      const chessCom = 'https://www.chess.com/game/live/123';
      expect(
        classifyPgnTimeControlCategory('30', site: chessCom),
        'ultrabullet',
      );
      expect(classifyPgnTimeControlCategory('31', site: chessCom), 'bullet');
      expect(classifyPgnTimeControlCategory('60+1', site: chessCom), 'bullet');
      expect(classifyPgnTimeControlCategory('179', site: chessCom), 'bullet');
      expect(classifyPgnTimeControlCategory('180', site: chessCom), 'blitz');
      expect(classifyPgnTimeControlCategory('599', site: chessCom), 'blitz');
      expect(classifyPgnTimeControlCategory('600', site: chessCom), 'rapid');
      expect(classifyPgnTimeControlCategory('3600', site: chessCom), 'rapid');
      expect(
        classifyPgnTimeControlCategory('3601', site: chessCom),
        'classical',
      );
    });

    test('normalizes explicit buckets', () {
      expect(classifyPgnTimeControlCategory('Classical'), 'classical');
      expect(classifyPgnTimeControlCategory('standard'), 'classical');
      expect(classifyPgnTimeControlCategory('Rapid'), 'rapid');
      expect(classifyPgnTimeControlCategory('bullet'), 'bullet');
      expect(classifyPgnTimeControlCategory('ultra bullet'), 'ultrabullet');
      expect(classifyPgnTimeControlCategory('ultra-bullet'), 'ultrabullet');
      expect(
        classifyPgnTimeControlCategory('correspondence'),
        'correspondence',
      );
      expect(classifyPgnTimeControlCategory('timeControl.blitz'), 'blitz');
    });
  });

  group('classifyFreeformTimeControlCategory', () {
    test('uses broadcast minute semantics', () {
      expect(classifyFreeformTimeControlCategory('3+2'), 'blitz');
      expect(classifyFreeformTimeControlCategory('5+0'), 'blitz');
      expect(classifyFreeformTimeControlCategory('15+10'), 'rapid');
      expect(classifyFreeformTimeControlCategory('90+30'), 'classical');
      expect(
        classifyFreeformTimeControlCategory('90 min + 30 sec / move'),
        'classical',
      );
      expect(
        classifyFreeformTimeControlCategory('25 min + 10 sec/move'),
        'rapid',
      );
      expect(classifyFreeformTimeControlCategory('g/3;+2'), 'blitz');
      expect(classifyFreeformTimeControlCategory('g60+30'), 'classical');
      expect(classifyFreeformTimeControlCategory('g25d5'), 'rapid');
      expect(classifyFreeformTimeControlCategory('1h50+10'), 'classical');
    });

    test('checks speed words slowest first', () {
      expect(
        classifyFreeformTimeControlCategory('classical & rapid'),
        'classical',
      );
      expect(classifyFreeformTimeControlCategory('rapid & blitz'), 'rapid');
    });
  });

  test('falls back to event and site only when the PGN tag is unusable', () {
    expect(
      classifyTimeControlCategory(
        null,
        event: 'Titled Swiss',
        site: 'ChessEver',
      ),
      'classical',
    );
    expect(
      classifyTimeControlCategory(
        null,
        event: 'Titled Tuesday',
        site: 'lichess.org',
      ),
      'blitz',
    );
    expect(
      classifyTimeControlCategory(
        '-',
        event: 'Chess.com RCC Swiss',
        site: 'chess.com',
      ),
      'rapid',
    );
    expect(
      classifyTimeControlCategory(
        null,
        event: 'Chess.com Classic Play-In',
        site: 'chess.com',
      ),
      'rapid',
    );
    expect(
      classifyTimeControlCategory(
        '900+10',
        event: 'World Blitz Championship',
        site: 'example.com',
      ),
      'rapid',
    );
  });

  test('uses Lichess effective-clock speed boundaries', () {
    const lichess = 'https://lichess.org/game-id';
    expect(classifyTimeControlCategory('15+0', site: lichess), 'ultrabullet');
    expect(classifyTimeControlCategory('29+0', site: lichess), 'ultrabullet');
    expect(classifyTimeControlCategory('30+0', site: lichess), 'bullet');
    expect(classifyTimeControlCategory('179+0', site: lichess), 'bullet');
    expect(classifyTimeControlCategory('180+0', site: lichess), 'blitz');
    expect(classifyTimeControlCategory('60+3', site: lichess), 'blitz');
    expect(classifyTimeControlCategory('479+0', site: lichess), 'blitz');
    expect(classifyTimeControlCategory('480+0', site: lichess), 'rapid');
    expect(classifyTimeControlCategory('300+5', site: lichess), 'rapid');
    expect(classifyTimeControlCategory('1499+0', site: lichess), 'rapid');
    expect(classifyTimeControlCategory('1500+0', site: lichess), 'classical');
    expect(
      classifyTimeControlCategory('21600+0', site: lichess),
      'correspondence',
    );
    expect(
      classifyTimeControlCategory(
        null,
        event: 'rated correspondence game',
        site: lichess,
      ),
      'correspondence',
    );
  });

  test('uses combined-file source provenance when Site is unavailable', () {
    expect(
      classifyTimeControlCategory('15+0', site: '?', source: 'lichess'),
      'ultrabullet',
    );
    expect(
      classifyTimeControlCategory('60+0', site: '?', source: 'chesscom'),
      'bullet',
    );
    expect(
      classifyTimeControlCategory(null, site: '?', source: 'chessever'),
      'classical',
    );
    expect(
      classifyTimeControlCategory(
        '-',
        event: 'Chess.com RCC Swiss',
        site: '?',
        source: 'chesscom',
      ),
      'rapid',
    );
  });
}
