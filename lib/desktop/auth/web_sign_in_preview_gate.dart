import 'dart:math' as math;

import 'package:chessever/desktop/auth/desktop_welcome_screen.dart';
import 'package:chessever/desktop/auth/web_sign_in_preview_data.dart';
import 'package:chessever/desktop/shell/desktop_chrome_metrics.dart';
import 'package:chessever/desktop/shell/desktop_sidebar.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_like_count_heart.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The sign-in requirement remains the boundary. Its backdrop is a separately
/// scoped, inert presentation of PUBLIC preview data, not a mounted signed-in
/// DesktopShell. No user tabs, private libraries, chat, membership, live feeds,
/// engine jobs, navigation callbacks or account mutation services are started.
class WebSignInPreviewGate extends StatefulWidget {
  const WebSignInPreviewGate({super.key, this.location, this.loadPreview});
  final Uri? location;
  final Future<WebSignInPreviewData> Function()? loadPreview;

  @override
  State<WebSignInPreviewGate> createState() => _WebSignInPreviewGateState();
}

class _WebSignInPreviewGateState extends State<WebSignInPreviewGate> {
  late final Future<WebSignInPreviewData> _data =
      (widget.loadPreview ?? WebSignInPreviewData.load)();
  final GlobalKey _previewKey = GlobalKey();
  final FocusScopeNode _authFocus = FocusScopeNode(
    debugLabel: 'Required web sign-in',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );

  @override
  void dispose() {
    _authFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final location = WebSignInPreviewLocation.fromUri(
      widget.location ?? Uri.base,
    );
    return PopScope(
      canPop: false,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            child: ExcludeFocus(
              child: AbsorbPointer(
                child: TickerMode(
                  enabled: false,
                  child: ProviderScope(
                    overrides: [
                      boardSettingsProviderNew.overrideWith(
                        _PreviewBoardSettings.new,
                      ),
                      engineSettingsProviderNew.overrideWith(
                        _PreviewEngineSettings.new,
                      ),
                    ],
                    child: ColoredBox(
                      color: kBackgroundColor,
                      child: LayoutBuilder(
                        builder:
                            (context, constraints) => Row(
                              children: [
                                DesktopSidebar(
                                  current: location.pane,
                                  expanded: constraints.maxWidth >= 1000,
                                  readOnlyPreview: true,
                                  feedbackScreenshotKey: _previewKey,
                                  onSelect: (_, {required bool inNewTab}) {},
                                  onToggleExpanded: () {},
                                  onSearch: () {},
                                  onHowToUse: () {},
                                ),
                                Expanded(
                                  child: Column(
                                    children: [
                                      _PreviewTabs(title: location.title),
                                      Expanded(
                                        child:
                                            FutureBuilder<WebSignInPreviewData>(
                                              future: _data,
                                              builder:
                                                  (context, value) =>
                                                      _PreviewPage(
                                                        location: location,
                                                        data: value.data,
                                                      ),
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const ModalBarrier(
            key: ValueKey('web-sign-in-barrier'),
            color: Color(0x66000000),
            dismissible: false,
            barrierSemanticsDismissible: false,
          ),
          SafeArea(
            child: FocusScope(
              node: _authFocus,
              autofocus: true,
              onKeyEvent: (_, event) {
                final keyboard = HardwareKeyboard.instance;
                final modified =
                    keyboard.isControlPressed ||
                    keyboard.isMetaPressed ||
                    keyboard.isAltPressed;
                final key = event.logicalKey;
                if (!modified &&
                    (key == LogicalKeyboardKey.tab ||
                        key == LogicalKeyboardKey.enter ||
                        key == LogicalKeyboardKey.space ||
                        key == LogicalKeyboardKey.shiftLeft ||
                        key == LogicalKeyboardKey.shiftRight)) {
                  return KeyEventResult.ignored;
                }
                return KeyEventResult.handled;
              },
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Semantics(
                    scopesRoute: true,
                    namesRoute: true,
                    label: 'Sign in to explore ChessEver',
                    child: const DesktopWelcomeScreen(compact: true),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewBoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async => const BoardSettingsNew();
}

class _PreviewEngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async =>
      const EngineSettings(showEngineGauge: false, showEngineAnalysis: false);
}

class _PreviewTabs extends StatelessWidget {
  const _PreviewTabs({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) => Container(
    height: kDesktopChromeBarHeight,
    decoration: const BoxDecoration(
      color: kBlack2Color,
      border: Border(bottom: BorderSide(color: kDividerColor)),
    ),
    child: Row(
      children: [
        const SizedBox(width: 14),
        const Icon(Icons.arrow_back_rounded, color: kWhiteColor70, size: 18),
        const SizedBox(width: 22),
        const Icon(Icons.arrow_forward_rounded, color: kWhiteColor70, size: 18),
        const SizedBox(width: 24),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: _tab(
                  'Events',
                  Icons.emoji_events_outlined,
                  title == 'Events',
                ),
              ),
              if (title != 'Events')
                Flexible(
                  child: _tab(
                    title,
                    title == 'Likes'
                        ? Icons.favorite_border
                        : Icons.tab_outlined,
                    true,
                  ),
                ),
              if (MediaQuery.sizeOf(context).width >= 1100)
                Flexible(child: _tab('How to use', Icons.help_outline, false)),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18),
          child: Icon(
            Icons.account_circle_outlined,
            color: kWhiteColor70,
            size: 28,
          ),
        ),
      ],
    ),
  );
  Widget _tab(String label, IconData icon, bool active) => Container(
    width: 212,
    margin: const EdgeInsets.fromLTRB(0, 5, 8, 0),
    padding: const EdgeInsets.symmetric(horizontal: 18),
    decoration: BoxDecoration(
      color: active ? kBackgroundColor : kBlack3Color,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
      border: Border(
        top: BorderSide(
          color: active ? kPrimaryColor : Colors.transparent,
          width: 2,
        ),
      ),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: active ? kPrimaryColor : kWhiteColor70),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: kWhiteColor,
            ),
          ),
        ),
      ],
    ),
  );
}

class _PreviewPage extends StatelessWidget {
  const _PreviewPage({required this.location, required this.data});
  final WebSignInPreviewLocation location;
  final WebSignInPreviewData? data;

  @override
  Widget build(BuildContext context) {
    final likes = location.kind == 'likes';
    final games =
        data?.games(likes ? location.period : 'week') ??
        const <WebSignInPreviewGame>[];
    final sections = switch (location.kind) {
      'likes' || 'games' => const ['About', 'Games', 'Players'],
      'events' => const ['For You', 'Current', 'Past', 'Search'],
      'players' => const ['Players', 'Federations'],
      'library' => const ['My Databases', 'My Likes'],
      'collections' => const ['Collections', 'Following'],
      'calendar' => const ['Events', 'Calendar'],
      'board' => const ['Board', 'Notation', 'Explorer'],
      _ => [location.title],
    };
    final selected =
        likes || location.kind == 'games' ? 'Games' : sections.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Row(
            children: [
              Flexible(
                child: DesktopSegmentedTabs<String>(
                  selected: selected,
                  onChanged: (_) {},
                  tabs: [
                    for (final label in sections)
                      DesktopSegmentedTab(value: label, label: label),
                  ],
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: kDividerColor),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: const Text(
                  'Preview',
                  style: TextStyle(color: kWhiteColor70, fontSize: 11),
                ),
              ),
              if (MediaQuery.sizeOf(context).width >= 800) ...[
                const SizedBox(width: 16),
                const Icon(
                  Icons.view_agenda_outlined,
                  color: kWhiteColor70,
                  size: 19,
                ),
                const SizedBox(width: 18),
                const Icon(
                  Icons.table_rows_outlined,
                  color: kWhiteColor70,
                  size: 19,
                ),
                const SizedBox(width: 18),
                const Icon(
                  Icons.grid_view_rounded,
                  color: kPrimaryColor,
                  size: 19,
                ),
                const SizedBox(width: 18),
                const Icon(
                  Icons.refresh_rounded,
                  color: kWhiteColor70,
                  size: 19,
                ),
              ],
            ],
          ),
        ),
        if (likes)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                Flexible(
                  child: DesktopSegmentedTabs<String>(
                    selected: location.period,
                    onChanged: (_) {},
                    tabs: [
                      for (final p in const ['today', 'week', 'month', 'year'])
                        DesktopSegmentedTab(
                          value: p,
                          label: p[0].toUpperCase() + p.substring(1),
                        ),
                    ],
                  ),
                ),
                if (MediaQuery.sizeOf(context).width >= 800) ...[
                  const SizedBox(width: 22),
                  const Icon(
                    Icons.chevron_left,
                    color: kWhiteColor70,
                    size: 20,
                  ),
                  const SizedBox(width: 18),
                  Flexible(
                    child: Text(
                      data?.labels[location.period] ?? '',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: kWhiteColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 18),
                  const Icon(
                    Icons.chevron_right,
                    color: kWhiteColor70,
                    size: 20,
                  ),
                ],
              ],
            ),
          ),
        Expanded(
          child: switch (location.kind) {
            'private' || 'library' || 'collections' => _PrivateLayout(
              title: location.title,
              kind: location.kind,
            ),
            'players' => _PlayersPreview(games: games),
            'calendar' => _CalendarPreview(
              date: (data?.capturedAt ?? DateTime.now()).toLocal(),
              eventNames:
                  games
                      .map((g) => g.card.title)
                      .where((name) => name.isNotEmpty)
                      .toSet()
                      .toList(),
            ),
            'board' => _BoardPreview(games: games),
            'events' when data?.events.isNotEmpty == true => _EventsPreview(
              events: data!.events,
            ),
            _ => _GamesPreview(games: games, showLikes: likes),
          },
        ),
      ],
    );
  }
}

class _GamesPreview extends StatelessWidget {
  const _GamesPreview({required this.games, required this.showLikes});
  final List<WebSignInPreviewGame> games;
  final bool showLikes;
  @override
  Widget build(BuildContext context) {
    if (games.isEmpty) return const SizedBox.expand();
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = ((constraints.maxWidth - 32) / 320).floor().clamp(1, 5);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: games.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: .95,
          ),
          itemBuilder: (_, i) {
            final card = DesktopGameCard(
              data: games[i].card,
              onTap: null,
              layout: DesktopCardLayout.grid,
              selected: i == 0,
              allowStockfishFallback: false,
              visualPreviewOnly: true,
            );
            return showLikes
                ? DesktopBoardLikeBadge(likes: games[i].likes, child: card)
                : card;
          },
        );
      },
    );
  }
}

class _PrivateLayout extends StatelessWidget {
  const _PrivateLayout({required this.title, required this.kind});
  final String title, kind;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder:
        (context, constraints) => Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (constraints.maxWidth > 700)
                Container(
                  width: 190,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: kBlack2Color,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kDividerColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Icon(Icons.folder_outlined, color: kWhiteColor70),
                      const SizedBox(height: 12),
                      const Divider(color: kDividerColor),
                    ],
                  ),
                ),
              const SizedBox(width: 14),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: kBlack2Color,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kDividerColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.search_rounded,
                            color: kWhiteColor70,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Search $title',
                              style: const TextStyle(
                                color: kWhiteColor70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      const Divider(color: kDividerColor),
                      const SizedBox(height: 24),
                      Text(
                        'Your ${title.toLowerCase()} will appear after sign-in.',
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
  );
}

class _PlayersPreview extends StatelessWidget {
  const _PlayersPreview({required this.games});
  final List<WebSignInPreviewGame> games;
  @override
  Widget build(BuildContext context) {
    final players =
        <
          String,
          ({String name, String title, String federation, int rating})
        >{};
    for (final g in games) {
      final c = g.card;
      players[c.whiteName] = (
        name: c.whiteName,
        title: c.whiteTitle,
        federation: c.whiteFederation,
        rating: c.whiteRating,
      );
      players[c.blackName] = (
        name: c.blackName,
        title: c.blackTitle,
        federation: c.blackFederation,
        rating: c.blackRating,
      );
    }
    final rows =
        players.values.toList()..sort((a, b) => b.rating.compareTo(a.rating));
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: rows.length,
      separatorBuilder:
          (_, i) => const Divider(height: 1, color: kDividerColor),
      itemBuilder:
          (_, i) => SizedBox(
            height: 58,
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: kBlack3Color,
                  child: Icon(Icons.person_outline, color: kWhiteColor70),
                ),
                const SizedBox(width: 16),
                FederationFlag(
                  federation: rows[i].federation,
                  width: 24,
                  height: 16,
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 38,
                  child: Text(
                    rows[i].title,
                    style: const TextStyle(
                      color: kPrimaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    rows[i].name,
                    style: const TextStyle(color: kWhiteColor, fontSize: 14),
                  ),
                ),
                Text(
                  rows[i].rating > 0 ? '${rows[i].rating}' : '',
                  style: const TextStyle(color: kWhiteColor70),
                ),
              ],
            ),
          ),
    );
  }
}

class _BoardPreview extends StatelessWidget {
  const _BoardPreview({required this.games});
  final List<WebSignInPreviewGame> games;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder:
        (context, c) => Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Center(
                  child: SizedBox(
                    width: math.min(c.maxHeight * .85, c.maxWidth * .66),
                    child:
                        games.isEmpty
                            ? const SizedBox.shrink()
                            : AspectRatio(
                              aspectRatio: .88,
                              child: DesktopGameCard(
                                data: games.first.card,
                                onTap: null,
                                layout: DesktopCardLayout.grid,
                                allowStockfishFallback: false,
                                visualPreviewOnly: true,
                              ),
                            ),
                  ),
                ),
              ),
              if (c.maxWidth > 650)
                const Expanded(
                  child: _PrivateLayout(title: 'Notation', kind: 'private'),
                ),
            ],
          ),
        ),
  );
}

class _CalendarPreview extends StatelessWidget {
  const _CalendarPreview({required this.date, required this.eventNames});
  final DateTime date;
  final List<String> eventNames;
  @override
  Widget build(BuildContext context) {
    final first = DateTime(date.year, date.month, 1);
    final count = DateTime(date.year, date.month + 1, 0).day;
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return Padding(
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder:
            (context, outer) => Row(
              children: [
                if (outer.maxWidth >= 850) ...[
                  SizedBox(
                    width: 280,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Events',
                          style: TextStyle(
                            color: kWhiteColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 20),
                        for (final name in eventNames)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: kBlack2Color,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: kDividerColor),
                            ),
                            child: Text(
                              name,
                              style: const TextStyle(
                                color: kWhiteColor70,
                                fontSize: 13,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 20),
                ],
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '${months[date.month - 1]} ${date.year}',
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          for (final day in const [
                            'Mon',
                            'Tue',
                            'Wed',
                            'Thu',
                            'Fri',
                            'Sat',
                            'Sun',
                          ])
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Text(
                                  day,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: kWhiteColor70,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder:
                              (context, cells) => GridView.builder(
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: 42,
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 7,
                                      mainAxisExtent: cells.maxHeight / 6,
                                    ),
                                itemBuilder: (_, i) {
                                  final day = i - first.weekday + 2;
                                  return Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color:
                                          day == date.day
                                              ? kPrimaryColor.withValues(
                                                alpha: .08,
                                              )
                                              : kBlack2Color,
                                      border: Border.all(
                                        color: kDividerColor,
                                        width: .5,
                                      ),
                                    ),
                                    child: Text(
                                      day >= 1 && day <= count ? '$day' : '',
                                      style: const TextStyle(
                                        color: kWhiteColor70,
                                        fontSize: 13,
                                      ),
                                    ),
                                  );
                                },
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
      ),
    );
  }
}

class _EventsPreview extends StatelessWidget {
  const _EventsPreview({required this.events});
  final List<Map<String, dynamic>> events;
  @override
  Widget build(BuildContext context) => ListView.separated(
    padding: const EdgeInsets.all(20),
    physics: const NeverScrollableScrollPhysics(),
    itemCount: events.length,
    separatorBuilder: (_, i) => const SizedBox(height: 10),
    itemBuilder:
        (_, i) => Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kDividerColor),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.emoji_events_outlined,
                size: 28,
                color: kPrimaryColor,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      events[i]['name']?.toString() ?? '',
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      events[i]['location']?.toString() ?? '',
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
  );
}
