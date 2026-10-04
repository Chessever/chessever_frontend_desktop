import 'dart:io';
import 'dart:ui' as ui;

import 'package:chessever/desktop/panes/collections_pane.dart';
import 'package:chessever/desktop/panes/library_pane.dart'
    show libraryReadOnlyGamesFit;
import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/collections_catalog.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/collections/collection_actions.dart';
import 'package:chessever/desktop/widgets/collections/collection_catalog_row.dart';
import 'package:chessever/desktop/widgets/collections/collection_reading_views.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_icon.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/library/library_catalog_row.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/svg_asset.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/collections_fakes.dart';

/// Wide enough for the Library's games table to lay out all its columns.
const Size _window = Size(2600, 1400);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child, {
  required FakeCollectionsReader reader,
  bool premium = true,
  List<Override> overrides = const [],
  Size window = _window,
  List<FavoriteEvent> starred = const [],
  bool toaster = false,
  double pixelRatio = 1,
  ThemeData? theme,
  GlobalKey? capture,
}) async {
  tester.view.physicalSize = window * pixelRatio;
  tester.view.devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      collectionsReaderProvider.overrideWithValue(reader),
      favoriteEventsProvider.overrideWith(() => FakeFavoriteEvents(starred)),
      subscriptionProvider.overrideWith(
        (ref) =>
            FakeSubscription(premium ? premiumSubscription : freeSubscription),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme,
        // The shell's toaster, for the tests that read a toast. [capture]
        // sits above it, so a screenshot has tooltips and toasts.
        builder:
            toaster
                ? (context, app) => RepaintBoundary(
                  key: capture,
                  child: FTheme(
                    data: FThemes.zinc.dark,
                    child: FToaster(child: app!),
                  ),
                )
                : null,
        home: Scaffold(body: child),
      ),
    ),
  );
  await _settle(tester);
  return container;
}

/// Spinners never settle, so the tests pump a fixed while instead.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(finder);
  await _settle(tester);
}

Finder _row(String title) => find.ancestor(
  of: find.textContaining(title, findRichText: true),
  matching: find.byType(CollectionCatalogRow),
);

/// One of the phone's glyphs, by its asset.
Finder _glyph(String asset) => find.byWidgetPredicate(
  (widget) => widget is DesktopIcon && widget.assetPath == asset,
);

Finder _in(Finder row, Finder what) => find.descendant(of: row, matching: what);

/// The square of [row]'s star that takes the pointer.
Finder _starSlot(Finder row) =>
    find
        .ancestor(
          of: _in(row, find.byType(DesktopIcon)),
          matching: find.byType(RawGestureDetector),
        )
        .first;

/// The catalog's titles from the top, as they are on screen.
List<String> _titles(WidgetTester tester) {
  final rows = tester.widgetList<CollectionCatalogRow>(
    find.byType(CollectionCatalogRow),
  );
  final byTop = {
    for (final row in rows)
      tester.getTopLeft(find.byWidget(row)).dy: row.collection.title,
  };
  return [for (final top in byTop.keys.toList()..sort()) byTop[top]!];
}

/// Where a text is drawn, not the box it was given: a count set from the
/// right fills its column, and only its glyphs say where it ends. [of]
/// narrows it to one part of the text.
Rect _ink(WidgetTester tester, Finder finder, {String? of}) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final text = paragraph.text.toPlainText();
  final start = of == null ? 0 : text.indexOf(of);
  final end = of == null ? text.length : start + of.length;
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  return boxes
      .map((box) => box.toRect())
      .reduce((a, b) => a.expandToInclude(b))
      .shift(paragraph.localToGlobal(Offset.zero));
}

typedef _PixelTest = bool Function(int r, int g, int b, int a);

/// Any red at all, however faint: the old star's fill was a 12% tint.
bool _isRed(int r, int g, int b, int a) => a > 8 && r > 2 * g && r > 2 * b;

/// The phone's star gold (#FFD700).
bool _isGold(int r, int g, int b, int a) =>
    a > 200 && r > 230 && g > 180 && g < 235 && b < 80;

/// A stroke of the outline star or the chevron, on the dark table.
bool _isLit(int r, int g, int b, int a) => a > 100 && r > 110 && b > 110;

/// What a layer painted, as premultiplied RGBA at twice the logical size.
class _Painted {
  _Painted(this.bytes, this.width, this.height, this.origin);

  final ByteData bytes;
  final int width;
  final int height;

  /// Where the image's top left corner is on screen.
  final Offset origin;

  static const double ratio = 2;

  /// How many pixels inside [within] pass [test], and the box they fill, in
  /// screen coordinates.
  ({int count, Rect? bounds}) where(Rect within, _PixelTest test) {
    final area = within.shift(-origin);
    // Every pixel the area touches; a hair of rounding touches none.
    int first(double edge) => (edge * ratio + 0.001).floor();
    int last(double edge) => (edge * ratio - 0.001).ceil();
    final left = first(area.left).clamp(0, width);
    final right = last(area.right).clamp(0, width);
    final top = first(area.top).clamp(0, height);
    final bottom = last(area.bottom).clamp(0, height);
    var count = 0;
    int? minX, maxX, minY, maxY;
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        final at = (y * width + x) * 4;
        if (!test(
          bytes.getUint8(at),
          bytes.getUint8(at + 1),
          bytes.getUint8(at + 2),
          bytes.getUint8(at + 3),
        )) {
          continue;
        }
        count++;
        minX = minX == null || x < minX ? x : minX;
        maxX = maxX == null || x > maxX ? x : maxX;
        minY = minY == null || y < minY ? y : minY;
        maxY = maxY == null || y > maxY ? y : maxY;
      }
    }
    return (
      count: count,
      bounds:
          minX == null
              ? null
              : Rect.fromLTRB(
                minX / ratio,
                minY! / ratio,
                (maxX! + 1) / ratio,
                (maxY! + 1) / ratio,
              ).shift(origin),
    );
  }
}

/// The pixels of the layer [finder] is painted on.
Future<_Painted> _painted(WidgetTester tester, Finder finder) async {
  RenderObject? layer = tester.renderObject(finder);
  while (layer != null && layer is! RenderRepaintBoundary) {
    layer = layer.parent;
  }
  final boundary = layer! as RenderRepaintBoundary;
  final origin = boundary.localToGlobal(Offset.zero);
  late final _Painted painted;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _Painted.ratio);
    final bytes = await image.toByteData();
    painted = _Painted(bytes!, image.width, image.height, origin);
    image.dispose();
  });
  return painted;
}

/// A mouse resting on [finder].
Future<TestGesture> _hover(WidgetTester tester, Finder finder) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(finder));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return mouse;
}

/// Where the fixture's screenshots go; unset, it does not run.
final String? _shots = Platform.environment['COLLECTIONS_TABLE_SHOTS'];

/// The shell's dark theme as a Mac builds it, so text asks for the system
/// font the fixture loads.
ThemeData get _macTheme => ThemeData(
  brightness: Brightness.dark,
  platform: TargetPlatform.macOS,
  colorScheme: ColorScheme.fromSeed(
    seedColor: kPrimaryColor,
    brightness: Brightness.dark,
    primary: kPrimaryColor,
    onPrimary: kWhiteColor,
    surface: kBlack2Color,
    onSurface: kWhiteColor,
  ),
  scaffoldBackgroundColor: kBackgroundColor,
  useMaterial3: true,
);

/// Real typefaces instead of the test font's blocks: the Mac system font the
/// shell's text is set in, forui's own for tooltips and toasts, and the
/// Material icons.
Future<void> _loadFixtureFonts() async {
  Future<ByteData> file(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  await (FontLoader('.AppleSystemUIFont')
    ..addFont(file('/System/Library/Fonts/SFNS.ttf'))).load();
  await (FontLoader('packages/forui/Inter')
        ..addFont(
          rootBundle.load(
            'packages/forui/assets/fonts/inter/Inter-Regular.ttf',
          ),
        )
        ..addFont(
          rootBundle.load('packages/forui/assets/fonts/inter/Inter-Bold.ttf'),
        ))
      .load();
  await (FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

Future<void> _shoot(WidgetTester tester, GlobalKey capture, String name) async {
  final boundary =
      capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(_shots!).create(recursive: true);
    await File('$_shots/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

/// A catalog with what a real one holds: long and short titles, an event, a
/// single game, large counts, and rows nobody starred.
const List<Collection> _fixtureBooks = [
  Collection(
    id: 'f1',
    slug: 'my-60-memorable-games',
    kind: CollectionKind.book,
    title: 'My 60 Memorable Games',
    author: 'Bobby Fischer',
    authorId: 'account:0123456789abcdef0123456789abcdef',
    gameCount: 60,
    viewCount: 12840,
    starCount: 372,
    access: CollectionAccess.free,
  ),
  Collection(
    id: 'f2',
    slug: 'zurich-1953',
    kind: CollectionKind.book,
    title: 'Zurich International Chess Tournament 1953',
    author: 'David Bronstein',
    gameCount: 210,
    viewCount: 9020,
    starCount: 214,
    note: 'Candidates',
  ),
  Collection(
    id: 'f3',
    slug: 'life-and-games-of-tal',
    kind: CollectionKind.book,
    title: 'The Life and Games of Mikhail Tal',
    author: 'Mikhail Tal',
    gameCount: 100,
    viewCount: 7411,
    starCount: 96,
    access: CollectionAccess.free,
  ),
  Collection(
    id: 'f4',
    slug: 'candidates-1962',
    kind: CollectionKind.event,
    title: 'Candidates Tournament 1962',
    location: 'Curacao',
    gameCount: 216,
    access: CollectionAccess.free,
  ),
  Collection(
    id: 'f5',
    slug: 'the-immortal-game',
    kind: CollectionKind.book,
    title: 'The Immortal Game',
    author: 'Adolf Anderssen',
    gameCount: 1,
    viewCount: 640,
    starCount: 5,
    access: CollectionAccess.free,
  ),
  Collection(
    id: 'f6',
    slug: 'my-great-predecessors-1',
    kind: CollectionKind.book,
    title: 'Garry Kasparov on My Great Predecessors, Part I',
    author: 'Garry Kasparov',
    gameCount: 1348,
    viewCount: 148211,
    starCount: 12030,
  ),
  Collection(
    id: 'f7',
    slug: 'simple-chess',
    kind: CollectionKind.book,
    title: 'Simple Chess',
    author: 'Michael Stean',
    gameCount: 28,
    viewCount: 311,
    access: CollectionAccess.free,
  ),
  Collection(
    id: 'f8',
    slug: 'art-of-attack',
    kind: CollectionKind.book,
    title: 'Art of Attack in Chess',
    author: 'Vladimir Vukovic',
    gameCount: 45,
    viewCount: 2750,
    starCount: 41,
    access: CollectionAccess.free,
  ),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the catalog', () {
    testWidgets('lists published collections on the Library row frame', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      expect(find.byType(CollectionCatalogRow), findsNWidgets(3));
      expect(find.byType(LibraryCatalogRowFrame), findsNWidgets(3));
      expect(find.text('COLLECTION'), findsOneWidget);
      expect(find.text('60 games'), findsNothing);
      expect(find.text('3 games'), findsOneWidget);
      expect(
        find.text('Bobby Fischer'),
        findsNWidgets(2),
        reason: 'row + rail',
      );
      // Nothing is selected yet: the preview says what Collections is.
      expect(find.text('About collections'), findsOneWidget);
      expect(reader.gameReads, isEmpty);
    });

    testWidgets('the rail lists the catalog and its authors', (tester) async {
      await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
      );

      expect(find.text('All collections'), findsOneWidget);
      expect(find.text('CATALOG'), findsOneWidget);
      expect(find.text('AUTHORS'), findsOneWidget);
      expect(find.text('David Bronstein'), findsNWidgets(2));
    });

    testWidgets('selecting a collection previews its games in the table', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      await tester.tap(_row('My 60 Memorable Games'));
      await _settle(tester);

      expect(reader.gameReads, ['my-60-memorable-games']);
      expect(find.text('About collections'), findsNothing);
      // The Library's own table: abbreviated names, no "Saved" column.
      expect(find.text('Larsen, B.'), findsWidgets);
      expect(find.text('White'), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
    });

    testWidgets('a locked collection shows its contents, never its games', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        premium: false,
      );

      await tester.tap(_row('Zurich 1953'));
      await _settle(tester);

      expect(
        find.text('Read all 210 games in this collection'),
        findsOneWidget,
      );
      expect(find.text('Chapter 1: Openings'), findsOneWidget);
      expect(find.text('2 games'), findsWidgets);
      expect(
        reader.gameReads,
        isEmpty,
        reason: 'games are not asked for while the collection is locked',
      );
    });

    testWidgets('a subscriber the server still reports locked sees the lock', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      await tester.tap(_row('Zurich 1953'));
      await _settle(tester);

      expect(
        find.text('Read all 210 games in this collection'),
        findsOneWidget,
      );
      expect(reader.gameReads, isEmpty);
    });

    testWidgets('search narrows the catalog after a beat', (tester) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      await tester.enterText(find.byType(TextField).first, 'zurich');
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        reader.bookQueries.where((q) => q.text == 'zurich'),
        isEmpty,
        reason: 'not asked for on every keystroke',
      );
      await _settle(tester);

      expect(reader.bookQueries.last.text, 'zurich');
      expect(find.byType(CollectionCatalogRow), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'nothing like this');
      await _settle(tester);

      expect(find.text('No matches'), findsOneWidget);
      expect(find.text('Try another search or clear filters.'), findsOneWidget);
    });

    testWidgets('an author in the rail narrows the catalog and can be left', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      await tester.tap(find.text('Bobby Fischer').first);
      await _settle(tester);

      expect(
        reader.bookQueries.last.authorId,
        'account:0123456789abcdef0123456789abcdef',
      );
      expect(find.byType(CollectionCatalogRow), findsOneWidget);
      expect(find.text('Eleventh World Chess Champion.'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

      await tester.tap(find.text('All collections'));
      await _settle(tester);

      expect(find.byType(CollectionCatalogRow), findsNWidgets(3));
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    });

    testWidgets('an author without a catalog identity is matched by name', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(tester, const CollectionsPane(), reader: reader);

      await tester.tap(find.text('David Bronstein').first);
      await _settle(tester);

      expect(reader.bookQueries.last.authorId, isEmpty);
      expect(reader.bookQueries.last.author, 'David Bronstein');
      expect(find.text('No author description available yet.'), findsOneWidget);
    });

    testWidgets('a failed catalog offers a retry that works', (tester) async {
      final reader =
          FakeCollectionsReader()..booksError = StateError('offline');
      await _pump(tester, const CollectionsPane(), reader: reader);

      expect(find.text("Couldn't load collections."), findsOneWidget);

      reader.booksError = null;
      await tester.tap(find.text('Try again'));
      await _settle(tester);

      expect(find.byType(CollectionCatalogRow), findsNWidgets(3));
    });

    testWidgets('a bad search explains itself instead of failing', (
      tester,
    ) async {
      final reader =
          FakeCollectionsReader()
            ..booksError = const CollectionsRequestException(
              'Invalid eco',
              statusCode: 400,
            );
      await _pump(tester, const CollectionsPane(), reader: reader);

      expect(find.text('Check your search'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a server that predates collections says so, with no retry', (
      tester,
    ) async {
      final reader =
          FakeCollectionsReader()
            ..booksError = const CollectionsRequestException(
              'Collections are not available here yet',
              statusCode: 403,
              code: kCollectionsNotAvailable,
            );
      await _pump(tester, const CollectionsPane(), reader: reader);

      expect(find.text('Collections are not available yet'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a double click opens the collection in its own tab', (
      tester,
    ) async {
      final container = await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
      );

      await _doubleTap(tester, _row('My 60 Memorable Games'));

      final tabs = container.read(desktopTabsProvider).tabs;
      final opened = tabs.singleWhere(
        (tab) => tab.kind == TabKind.collectionWorkspace,
      );
      expect(opened.title, 'My 60 Memorable Games');
      expect(
        container.read(collectionWorkspaceArgsByTabIdProvider)[opened.id]?.slug,
        'my-60-memorable-games',
      );

      // Opening it again brings that tab forward instead of a second one.
      await _doubleTap(tester, _row('My 60 Memorable Games'));
      expect(
        container
            .read(desktopTabsProvider)
            .tabs
            .where((tab) => tab.kind == TabKind.collectionWorkspace),
        hasLength(1),
      );
    });
  });

  group('an opened collection', () {
    List<Override> opened(String slug, String title) => [
      collectionWorkspaceArgsByTabIdProvider.overrideWith(
        (ref) => {'t1': CollectionWorkspaceArgs(slug: slug, title: title)},
      ),
    ];

    testWidgets('opens on its games and counts one read', (tester) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      expect(find.text('Larsen, B.'), findsWidgets);
      expect(
        find.text('by Bobby Fischer · 3 games · Simon & Schuster · 1969'),
        findsOneWidget,
      );
      expect(find.text('Collection'), findsOneWidget);
      expect(reader.views, ['my-60-memorable-games']);
      // The count the server answered replaces the catalog's.
      expect(find.text('1285'), findsOneWidget);
    });

    testWidgets('an event collection is not counted as a read', (tester) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        overrides: opened('candidates-1962', 'Candidates Tournament 1962'),
      );

      expect(reader.views, isEmpty);
      expect(find.text('Event collection'), findsOneWidget);
      // Its rounds can be picked from.
      expect(find.text('All games'), findsOneWidget);
    });

    testWidgets('a round narrows the games and All games restores them', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: FakeCollectionsReader(),
        overrides: opened('candidates-1962', 'Candidates Tournament 1962'),
      );
      expect(find.text('2'), findsOneWidget, reason: 'two games are listed');

      await tester.tap(find.text('All games'));
      await _settle(tester);
      await tester.tap(find.text('Round 2').last);
      await _settle(tester);

      expect(
        find.widgetWithText(DesktopToolbarPillButton, 'Round 2'),
        findsOneWidget,
      );
      expect(find.text('2'), findsNothing, reason: 'one game is left');
      expect(find.text('Tal, M.'), findsOneWidget);

      await tester.tap(
        find.widgetWithText(DesktopToolbarPillButton, 'Round 2'),
      );
      await _settle(tester);
      await tester.tap(find.text('All games').last);
      await _settle(tester);

      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('About shows the credits, the prose and the bound events', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: FakeCollectionsReader(),
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      await tester.tap(find.text('About'));
      await _settle(tester);

      expect(find.text('by Bobby Fischer'), findsOneWidget);
      expect(find.text('Simon & Schuster · 1969'), findsOneWidget);
      expect(find.text('About this collection'), findsOneWidget);
      expect(
        find.text('Sixty games, annotated by the player.'),
        findsOneWidget,
      );
      expect(find.text('Wins and losses alike.'), findsOneWidget);
      expect(find.text('Foreword'), findsOneWidget);
      expect(find.text('Events'), findsOneWidget);
      expect(
        find.textContaining('Mar del Plata 1960', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('3 games · 3 players'), findsOneWidget);
    });

    testWidgets('a player\'s games are one double click away, and back', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: FakeCollectionsReader(),
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      await tester.tap(find.text('Players'));
      await _settle(tester);
      expect(find.text('Larsen, Bent'), findsOneWidget);
      expect(find.text('PLAYER'), findsOneWidget);

      await _doubleTap(tester, find.text('Larsen, Bent'));

      // Back on Games, narrowed to the two games Larsen played, with a pill
      // that names him and clears the scope.
      final scope = find.widgetWithText(
        DesktopToolbarPillButton,
        'Larsen, Bent',
      );
      expect(scope, findsOneWidget);
      expect(find.text('Larsen, B.'), findsNWidgets(2));
      expect(
        find.text('3'),
        findsNothing,
        reason: 'only two rows are numbered',
      );

      await tester.tap(scope);
      await _settle(tester);

      expect(scope, findsNothing);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('search inside a collection is answered by the server', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );
      final readsBefore = reader.gameReads.length;

      await tester.enterText(find.byType(TextField).first, 'no such player');
      await _settle(tester);

      expect(reader.gameReads.length, readsBefore + 1);
      expect(find.text('No games match this search.'), findsOneWidget);
    });

    testWidgets('a locked collection opens on About with the way in', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        premium: false,
        overrides: opened('zurich-1953', 'Zurich 1953'),
      );

      expect(find.text('Premium'), findsOneWidget);
      expect(
        find.text('Read all 210 games in this collection'),
        findsOneWidget,
      );
      expect(find.text('About this collection'), findsOneWidget);

      await tester.tap(find.text('Games'));
      await _settle(tester);
      expect(find.text('Chapter 1: Openings'), findsOneWidget);

      await tester.tap(find.text('Players'));
      await _settle(tester);
      expect(find.text('Chapter 1: Openings'), findsOneWidget);
      expect(reader.gameReads, isEmpty);
      expect(reader.playerReads, isEmpty);
    });

    testWidgets('games the server refuses show the lock, not an error', (
      tester,
    ) async {
      // The detail read came back open, the games read did not.
      final reader = FakeCollectionsReader(lockedSlugs: const {})
        ..gamesError = const CollectionsRequestException(
          'Premium required',
          statusCode: 402,
          code: 'premium_required',
        );
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      expect(find.text('Read all 3 games in this collection'), findsOneWidget);
      expect(find.text("Couldn't load the games."), findsNothing);
    });

    testWidgets('a failed games read can be asked for again', (tester) async {
      final reader =
          FakeCollectionsReader()..gamesError = StateError('offline');
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      expect(find.text("Couldn't load the games."), findsOneWidget);

      reader.gamesError = null;
      await tester.tap(find.text('Try again'));
      await _settle(tester);

      expect(find.text('Larsen, B.'), findsWidgets);
    });

    testWidgets('a tab whose collection is gone says so', (tester) async {
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 'missing'),
        reader: FakeCollectionsReader(),
      );

      expect(find.text('This collection is no longer open'), findsOneWidget);
    });

    testWidgets('a game opens on the board as the collection published it', (
      tester,
    ) async {
      final container = await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: FakeCollectionsReader(),
        overrides: opened('my-60-memorable-games', 'My 60 Memorable Games'),
      );

      await _doubleTap(tester, find.text('Larsen, B.').first);

      final boards = container.read(boardTabGameArgsByTabIdProvider);
      expect(boards, hasLength(1));
      final args = boards.values.single;
      expect(args.pgn, sampleCard(0).pgn!.trim());
      expect(args.databaseTitle, 'My 60 Memorable Games');
      // Previous and next walk the three games the table listed.
      expect(args.databaseGames.map((g) => g.id), ['g0', 'g1', 'g2']);
      expect(args.databaseGames.first.pgn, sampleCard(0).pgn!.trim());
      expect(args.accessContext?.isCollectionContent, isTrue);
      // Not the reader's record: Save has nothing to write back to.
      expect(args.librarySaveOrigin, isNull);
    });
  });

  group('under real use', () {
    testWidgets(
      'a starred row moves up and its star still reaches the server',
      (tester) async {
        final reader = FakeCollectionsReader();
        await _pump(
          tester,
          const CollectionsPane(),
          reader: reader,
          overrides: [
            collectionStarAccountProvider.overrideWithValue(() => true),
          ],
        );
        final last = _row('Candidates Tournament 1962');
        expect(
          tester.getTopLeft(last).dy,
          greaterThan(tester.getTopLeft(_row('Zurich 1953')).dy),
        );

        await tester.tap(_in(last, _glyph(SvgAsset.starIcon)));
        await _settle(tester);

        // Pinned to the top: the row that was pressed has been rebuilt.
        expect(
          tester.getTopLeft(_row('Candidates Tournament 1962')).dy,
          lessThan(tester.getTopLeft(_row('My 60 Memorable Games')).dy),
        );
        expect(reader.stars, [('candidates-1962', true)]);
      },
    );

    testWidgets('re-reading a locked collection keeps its way in on screen', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      final container = await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        premium: false,
      );
      await tester.tap(_row('Zurich 1953'));
      await _settle(tester);
      expect(find.byType(CollectionLockedContents), findsOneWidget);

      // What confirming a purchase does, read after read.
      container.invalidate(collectionDetailProvider('zurich-1953'));
      await tester.pump();

      expect(
        find.byType(CollectionLockedContents),
        findsOneWidget,
        reason: 'the unlock button started the re-read and must outlive it',
      );
      await _settle(tester);
    });

    testWidgets(
      'the confirm loop holds the collection with nothing on screen',
      (tester) async {
        final reader = FakeCollectionsReader();
        final container = await _pump(
          tester,
          const SizedBox.shrink(),
          reader: reader,
        );
        var looks = 0;
        final confirmed = confirmCollectionPremium(
          container,
          'zurich-1953',
          waits: const [Duration.zero, Duration.zero, Duration.zero],
        );
        // The purchase lands after the second look.
        final watch = container.listen(
          collectionDetailProvider('zurich-1953'),
          (_, next) {
            if (next.hasValue && !next.isLoading && ++looks == 2) {
              reader.lockedSlugs = {};
            }
          },
        );
        addTearDown(watch.close);

        expect(await tester.runAsync(() => confirmed), isTrue);
        expect(reader.detailReads.length, 3);
        expect(container.read(collectionConfirmingProvider), isEmpty);
      },
    );

    testWidgets('a credit opens the author as the catalog knows them', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      final container = await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
      );

      // All an opened collection's credit carries: an id and a name.
      container
          .read(collectionsAuthorRequestProvider.notifier)
          .state = const CollectionAuthor(
        id: 'account:0123456789abcdef0123456789abcdef',
        name: 'Bobby Fischer',
      );
      await _settle(tester);

      expect(find.byType(CollectionCatalogRow), findsOneWidget);
      expect(find.text('1 collection · 60 games'), findsOneWidget);
      expect(find.text('Eleventh World Chess Champion.'), findsOneWidget);
      expect(find.text('0 collections'), findsNothing);
    });

    test('an author is matched by id, then by name, else kept as given', () {
      const known = [
        CollectionAuthor(id: 'account:a', name: 'Bobby Fischer', bookCount: 2),
        CollectionAuthor(id: 'David Bronstein', name: 'David Bronstein'),
      ];
      expect(
        resolveCollectionAuthor(
          const CollectionAuthor(id: 'account:a', name: 'R. Fischer'),
          known,
        )?.bookCount,
        2,
      );
      expect(
        resolveCollectionAuthor(
          const CollectionAuthor(id: 'x', name: ' bobby fischer '),
          known,
        )?.id,
        'account:a',
      );
      const stranger = CollectionAuthor(id: 'x', name: 'Nobody');
      expect(resolveCollectionAuthor(stranger, known), same(stranger));
      expect(resolveCollectionAuthor(null, known), isNull);
    });

    test('a part stands for the chapters under it', () {
      final games = [
        collectionGameFromCard(sampleCard(0, sectionId: 'c1'), 0)!,
        collectionGameFromCard(sampleCard(1, sectionId: 'c2'), 1)!,
        collectionGameFromCard(sampleCard(2, sectionId: 'c3'), 2)!,
      ];
      const part = CollectionSection(
        id: 'p1',
        kind: CollectionSectionKind.part,
        label: 'Part I',
        children: [
          CollectionSection(
            id: 'c1',
            kind: CollectionSectionKind.chapter,
            label: 'Chapter 1',
            gameCount: 1,
            children: [
              CollectionSection(
                id: 'c2',
                kind: CollectionSectionKind.chapter,
                label: 'Chapter 1.1',
                gameCount: 1,
              ),
            ],
          ),
        ],
      );

      expect(
        scopeCollectionGames(games, section: part).map((game) => game.id),
        ['g0', 'g1'],
      );
      expect(
        scopeCollectionGames(
          games,
          section: part.children.single.children.single,
        ).map((game) => game.id),
        ['g1'],
      );
      expect(scopeCollectionGames(games), same(games));
    });

    test(
      'the games table gives up columns as it narrows, never the players',
      () {
        // Collections beside the rail on a 1440 window.
        expect(libraryReadOnlyGamesFit(508).columns, [
          'number',
          'white',
          'result',
          'black',
          'eco',
        ]);
        // An opened collection on the same window has room for the date.
        expect(libraryReadOnlyGamesFit(643).columns, [
          'number',
          'white',
          'result',
          'black',
          'eco',
          'date',
        ]);
        expect(libraryReadOnlyGamesFit(900).columns.length, 9);
        // The split's own minimum.
        final narrowest = libraryReadOnlyGamesFit(361);
        expect(narrowest.columns, ['number', 'white', 'result', 'black']);
        expect(narrowest.playerWidth, greaterThanOrEqualTo(104));
        // The players take up what the columns left.
        expect(libraryReadOnlyGamesFit(508).playerWidth, closeTo(142.5, 0.01));
      },
    );

    testWidgets('the games fit a 1440 window without running off the table', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        window: const Size(1440, 900),
      );

      await tester.tap(_row('My 60 Memorable Games'));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('White'), findsOneWidget);
      expect(find.text('Black'), findsOneWidget);
      expect(find.text('Event'), findsNothing);
    });
  });

  group('the catalog table', () {
    const table = Size(1400, 800);

    testWidgets('a starred collection wears the gold star, and nothing red', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
        window: table,
        starred: [starredCollection('my-60-memorable-games')],
      );
      final starred = _row('My 60 Memorable Games');

      expect(_in(starred, _glyph(SvgAsset.starFilledIcon)), findsOneWidget);
      expect(_in(starred, _glyph(SvgAsset.starIcon)), findsNothing);
      expect(_glyph(SvgAsset.starIcon), findsNWidgets(2));
      // No button chrome behind any of them.
      final rows = find.byType(CollectionCatalogRow);
      expect(_in(rows, find.byType(DesktopHeaderIconButton)), findsNothing);
      expect(_in(rows, find.byType(FButton)), findsNothing);

      // And as painted: gold, and not one reddish pixel in the row.
      final painted = await _painted(tester, starred);
      final row = tester.getRect(starred);
      expect(painted.where(row, _isRed).count, 0);
      expect(painted.where(row, _isGold).count, greaterThan(100));
    });

    testWidgets('each star is drawn in the middle of its slot', (tester) async {
      await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
        window: table,
        starred: [starredCollection('my-60-memorable-games')],
      );

      for (final (title, drawn) in [
        ('My 60 Memorable Games', _isGold),
        ('Zurich 1953', _isLit),
      ]) {
        final slot = tester.getRect(_starSlot(_row(title)));
        expect(slot.width, greaterThanOrEqualTo(28));
        expect(slot.height, greaterThanOrEqualTo(28));
        final painted = await _painted(tester, _row(title));
        final star = painted.where(slot, drawn).bounds!;
        expect(star.center.dx, closeTo(slot.center.dx, 0.5), reason: title);
        expect(star.center.dy, closeTo(slot.center.dy, 0.5), reason: title);
        // A glyph, not a tile: it leaves most of its slot empty.
        expect(star.width, lessThan(17));
        expect(star.height, lessThan(17));
      }
    });

    testWidgets('an outline star brightens under the pointer, and only that', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
        window: table,
      );
      final row = _row('Zurich 1953');
      final slot = _starSlot(row);
      int brightest(_Painted painted) {
        var most = 0;
        painted.where(tester.getRect(slot), (r, g, b, a) {
          if (r > most) most = r;
          return false;
        });
        return most;
      }

      // 70% white at rest, the shell's resting foreground.
      expect(brightest(await _painted(tester, row)), closeTo(179, 3));

      final mouse = await _hover(tester, slot);
      final hovered = await _painted(tester, row);
      expect(brightest(hovered), greaterThan(250));
      // Nothing behind the glyph: a corner of its slot is the hovered row's
      // own surface, pixel for pixel.
      Set<int> colours(Rect area) {
        final seen = <int>{};
        hovered.where(area, (r, g, b, a) {
          seen.add(Color.fromARGB(a, r, g, b).toARGB32());
          return false;
        });
        return seen;
      }

      final surface = colours(
        tester.getRect(row).topLeft + const Offset(4, 4) & const Size(4, 4),
      );
      expect(surface, hasLength(1));
      expect(colours(tester.getRect(slot).topLeft & const Size(4, 4)), surface);

      // Its tooltip says what a press does, and leaves with the pointer.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Star collection'), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await _settle(tester);
      expect(find.text('Star collection'), findsNothing);
    });

    testWidgets('header labels stand on the edges of the cells under them', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
        window: table,
      );
      final row = _row('My 60 Memorable Games');

      // A label is as wide as its text, so its box is where the text is set
      // from. (Its letters stand half a letter spacing, an eighth of a
      // pixel, inside that.)
      Map<String, double> edges() => {
        'COLLECTION': tester.getRect(find.text('COLLECTION')).left,
        'AUTHOR': tester.getRect(find.text('AUTHOR')).left,
        'GAMES': tester.getRect(find.text('GAMES')).right,
        'VIEWS': tester.getRect(find.text('VIEWS')).right,
        'STARS': tester.getRect(find.text('STARS')).right,
      };
      final cells = {
        'COLLECTION':
            _ink(
              tester,
              find.textContaining('My 60 Memorable Games', findRichText: true),
              of: 'My 60 Memorable Games',
            ).left,
        'AUTHOR': _ink(tester, _in(row, find.text('Bobby Fischer'))).left,
        'GAMES': _ink(tester, find.text('3 games')).right,
        'VIEWS': _ink(tester, find.text('1284')).right,
        'STARS': _ink(tester, find.text('37')).right,
      };
      final unsorted = edges();
      for (final column in cells.keys) {
        expect(
          unsorted[column],
          closeTo(cells[column]!, 0.01),
          reason: '$column and its cells',
        );
      }

      // Sorted either way, with the mark beside it, a label does not move.
      for (final column in cells.keys) {
        for (var press = 0; press < 2; press++) {
          await tester.tap(find.text(column));
          await _settle(tester);
          expect(_glyph(SvgAsset.arrowDown), findsOneWidget);
          expect(
            edges()[column],
            closeTo(unsorted[column]!, 0.01),
            reason: '$column, sorted (press ${press + 1})',
          );
        }
        // Back to the team's order.
        await tester.tap(find.text(column));
        await _settle(tester);
      }
      expect(_glyph(SvgAsset.arrowDown), findsNothing);
      expect(edges(), unsorted);
    });

    testWidgets('one gutter separates every column', (tester) async {
      await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
        window: table,
      );
      final row = _row('My 60 Memorable Games');
      final cells = [
        tester.getRect(_in(row, find.byType(CollectionCoverThumb))),
        tester.getRect(_in(row, find.byType(CollectionTitleLine))),
        tester.getRect(_in(row, find.text('Bobby Fischer'))),
        tester.getRect(find.text('3 games')),
        tester.getRect(find.text('1284')),
        tester.getRect(find.text('37')),
      ];

      for (var i = 1; i < cells.length; i++) {
        expect(
          cells[i].left - cells[i - 1].right,
          closeTo(CollectionCatalogColumns.gutter, 0.01),
          reason: 'between columns ${i - 1} and $i',
        );
      }
      // Nothing touches the row's edges.
      final frame = tester.getRect(row);
      expect(cells.first.left - frame.left, greaterThanOrEqualTo(10));
      final star = tester.getRect(_starSlot(row));
      expect(frame.right - star.right, greaterThanOrEqualTo(10));
    });

    testWidgets('the stars stand in one line, with a count or without', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
        window: table,
      );
      final rows = [
        _row('My 60 Memorable Games'),
        _row('Zurich 1953'),
        _row('Candidates Tournament 1962'),
      ];
      // The event has no stars: its count slot is empty, not gone.
      expect(_in(rows[2], find.text('0')), findsNothing);

      final stars = [
        for (final row in rows)
          tester.getRect(_in(row, _glyph(SvgAsset.starIcon))),
      ];
      expect(stars.map((star) => star.left).toSet(), hasLength(1));
      expect(stars.map((star) => star.width).toSet(), {16});
      for (final (index, row) in rows.indexed) {
        final slot = tester.getRect(_starSlot(row));
        expect(stars[index].center, slot.center);
      }
      // The counts end on one edge, a fixed step from their stars.
      final counts = [
        _ink(tester, find.text('37')).right,
        _ink(tester, find.text('21')).right,
      ];
      expect(counts.toSet(), hasLength(1));
      expect(stars.first.left - counts.first, closeTo(8, 0.01));
    });

    testWidgets(
      'a narrow pane gives up VIEWS, then AUTHOR, and stays aligned',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          // The rail folded away, so the catalog has the window to itself.
          'split_view::collections_pane.main':
              '{"weights":[0.2,0.8],"collapsed":[0]}',
        });
        final widths = <String, List<String>>{};
        for (final width in [800.0, 700.0, 620.0]) {
          await _pump(
            tester,
            const CollectionsPane(),
            reader: FakeCollectionsReader(),
            window: Size(width, 800),
          );
          expect(tester.takeException(), isNull, reason: 'at $width');
          widths['$width'] = [
            for (final label in [
              'COLLECTION',
              'AUTHOR',
              'GAMES',
              'VIEWS',
              'STARS',
            ])
              if (find.text(label).evaluate().isNotEmpty) label,
          ];
          expect(
            tester.getRect(find.text('GAMES')).right,
            closeTo(_ink(tester, find.text('3 games')).right, 0.01),
          );
          expect(
            tester.getRect(find.text('STARS')).right,
            closeTo(_ink(tester, find.text('37')).right, 0.01),
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }

        expect(widths['800.0'], [
          'COLLECTION',
          'AUTHOR',
          'GAMES',
          'VIEWS',
          'STARS',
        ]);
        expect(widths['700.0'], ['COLLECTION', 'AUTHOR', 'GAMES', 'STARS']);
        expect(widths['620.0'], ['COLLECTION', 'GAMES', 'STARS']);
      },
    );
  });

  group('sorting the catalog', () {
    const table = Size(1400, 800);

    int turns(WidgetTester tester) =>
        tester
            .widget<RotatedBox>(
              find
                  .ancestor(
                    of: _glyph(SvgAsset.arrowDown),
                    matching: find.byType(RotatedBox),
                  )
                  .first,
            )
            .quarterTurns;

    testWidgets('a header asks the server: natural, reversed, the team\'s', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        window: table,
      );
      const team = [
        'My 60 Memorable Games',
        'Zurich 1953',
        'Candidates Tournament 1962',
      ];
      expect(_titles(tester), team);
      expect(_glyph(SvgAsset.arrowDown), findsNothing);
      var asked = reader.bookQueries.length;

      // Counts start from the largest.
      await tester.tap(find.text('GAMES'));
      await _settle(tester);
      expect(reader.bookQueries.length, asked + 1, reason: 'read again');
      expect(reader.bookQueries.last.parameters, {'sort': 'games'});
      expect(_titles(tester), [
        'Zurich 1953',
        'My 60 Memorable Games',
        'Candidates Tournament 1962',
      ]);
      expect(turns(tester), 0, reason: 'pointing down');
      // Before a label set from the right, so the label keeps its edge.
      expect(
        tester.getRect(_glyph(SvgAsset.arrowDown)).right,
        lessThan(_ink(tester, find.text('GAMES')).left),
      );

      await tester.tap(find.text('GAMES'));
      await _settle(tester);
      expect(reader.bookQueries.length, asked + 2);
      expect(reader.bookQueries.last.parameters, {
        'sort': 'games',
        'order': 'asc',
      });
      expect(_titles(tester), [
        'Candidates Tournament 1962',
        'My 60 Memorable Games',
        'Zurich 1953',
      ]);
      expect(turns(tester), 2, reason: 'turned over');

      await tester.tap(find.text('GAMES'));
      await _settle(tester);
      expect(_titles(tester), team);
      expect(_glyph(SvgAsset.arrowDown), findsNothing);
      expect(reader.bookQueries.last.sort, 'games', reason: 'still listed');
      asked = reader.bookQueries.length;

      // Names start from A.
      await tester.tap(find.text('COLLECTION'));
      await _settle(tester);
      expect(reader.bookQueries.length, asked + 1);
      expect(reader.bookQueries.last.parameters, {'sort': 'name'});
      expect(_titles(tester), [
        'Candidates Tournament 1962',
        'My 60 Memorable Games',
        'Zurich 1953',
      ]);
      expect(turns(tester), 2, reason: 'ascending');
      // After a label set from the left.
      expect(
        tester.getRect(_glyph(SvgAsset.arrowDown)).left,
        greaterThan(_ink(tester, find.text('COLLECTION')).right),
      );

      await tester.tap(find.text('COLLECTION'));
      await _settle(tester);
      expect(reader.bookQueries.last.parameters, {
        'sort': 'name',
        'order': 'desc',
      });
      expect(turns(tester), 0);

      // Another column starts over in its own natural direction.
      await tester.tap(find.text('STARS'));
      await _settle(tester);
      expect(reader.bookQueries.last.parameters, {'sort': 'stars'});
      expect(_glyph(SvgAsset.arrowDown), findsOneWidget);
    });

    testWidgets('the direction mark is drawn in the middle of its slot', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
        window: table,
      );

      for (final direction in ['descending', 'ascending']) {
        await tester.tap(find.text('VIEWS'));
        await _settle(tester);
        final slot = tester.getRect(
          find
              .ancestor(
                of: _glyph(SvgAsset.arrowDown),
                matching: find.byType(RotatedBox),
              )
              .first,
        );
        final painted = await _painted(tester, find.text('VIEWS'));
        final mark = painted.where(slot, _isLit).bounds!;
        expect(mark.center.dx, closeTo(slot.center.dx, 0.5), reason: direction);
        expect(mark.center.dy, closeTo(slot.center.dy, 0.5), reason: direction);
      }
    });

    testWidgets('the headers are buttons a keyboard reaches', (tester) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        window: table,
      );
      final handle = tester.ensureSemantics();

      expect(
        tester.getSemantics(find.bySemanticsLabel('Sort by stars')),
        matchesSemantics(
          label: 'Sort by stars',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      Focus.of(tester.element(find.text('STARS'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);

      expect(reader.bookQueries.last.parameters, {'sort': 'stars'});
      expect(
        tester.getSemantics(find.bySemanticsLabel('Sort by stars')),
        matchesSemantics(
          label: 'Sort by stars',
          value: 'Descending',
          isButton: true,
          isFocusable: true,
          isFocused: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('starred collections lead the team\'s order only', (
      tester,
    ) async {
      await _pump(
        tester,
        const CollectionsPane(),
        reader: FakeCollectionsReader(),
        window: table,
        starred: [starredCollection('candidates-1962')],
      );
      expect(_titles(tester).first, 'Candidates Tournament 1962');

      await tester.tap(find.text('STARS'));
      await _settle(tester);

      // The server's order, row for row: the starred one has no stars.
      expect(_titles(tester), [
        'My 60 Memorable Games',
        'Zurich 1953',
        'Candidates Tournament 1962',
      ]);
    });

    testWidgets('an order the server does not know goes back, with one toast', (
      tester,
    ) async {
      final reader =
          FakeCollectionsReader()
            ..orderError =
                (query) =>
                    query.sort == 'stars'
                        ? FakeCollectionsReader.unknownOrder
                        : null;
      await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        window: table,
        toaster: true,
      );
      await tester.tap(find.text('GAMES'));
      await _settle(tester);
      const byGames = [
        'Zurich 1953',
        'My 60 Memorable Games',
        'Candidates Tournament 1962',
      ];
      expect(_titles(tester), byGames);

      await tester.tap(find.text('STARS'));
      await tester.pump();
      // The rows it had stay while the new order is read.
      expect(_titles(tester), byGames);
      await _settle(tester);

      expect(reader.bookQueries.last.parameters, {'sort': 'stars'});
      expect(
        find.text('Sorting by stars is not available yet.'),
        findsOneWidget,
      );
      // Back on GAMES, which was never read again.
      expect(_titles(tester), byGames);
      expect(
        tester.getRect(_glyph(SvgAsset.arrowDown)).right,
        lessThan(_ink(tester, find.text('GAMES')).left),
      );
      expect(reader.bookQueries.where((q) => q.sort == 'games'), hasLength(1));
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);
      expect(find.text('Sorting by stars is not available yet.'), findsNothing);

      // The next press steps over what was refused instead of asking again.
      await tester.tap(find.text('STARS'));
      await _settle(tester);
      expect(reader.bookQueries.last.parameters, {
        'sort': 'stars',
        'order': 'asc',
      });
      expect(
        find.text('Sorting by stars in reverse is not available yet.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);

      // With nothing left to ask for, a press still answers.
      final asked = reader.bookQueries.length;
      await tester.tap(find.text('STARS'));
      await _settle(tester);
      expect(reader.bookQueries.length, asked);
      expect(
        find.text('Sorting by stars is not available yet.'),
        findsOneWidget,
      );
      expect(_titles(tester), byGames);
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);
    });

    testWidgets('a reverse the server refuses still lets the header go back', (
      tester,
    ) async {
      // Today's server: it knows name, and no direction.
      final reader =
          FakeCollectionsReader()
            ..orderError =
                (query) =>
                    query.parameters.containsKey('order')
                        ? FakeCollectionsReader.unknownOrder
                        : null;
      await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        window: table,
        toaster: true,
      );
      const byName = [
        'Candidates Tournament 1962',
        'My 60 Memorable Games',
        'Zurich 1953',
      ];

      await tester.tap(find.text('COLLECTION'));
      await _settle(tester);
      expect(_titles(tester), byName);

      await tester.tap(find.text('COLLECTION'));
      await _settle(tester);
      expect(reader.bookQueries.last.parameters, {
        'sort': 'name',
        'order': 'desc',
      });
      expect(_titles(tester), byName, reason: 'refused: still A to Z');
      expect(_glyph(SvgAsset.arrowDown), findsOneWidget);
      expect(
        find.text('Sorting by name in reverse is not available yet.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);

      await tester.tap(find.text('COLLECTION'));
      await _settle(tester);
      expect(_glyph(SvgAsset.arrowDown), findsNothing);
      expect(_titles(tester).first, 'My 60 Memorable Games');
    });

    testWidgets('a read that fails for another reason can be asked again', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        window: table,
        toaster: true,
      );
      reader.orderError = (query) => StateError('offline');

      await tester.tap(find.text('VIEWS'));
      await _settle(tester);

      expect(find.text('Could not sort by views. Try again.'), findsOneWidget);
      expect(_glyph(SvgAsset.arrowDown), findsNothing);
      expect(find.byType(CollectionCatalogRow), findsNWidgets(3));
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);

      reader.orderError = null;
      await tester.tap(find.text('VIEWS'));
      await _settle(tester);
      expect(reader.bookQueries.last.parameters, {'sort': 'views'});
      expect(_titles(tester).first, 'My 60 Memorable Games');
      expect(_glyph(SvgAsset.arrowDown), findsOneWidget);
    });

    testWidgets('clearing the filters clears the order with them', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionsPane(),
        reader: reader,
        window: table,
      );

      await tester.tap(find.text('Filters'));
      await _settle(tester);
      await tester.enterText(find.byType(EditableText).last, 'B90');
      await tester.tap(find.text('Apply'));
      await _settle(tester);
      await tester.tap(find.text('GAMES'));
      await _settle(tester);
      expect(reader.bookQueries.last.parameters, {
        'eco': 'B90',
        'sort': 'games',
      });
      expect(reader.bookQueries.last.filterCount, 2);

      // An order alone is not a filter to clear: applying nothing keeps it.
      await tester.tap(find.text('Filters'));
      await _settle(tester);
      await tester.tap(find.text('Apply'));
      await _settle(tester);
      expect(_glyph(SvgAsset.arrowDown), findsOneWidget);

      await tester.tap(find.text('Filters'));
      await _settle(tester);
      await tester.tap(find.text('Clear all'));
      await tester.pump();
      await tester.tap(find.text('Apply'));
      await _settle(tester);

      expect(_glyph(SvgAsset.arrowDown), findsNothing);
      expect(_titles(tester), [
        'My 60 Memorable Games',
        'Zurich 1953',
        'Candidates Tournament 1962',
      ]);
      // forui's text field in a dialog trips a semantics assert under test.
    }, semanticsEnabled: false);
  });

  group('the opened collection\'s star', () {
    testWidgets('is the same bare glyph beside its count', (tester) async {
      final reader = FakeCollectionsReader();
      await _pump(
        tester,
        const CollectionWorkspacePane(tabId: 't1'),
        reader: reader,
        window: const Size(1400, 800),
        starred: [starredCollection('my-60-memorable-games')],
        overrides: [
          collectionWorkspaceArgsByTabIdProvider.overrideWith(
            (ref) => {
              't1': const CollectionWorkspaceArgs(
                slug: 'my-60-memorable-games',
                title: 'My 60 Memorable Games',
              ),
            },
          ),
          collectionStarAccountProvider.overrideWithValue(() => true),
        ],
      );
      final button = find.byType(CollectionStarButton);

      expect(_in(button, _glyph(SvgAsset.starFilledIcon)), findsOneWidget);
      expect(_in(button, find.byType(FButton)), findsNothing);
      final count = _ink(tester, _in(button, find.text('37')));
      final star = tester.getRect(_glyph(SvgAsset.starFilledIcon));
      expect(star.left - count.right, closeTo(8, 0.01));
      // On the middle of the count's line.
      expect(
        star.center.dy,
        closeTo(tester.getCenter(_in(button, find.text('37'))).dy, 0.01),
      );

      // One press unstars it, at once: nothing here waits for a double click.
      await tester.tap(_glyph(SvgAsset.starFilledIcon));
      await _settle(tester);
      expect(reader.stars, [('my-60-memorable-games', false)]);
      expect(_in(button, _glyph(SvgAsset.starIcon)), findsOneWidget);
    });
  });

  group('fixture', () {
    // Not a test of anything: it draws the catalog with real typefaces and
    // writes it out, so the table can be looked at without running the app.
    //   COLLECTIONS_TABLE_SHOTS=/tmp/collections_table flutter test \
    //     test/desktop/collections_pane_test.dart --plain-name fixture
    testWidgets(
      'draws the catalog to files',
      (tester) async {
        await tester.runAsync(_loadFixtureFonts);
        final starred = [
          starredCollection('life-and-games-of-tal'),
          starredCollection('simple-chess'),
        ];
        Future<GlobalKey> open(
          Size window, {
          Widget pane = const CollectionsPane(),
          FakeCollectionsReader? reader,
          bool railFolded = false,
          List<Override> overrides = const [],
        }) async {
          SharedPreferences.setMockInitialValues({
            // Room for the catalog: the fixture is about its rows.
            'split_view::collections_pane.home_split':
                '{"weights":[0.66,0.34],"collapsed":[]}',
            if (railFolded)
              'split_view::collections_pane.main':
                  '{"weights":[0.2,0.8],"collapsed":[0]}',
          });
          final capture = GlobalKey();
          await _pump(
            tester,
            pane,
            reader: reader ?? FakeCollectionsReader(books: _fixtureBooks),
            window: window,
            pixelRatio: 2,
            theme: _macTheme,
            starred: starred,
            toaster: true,
            capture: capture,
            premium: false,
            overrides: overrides,
          );
          return capture;
        }

        // The pane as it opens, with a row selected.
        var capture = await open(const Size(1100, 620));
        await tester.tap(_row('The Immortal Game'));
        await _settle(tester);
        await _shoot(tester, capture, '01_pane_1100_team_order');

        await tester.tap(find.text('STARS'));
        await _settle(tester);
        await _shoot(tester, capture, '02_pane_1100_stars_descending');

        await tester.tap(find.text('COLLECTION'));
        await _settle(tester);
        final mouse = await _hover(
          tester,
          _starSlot(_row('Candidates Tournament 1962')),
        );
        await _shoot(tester, capture, '03_pane_1100_name_ascending_star_hover');
        await tester.pump(const Duration(milliseconds: 400));
        await _settle(tester);
        await _shoot(tester, capture, '04_pane_1100_star_tooltip');
        await mouse.moveTo(tester.getCenter(find.text('GAMES')));
        await _settle(tester);
        await _shoot(tester, capture, '05_pane_1100_header_hover');
        await mouse.moveTo(Offset.zero);
        await _settle(tester);

        Focus.of(tester.element(find.text('VIEWS'))).requestFocus();
        await _settle(tester);
        await _shoot(tester, capture, '06_pane_1100_header_keyboard_focus');
        await tester.pumpWidget(const SizedBox.shrink());

        // A sort the server refuses: the order stays, a toast says why.
        capture = await open(
          const Size(1100, 620),
          reader: FakeCollectionsReader(books: _fixtureBooks)
            ..orderError =
                (query) =>
                    query.sort == 'views'
                        ? FakeCollectionsReader.unknownOrder
                        : null,
        );
        await tester.tap(find.text('GAMES'));
        await _settle(tester);
        await tester.tap(find.text('VIEWS'));
        await _settle(tester);
        await _shoot(tester, capture, '07_pane_1100_refused_sort_toast');
        await tester.pump(const Duration(seconds: 4));
        await _settle(tester);
        await tester.pumpWidget(const SizedBox.shrink());

        // Narrow panes: VIEWS goes first, then AUTHOR.
        for (final width in [700.0, 620.0]) {
          capture = await open(Size(width, 620), railFolded: true);
          await tester.tap(find.text('GAMES'));
          await _settle(tester);
          debugPrint(
            'catalog at $width: '
            '${tester.getSize(find.byType(CollectionCatalogHeader)).width}',
          );
          await _shoot(tester, capture, '08_pane_${width.round()}_narrow');
          await tester.pumpWidget(const SizedBox.shrink());
        }

        // An opened collection: the same star in its header.
        for (final (name, slug) in [
          ('09_opened_starred', 'life-and-games-of-tal'),
          ('10_opened_unstarred', 'my-60-memorable-games'),
        ]) {
          capture = await open(
            const Size(1100, 620),
            pane: const CollectionWorkspacePane(tabId: 't1'),
            overrides: [
              collectionWorkspaceArgsByTabIdProvider.overrideWith(
                (ref) => {'t1': CollectionWorkspaceArgs(slug: slug, title: '')},
              ),
            ],
          );
          await _shoot(tester, capture, name);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
      skip: _shots == null,
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });

  group('the catalog query', () {
    test('untouched filters send nothing', () {
      final query = collectionQueryFor(text: '  ', filter: GameFilter());

      expect(query.isActive, isFalse);
      expect(query.parameters, isEmpty);
    });

    test('each header state sends its own sort and order', () {
      Map<String, dynamic> sent(CollectionCatalogSort sort) =>
          collectionQueryFor(
            text: '',
            filter: GameFilter(),
            sort: sort,
          ).parameters;

      expect(sent(const CollectionCatalogSort.standard()), isEmpty);
      // The natural direction is the server's default for the column.
      for (final column in CollectionSortColumn.values) {
        expect(sent(CollectionCatalogSort.natural(column)), {
          'sort': column.api,
        });
      }
      expect(
        sent(
          const CollectionCatalogSort.by(
            CollectionSortColumn.name,
            ascending: false,
          ),
        ),
        {'sort': 'name', 'order': 'desc'},
      );
      expect(
        sent(
          const CollectionCatalogSort.by(
            CollectionSortColumn.author,
            ascending: false,
          ),
        ),
        {'sort': 'author', 'order': 'desc'},
      );
      for (final column in [
        CollectionSortColumn.games,
        CollectionSortColumn.views,
        CollectionSortColumn.stars,
      ]) {
        expect(sent(CollectionCatalogSort.by(column, ascending: true)), {
          'sort': column.api,
          'order': 'asc',
        });
      }
    });

    test(
      'an order counts as one filter, and its natural form is one query',
      () {
        const byName = CollectionSearchQuery(sort: 'name');

        expect(byName.filterCount, 1);
        expect(
          const CollectionSearchQuery(sort: 'name', order: 'desc').filterCount,
          1,
        );
        expect(byName.isActive, isTrue);
        expect(byName, const CollectionSearchQuery(sort: 'name', order: 'asc'));
        expect(
          byName.hashCode,
          const CollectionSearchQuery(sort: 'name', order: 'asc').hashCode,
        );
        expect(
          byName,
          isNot(const CollectionSearchQuery(sort: 'name', order: 'desc')),
        );
        expect(byName.withText('tal').parameters, {'q': 'tal', 'sort': 'name'});
        // The dated sorts have their direction in their name.
        expect(
          const CollectionSearchQuery(sort: 'newest', order: 'asc').parameters,
          {'sort': 'newest'},
        );
      },
    );

    test('a header cycles natural, reversed, then back to the team\'s', () {
      const team = CollectionCatalogSort.standard();
      for (final column in CollectionSortColumn.values) {
        final first = team.after(column);
        expect(first, CollectionCatalogSort.natural(column));
        expect(
          first.ascending,
          column == CollectionSortColumn.name ||
              column == CollectionSortColumn.author,
          reason: '${column.api}: names from A, counts from the largest',
        );
        final second = first.after(column);
        expect(second.column, column);
        expect(second.ascending, !first.ascending);
        expect(second.after(column), team);
      }
      // Another column starts in its own direction, whatever this one was.
      expect(
        const CollectionCatalogSort.by(
          CollectionSortColumn.name,
          ascending: false,
        ).after(CollectionSortColumn.stars),
        CollectionCatalogSort.natural(CollectionSortColumn.stars),
      );
    });

    test('a refused order is stepped over, never asked for twice', () {
      const team = CollectionCatalogSort.standard();
      final stars = CollectionCatalogSort.natural(CollectionSortColumn.stars);
      const starsUp = CollectionCatalogSort.by(
        CollectionSortColumn.stars,
        ascending: true,
      );
      final byGames = CollectionCatalogSort.natural(CollectionSortColumn.games);

      expect(team.after(CollectionSortColumn.stars, refused: {stars}), starsUp);
      expect(stars.after(CollectionSortColumn.stars, refused: {starsUp}), team);
      // Nothing left to offer: the order in force stays, even another
      // column's.
      expect(
        byGames.after(CollectionSortColumn.stars, refused: {stars, starsUp}),
        byGames,
      );
      expect(
        collectionSortFailedMessage(stars, refused: true),
        'Sorting by stars is not available yet.',
      );
      expect(
        collectionSortFailedMessage(starsUp, refused: true),
        'Sorting by stars in reverse is not available yet.',
      );
      expect(
        collectionSortFailedMessage(stars, refused: false),
        'Could not sort by stars. Try again.',
      );
    });

    test('filters map onto the API\'s own names', () {
      final query = collectionQueryFor(
        text: ' carlsen ',
        filter: GameFilter(
          result: GameResultFilter.draw,
          eco: GameEcoFilter.forCode('b90'),
          minYear: 1990,
          maxYear: 2000,
        ),
        now: DateTime(2026),
      );

      expect(query.parameters, {
        'q': 'carlsen',
        'eco': 'B90',
        'result': '1/2-1/2',
        'minYear': 1990,
        'maxYear': 2000,
      });
    });
  });
}
