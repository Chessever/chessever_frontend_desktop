import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/time_control_classifier.dart';

void main() {
  group('classifyPgnTimeControlCategory', () {
    test('uses gamebase effective seconds boundaries', () {
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

    test('normalizes explicit buckets', () {
      expect(classifyPgnTimeControlCategory('Classical'), 'classical');
      expect(classifyPgnTimeControlCategory('standard'), 'classical');
      expect(classifyPgnTimeControlCategory('Rapid'), 'rapid');
      expect(classifyPgnTimeControlCategory('bullet'), 'blitz');
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
}
