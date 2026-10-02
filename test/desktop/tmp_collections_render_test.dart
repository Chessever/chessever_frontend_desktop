// Temporary: renders the Collections pane to PNG for a visual check.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chessever/desktop/panes/collections_pane.dart';
import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/widgets/collections/collection_actions.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _out = String.fromEnvironment('SHOTS');

class _Favs extends FavoriteEventsNotifier {
  @override
  Future<List<FavoriteEvent>> build() async => const <FavoriteEvent>[];
}

class _Sub extends SubscriptionNotifier {
  _Sub(super.initialState) : super.stub();
}

String _pgn(String w, String b, String res, String eco, String date, int we, int be) => '''
[Event "Candidates Tournament"]
[Site "Curacao"]
[Date "$date"]
[Round "3"]
[White "$w"]
[Black "$b"]
[Result "$res"]
[ECO "$eco"]
[WhiteElo "$we"]
[BlackElo "$be"]

1. e4 {The move Fischer called best by test.} c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Bg5 e6 7. f4 Be7 8. Qf3 Qc7 9. O-O-O Nbd7 10. g4 b5 {A sharp line.} 11. Bxf6 Nxf6 12. g5 Nd7 13. f5 Nc5 14. f6 gxf6 15. gxf6 Bf8 $res
''';

List<CollectionGameCard> _cards() {
  final rows = [
    ('Fischer, Robert James', 'Larsen, Bent', '1-0', 'B90', '1962.05.03', 2690, 2610, 'GM', 'USA', 'DEN'),
    ('Tal, Mikhail', 'Fischer, Robert James', '1/2-1/2', 'B92', '1962.05.05', 2705, 2690, 'GM', 'LAT', 'USA'),
    ('Petrosian, Tigran V', 'Keres, Paul', '1/2-1/2', 'D37', '1962.05.07', 2660, 2640, 'GM', 'ARM', 'EST'),
    ('Kortschnoj, Viktor', 'Geller, Efim P', '0-1', 'E97', '1962.05.09', 2650, 2655, 'GM', 'RUS', 'UKR'),
    ('Fischer, Robert James', 'Benko, Pal C', '1-0', 'B09', '1962.05.11', 2690, 2550, 'GM', 'USA', 'USA'),
    ('Keres, Paul', 'Tal, Mikhail', '1-0', 'C96', '1962.05.13', 2640, 2705, 'GM', 'EST', 'LAT'),
    ('Geller, Efim P', 'Petrosian, Tigran V', '1/2-1/2', 'C16', '1962.05.15', 2655, 2660, 'GM', 'UKR', 'ARM'),
    ('Larsen, Bent', 'Kortschnoj, Viktor', '0-1', 'A15', '1962.05.17', 2610, 2650, 'GM', 'DEN', 'RUS'),
  ];
  return [
    for (var i = 0; i < rows.length; i++)
      CollectionGameCard(
        id: 'g$i',
        orderIndex: i,
        white: CollectionPlayerSide(name: rows[i].$1, key: 'name:${rows[i].$1.toLowerCase()}', elo: rows[i].$6, title: rows[i].$8, fed: rows[i].$9),
        black: CollectionPlayerSide(name: rows[i].$2, key: 'name:${rows[i].$2.toLowerCase()}', elo: rows[i].$7, title: rows[i].$8, fed: rows[i].$10),
        result: rows[i].$3,
        eco: rows[i].$4,
        pgn: _pgn(rows[i].$1, rows[i].$2, rows[i].$3, rows[i].$4, rows[i].$5, rows[i].$6, rows[i].$7),
      ),
  ];
}

final _books = [
  const Collection(id: 'c1', slug: 'my-60-memorable-games', kind: CollectionKind.book, title: 'My 60 Memorable Games', author: 'Bobby Fischer', publisher: 'Simon & Schuster', publishedYear: 1969, gameCount: 60, viewCount: 1284, starCount: 37, access: CollectionAccess.free),
  const Collection(id: 'c2', slug: 'zurich-1953', kind: CollectionKind.book, title: 'Zurich International Chess Tournament 1953', author: 'David Bronstein', gameCount: 210, viewCount: 902, starCount: 21),
  const Collection(id: 'c3', slug: 'endgame-manual', kind: CollectionKind.book, title: 'Practical Rook Endgames', author: 'Elif Demir', annotator: 'Elif Demir', gameCount: 48, viewCount: 311, starCount: 4, access: CollectionAccess.free, note: 'Norway Chess 2025'),
  const Collection(id: 'c4', slug: 'candidates-1962', kind: CollectionKind.event, title: 'Candidates Tournament, Curacao 1962', author: 'ChessEver', location: 'Curacao', gameCount: 105, access: CollectionAccess.free),
  const Collection(id: 'c5', slug: 'najdorf-files', kind: CollectionKind.book, title: 'The Najdorf, 6.Bg5 Files', author: 'Tomas Varga', gameCount: 212, viewCount: 77, starCount: 0),
];

class _Reader implements CollectionsReader {
  @override
  VoidCallback holdFreshAccess(String slug) => () {};
  @override
  bool isFreshAccess(String slug) => false;
  @override
  Future<CollectionsPage> searchBooks(CollectionSearchQuery query, int offset) async => CollectionsPage(items: offset == 0 ? _books : const [], total: _books.length, limit: 40, offset: offset);
  @override
  Future<({List<CollectionAuthor> items, int total})> searchAuthors(CollectionSearchQuery query, int offset, {int limit = 40}) async => (
    items: offset == 0
        ? const [
          CollectionAuthor(id: 'a1', name: 'Bobby Fischer', bookCount: 1, gameCount: 60, about: 'Eleventh World Chess Champion.'),
          CollectionAuthor(id: 'a2', name: 'David Bronstein', bookCount: 1, gameCount: 210),
          CollectionAuthor(id: 'a3', name: 'Elif Demir', bookCount: 2, gameCount: 96),
          CollectionAuthor(id: 'a4', name: 'Tomas Varga', bookCount: 1, gameCount: 212),
        ]
        : const <CollectionAuthor>[],
    total: 4,
  );
  @override
  Future<Collection> fetchCollection(String slug) async {
    final base = _books.firstWhere((b) => b.slug == slug);
    return Collection(
      id: base.id, slug: base.slug, kind: base.kind, title: base.title, author: base.author, annotator: base.annotator,
      publisher: base.publisher, publishedYear: base.publishedYear, gameCount: base.gameCount, viewCount: base.viewCount,
      starCount: base.starCount, access: base.access,
      contentLocked: slug == 'zurich-1953',
      about: 'Fischer annotates sixty of his games, wins, draws and losses alike, with unusual candour.\n\nEach game opens with a short note on the occasion.',
      foreword: 'These games were chosen for what they taught me.',
      authorBio: 'Robert James Fischer was the eleventh World Chess Champion.',
      players: const ['Fischer, Robert James', 'Tal, Mikhail', 'Petrosian, Tigran V', 'Keres, Paul', 'Geller, Efim P', 'Larsen, Bent', 'Benko, Pal C'],
      sections: slug == 'zurich-1953'
          ? const [
            CollectionSection(id: 's1', kind: CollectionSectionKind.round, label: 'Round 1', gameCount: 7),
            CollectionSection(id: 's2', kind: CollectionSectionKind.round, label: 'Round 2', gameCount: 7),
            CollectionSection(id: 's3', kind: CollectionSectionKind.round, label: 'Round 3', title: 'The first rest day', gameCount: 7),
          ]
          : const [],
      events: const [
        CollectionEventRef(linkId: 'l1', title: 'Candidates Tournament 1962', location: 'Curacao', open: CollectionEventOpen.broadcast(groupBroadcastId: 'gb1')),
        CollectionEventRef(linkId: 'l2', title: 'Mar del Plata 1960', location: 'Argentina'),
      ],
    );
  }
  @override
  Future<List<CollectionGame>> fetchGames(String slug) => searchGames(slug);
  @override
  Future<List<CollectionGame>> searchGames(String slug, {CollectionSearchQuery search = const CollectionSearchQuery(), String? playerKey}) async {
    final cards = _cards();
    return [for (var i = 0; i < cards.length; i++) collectionGameFromCard(cards[i], i)!];
  }
  @override
  Future<List<CollectionPlayer>> fetchPlayers(String slug) async => const [
    CollectionPlayer(key: 'name:fischer, robert james', name: 'Fischer, Robert James', title: 'GM', fed: 'USA', bestElo: 2690, games: 3, wins: 2, draws: 1),
    CollectionPlayer(key: 'name:tal, mikhail', name: 'Tal, Mikhail', title: 'GM', fed: 'LAT', bestElo: 2705, games: 2, draws: 1, losses: 1),
    CollectionPlayer(key: 'name:keres, paul', name: 'Keres, Paul', title: 'GM', fed: 'EST', bestElo: 2640, games: 2, wins: 1, draws: 1),
    CollectionPlayer(key: 'name:petrosian, tigran v', name: 'Petrosian, Tigran V', title: 'GM', fed: 'ARM', bestElo: 2660, games: 2, draws: 2),
  ];
  @override
  Future<List<Collection>> fetchBooksForEvent(CollectionEventAnchors anchors) async => const [];
  @override
  Future<Map<String, dynamic>> recordView(String slug, String viewerId) async => {'viewCount': 1285, 'starCount': 37};
  @override
  Future<Map<String, dynamic>> recordStar(String slug, bool starred) async => {'viewCount': 1285, 'starCount': 38};
}

Future<void> _fonts() async {
  Future<void> load(String family, String path) async {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
    await loader.load();
  }
  await load('Geist', 'assets/fonts/Geist-VariableFont_wght.ttf');
  await load('Inter', 'assets/fonts/Geist-VariableFont_wght.ttf');
  await load('packages/forui/Inter', 'assets/fonts/Geist-VariableFont_wght.ttf');
  await load('MaterialIcons', '/Users/berkay/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Widget _host(GlobalKey key, Widget child, {bool premium = true, List<Override> extra = const []}) => ProviderScope(
  overrides: [
    collectionsReaderProvider.overrideWithValue(_Reader()),
    favoriteEventsProvider.overrideWith(_Favs.new),
    subscriptionProvider.overrideWith((ref) => _Sub(premium ? SubscriptionState(isSubscribed: true, expirationDate: DateTime.now().add(const Duration(days: 30))) : SubscriptionState())),
    ...extra,
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark().copyWith(textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Geist')),
    home: RepaintBoundary(key: key, child: Scaffold(backgroundColor: const Color(0xFF0C0C0E), body: DefaultTextStyle.merge(style: const TextStyle(fontFamily: 'Geist'), child: child))),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('collections pane', (tester) async {
    await tester.runAsync(_fonts);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(_host(key, const CollectionsPane()));
    await _settle(tester);
    await _shot(tester, key, '01-catalog');

    await tester.tap(find.text('My 60 Memorable Games'));
    await _settle(tester);
    await _shot(tester, key, '02-selected-preview');

    await tester.tap(find.text('Zurich International Chess Tournament 1953'));
    await _settle(tester);
    await _shot(tester, key, '03-locked-preview');

    await tester.tap(find.text('Elif Demir').first);
    await _settle(tester);
    await _shot(tester, key, '04-author');
  });

  for (final variant in ['games', 'about', 'players', 'locked']) {
    testWidgets('workspace $variant', (tester) async {
      await tester.runAsync(_fonts);
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      final slug = variant == 'locked' ? 'zurich-1953' : 'my-60-memorable-games';
      await tester.pumpWidget(
        _host(
          key,
          const CollectionWorkspacePane(tabId: 't1'),
          premium: variant != 'locked',
          extra: [
            collectionWorkspaceArgsByTabIdProvider.overrideWith(
              (ref) => {'t1': CollectionWorkspaceArgs(slug: slug, title: 'My 60 Memorable Games')},
            ),
          ],
        ),
      );
      await _settle(tester);
      if (variant == 'about') {
        await tester.tap(find.text('About'));
        await _settle(tester);
      } else if (variant == 'players') {
        await tester.tap(find.text('Players'));
        await _settle(tester);
      }
      await _shot(tester, key, '10-workspace-$variant');
    });
  }
}
