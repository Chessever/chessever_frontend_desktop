import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/state/my_likes_provider.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_date_gate_prompt.dart';
import 'package:chessever/desktop/widgets/desktop_date_group_card.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_lock_reasons.dart';
import 'package:chessever/desktop/widgets/desktop_locked_content.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/library/library_table_row_style.dart';
import 'package:chessever/desktop/widgets/library/my_likes/like_tags_dialog.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/repository/liked_games/liked_analyses_query.dart';
import 'package:chessever/repository/liked_games/liked_games_provider.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/models/like_tag.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/save_to_library_guard.dart';
import 'package:chessever/widgets/paywall/premium_paywall_sheet.dart';

/// Selection id the Library rail uses for the My Likes destination.
const String kMyLikesDestinationId = '__library_my_likes__';

typedef MyLikesOpenCallback =
    void Function(
      SavedAnalysis analysis,
      List<SavedAnalysis> openable, {
      bool newWindow,
    });

enum _LikeRowAction { open, openWindow, tags, copyPgn, copyTo, moveTo, remove }

enum _ExportChoice { premium, slice }

/// The My Likes destination inside the Library.
///
/// Browsing, searching, filtering, sorting, tagging and removing are free for
/// every like. Content actions (open, copy, export, copy or move into a
/// database) are free for likes from today and the previous six local days,
/// and are re-checked the moment the user takes them. Older likes stay listed,
/// drawn locked, and are never deleted.
class MyLikesView extends HookConsumerWidget {
  const MyLikesView({
    super.key,
    required this.onOpen,
    this.databaseTargets = const <LibraryFolder>[],
  });

  final MyLikesOpenCallback onOpen;

  /// Regular cloud databases a like can be copied or moved into.
  final List<LibraryFolder> databaseTargets;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewAsync = ref.watch(myLikesViewProvider);
    final query = ref.watch(myLikesQueryProvider);
    final tagCounts = ref.watch(myLikesTagCountsProvider);
    final searchController = useTextEditingController(text: query.search);
    final debounce = useRef<Timer?>(null);
    final selectedId = useState<String?>(null);
    final collapsed = useState<Set<String>>(const <String>{});
    final focusNode = useFocusNode(debugLabel: 'my-likes');
    useEffect(() => () => debounce.value?.cancel(), const []);

    final data = viewAsync.valueOrNull;

    List<SavedAnalysis> visibleOrder() => [
      for (final section in data?.sections ?? const [])
        for (final entry in section.value) entry.analysis,
    ];

    void onSearchChanged(String value) {
      debounce.value?.cancel();
      debounce.value = Timer(const Duration(milliseconds: 250), () {
        ref.read(myLikesQueryProvider.notifier).setSearch(value);
      });
    }

    Future<void> openLike(SavedAnalysis analysis, {bool newWindow = false}) =>
        _openLike(
          context,
          ref,
          analysis,
          visibleOrder(),
          onOpen,
          newWindow: newWindow,
        );

    Future<void> onRowAction(SavedAnalysis analysis, _LikeRowAction action) =>
        _handleRowAction(
          context,
          ref,
          analysis,
          action,
          visibleOrder: visibleOrder(),
          onOpen: onOpen,
          databaseTargets: databaseTargets,
        );

    KeyEventResult onKey(FocusNode _, KeyEvent event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      final order = visibleOrder();
      if (order.isEmpty) return KeyEventResult.ignored;
      final index = order.indexWhere((a) => a.id == selectedId.value);
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowUp) {
        final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
        final next = (index < 0 ? 0 : index + step).clamp(0, order.length - 1);
        selectedId.value = order[next].id;
        return KeyEventResult.handled;
      }
      if (index < 0) return KeyEventResult.ignored;
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        unawaited(openLike(order[index]));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.delete ||
          key == LogicalKeyboardKey.backspace) {
        unawaited(onRowAction(order[index], _LikeRowAction.remove));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final visibleTags = [
      for (final tag in kLikeTags)
        if ((tagCounts[tag.label] ?? 0) > 0 || query.tags.contains(tag.label))
          tag,
    ];

    return Focus(
      focusNode: focusNode,
      onKeyEvent: onKey,
      child: ColoredBox(
        color: kBackgroundColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Row(
                children: [
                  const Text(
                    'My Likes',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (data != null) ...[
                    const SizedBox(width: 10),
                    Text(
                      data.totalLiked == 1
                          ? '1 game'
                          : '${data.totalLiked} games',
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 13,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  const Spacer(),
                  Flexible(
                    child: DesktopSearchField(
                      controller: searchController,
                      maxWidth: 280,
                      hintText: 'Search player, event or title',
                      onChanged: onSearchChanged,
                      onClear: () {
                        debounce.value?.cancel();
                        searchController.clear();
                        ref.read(myLikesQueryProvider.notifier).clearSearch();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Builder(
                    builder:
                        (buttonContext) => DesktopToolbarPillButton(
                          label: query.sort.label,
                          icon: Icons.swap_vert_rounded,
                          tooltip: 'Sort likes',
                          onPress: () => _pickSort(buttonContext, ref, query),
                        ),
                  ),
                  const SizedBox(width: 8),
                  Builder(
                    builder:
                        (buttonContext) => DesktopToolbarPillButton(
                          label:
                              query.structuredFilterCount == 0
                                  ? 'Filters'
                                  : 'Filters ${query.structuredFilterCount}',
                          icon: Icons.tune_rounded,
                          tabularFigures: true,
                          tone:
                              query.structuredFilterCount == 0
                                  ? DesktopToolbarPillTone.neutral
                                  : DesktopToolbarPillTone.primary,
                          tooltip: 'Filter by result or speed',
                          onPress:
                              () => _pickFilters(buttonContext, ref, query),
                        ),
                  ),
                  const SizedBox(width: 8),
                  DesktopToolbarPillButton(
                    label: 'Export PGN',
                    icon: Icons.file_download_outlined,
                    tooltip: 'Export the likes in this list as one PGN file',
                    onPress:
                        data == null || data.visibleCount == 0
                            ? null
                            : () => _exportLikes(context, ref, visibleOrder()),
                  ),
                ],
              ),
            ),
            if (visibleTags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 0,
                  children: [
                    for (final tag in visibleTags)
                      LikeTagToggle(
                        tag: tag,
                        count: tagCounts[tag.label] ?? 0,
                        selected: query.tags.contains(tag.label),
                        onPressed:
                            () => ref
                                .read(myLikesQueryProvider.notifier)
                                .toggleTag(tag.label),
                      ),
                  ],
                ),
              ),
            if (data != null && data.lockedCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Text(
                  'Likes from the last 7 days open free. '
                  '${data.lockedCount == 1 ? '1 older like stays' : '${data.lockedCount} older likes stay'} '
                  'here, locked, until you go Premium.',
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ),
            Expanded(
              child: viewAsync.when(
                skipLoadingOnReload: true,
                loading:
                    () => const Center(
                      child: SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                        ),
                      ),
                    ),
                error:
                    (error, _) => _MyLikesMessage(
                      title: "Couldn't load your likes",
                      body: 'Check your connection and try again.',
                      actionLabel: 'Retry',
                      onAction: () {
                        ref.invalidate(myLikesRowsProvider);
                        unawaited(
                          ref.read(likedGamesProvider.notifier).refresh(),
                        );
                      },
                    ),
                data: (data) {
                  if (data.isEmpty) {
                    return const _MyLikesMessage(
                      title: 'No likes yet',
                      body:
                          "Right-click any game and choose Like game to keep it here.",
                    );
                  }
                  if (data.hasNoMatches) {
                    return _MyLikesMessage(
                      title: 'No likes match',
                      body: 'Try a different search, tag or filter.',
                      actionLabel: 'Clear all',
                      onAction: () {
                        debounce.value?.cancel();
                        searchController.clear();
                        ref.read(myLikesQueryProvider.notifier).clearAll();
                      },
                    );
                  }
                  return _MyLikesList(
                    data: data,
                    sortLabel: query.sort.label,
                    selectedId: selectedId.value,
                    collapsed: collapsed.value,
                    onToggleSection: (key) {
                      final next = <String>{...collapsed.value};
                      if (!next.remove(key)) next.add(key);
                      collapsed.value = next;
                    },
                    onSelect: (analysis) {
                      selectedId.value = analysis.id;
                      focusNode.requestFocus();
                    },
                    onOpen: (analysis) => openLike(analysis),
                    onContextMenu: (analysis, position) async {
                      selectedId.value = analysis.id;
                      final action = await _showRowMenu(
                        context,
                        position,
                        analysis,
                        canCopyOrMove: databaseTargets.isNotEmpty,
                      );
                      if (action == null || !context.mounted) return;
                      await onRowAction(analysis, action);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _likedOnLabel(SavedAnalysis analysis) =>
    DateFormat('EEEE, MMM d').format(likedAtOf(analysis));

Future<bool> _admitLikeContentAction(
  BuildContext context,
  WidgetRef ref,
  SavedAnalysis analysis,
  DesktopAction action,
) {
  return resolveDesktopDateGate(
    context,
    evaluate:
        () => likedGameDecision(
          analysis,
          action,
          subscription: ref.read(subscriptionProvider),
          entitlement: ref.read(desktopEntitlementProvider),
        ),
    title: 'This like is older than 7 days',
    body:
        'Free opens, copies and exports likes from today and the previous '
        '6 days. You liked this game on ${_likedOnLabel(analysis)}. Premium '
        'opens your full like history.',
  );
}

Future<void> _openLike(
  BuildContext context,
  WidgetRef ref,
  SavedAnalysis analysis,
  List<SavedAnalysis> visibleOrder,
  MyLikesOpenCallback onOpen, {
  bool newWindow = false,
}) async {
  if (analysis.id.isEmpty) return;
  final admitted = await _admitLikeContentAction(
    context,
    ref,
    analysis,
    DesktopAction.openContent,
  );
  if (!admitted || !context.mounted) return;
  // Recomputed now, not when the list was drawn, so the board's game list
  // never carries a like that crossed the window since.
  final openable = openableLikedAnalyses(
    visibleOrder,
    subscription: ref.read(subscriptionProvider),
    entitlement: ref.read(desktopEntitlementProvider),
  );
  onOpen(analysis, openable, newWindow: newWindow);
}

Future<void> _handleRowAction(
  BuildContext context,
  WidgetRef ref,
  SavedAnalysis analysis,
  _LikeRowAction action, {
  required List<SavedAnalysis> visibleOrder,
  required MyLikesOpenCallback onOpen,
  required List<LibraryFolder> databaseTargets,
}) async {
  switch (action) {
    case _LikeRowAction.open:
      await _openLike(context, ref, analysis, visibleOrder, onOpen);
    case _LikeRowAction.openWindow:
      await _openLike(
        context,
        ref,
        analysis,
        visibleOrder,
        onOpen,
        newWindow: true,
      );
    case _LikeRowAction.tags:
      final likeId = analysis.sourceGameId;
      if (likeId == null || likeId.isEmpty) return;
      await showLikeTagsDialog(context, likeId);
    case _LikeRowAction.copyPgn:
      if (!await _admitLikeContentAction(
        context,
        ref,
        analysis,
        DesktopAction.copy,
      )) {
        return;
      }
      await Clipboard.setData(
        ClipboardData(text: exportGameToPgn(analysis.chessGame).trim()),
      );
      if (context.mounted) showDesktopToast(context, 'PGN copied');
    case _LikeRowAction.copyTo:
    case _LikeRowAction.moveTo:
      await _copyOrMoveLike(
        context,
        ref,
        analysis,
        move: action == _LikeRowAction.moveTo,
        targets: databaseTargets,
      );
    case _LikeRowAction.remove:
      final removed = await ref
          .read(likedGamesProvider.notifier)
          .removeAnalysis(analysis);
      if (!context.mounted) return;
      showDesktopToast(
        context,
        removed ? 'Removed from My Likes' : "Couldn't remove this like.",
        error: !removed,
      );
  }
}

/// Copying or moving a like into a regular database is a content action (the
/// Likes window applies) and it creates a counted saved game, so capacity is
/// checked before anything is written. A move is checked exactly like a copy:
/// the row leaves the uncounted Likes collection and starts counting.
Future<void> _copyOrMoveLike(
  BuildContext context,
  WidgetRef ref,
  SavedAnalysis analysis, {
  required bool move,
  required List<LibraryFolder> targets,
}) async {
  if (analysis.id.isEmpty || targets.isEmpty) return;
  if (!await _admitLikeContentAction(
    context,
    ref,
    analysis,
    DesktopAction.save,
  )) {
    return;
  }
  if (!context.mounted) return;
  final target = await _pickDatabase(
    context,
    targets,
    title: move ? 'Move to database' : 'Save a copy to database',
  );
  if (target == null || target.isLikedGames || !context.mounted) return;
  if (!await canSaveMoreGames(context, gamesToAdd: 1)) return;
  if (!context.mounted) return;

  final repo = ref.read(libraryRepositoryProvider);
  try {
    if (move) {
      await repo.moveAnalysisToFolder(analysis.id, target.id);
      await ref.read(likedGamesProvider.notifier).refresh();
    } else {
      await repo.createSavedAnalysis(
        analysis.copyWith(id: '', folderId: target.id),
      );
    }
    if (!context.mounted) return;
    showDesktopToast(
      context,
      move
          ? 'Moved to ${target.displayName}'
          : 'Copied to ${target.displayName}',
    );
  } catch (_) {
    if (!context.mounted) return;
    showDesktopToast(
      context,
      move ? "Couldn't move this game." : "Couldn't copy this game.",
      error: true,
    );
  }
}

Future<void> _exportLikes(
  BuildContext context,
  WidgetRef ref,
  List<SavedAnalysis> visible,
) async {
  LikedGamesExportSlice evaluate() => likedGamesExportSlice(
    visible,
    subscription: ref.read(subscriptionProvider),
    entitlement: ref.read(desktopEntitlementProvider),
  );

  var slice = evaluate();
  if (slice.undetermined > 0) {
    showDesktopToast(
      context,
      "Couldn't confirm your membership. Check your connection and try again.",
      error: true,
    );
    return;
  }
  var toExport = slice.accessible;
  if (slice.locked > 0) {
    final choice = await showDesktopDialog<_ExportChoice>(
      context,
      builder:
          (_) => _ExportSliceDialog(
            accessible: slice.accessible.length,
            locked: slice.locked,
          ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == _ExportChoice.premium) {
      await showPremiumPaywallSheet(context: context);
      if (!context.mounted) return;
      // Re-evaluated after the sheet: a purchase exports everything, a
      // declined upgrade exports the free seven-day slice.
      slice = evaluate();
      if (slice.undetermined > 0) {
        showDesktopToast(
          context,
          "Couldn't confirm your membership. Try the export again.",
          error: true,
        );
        return;
      }
    }
    toExport = slice.accessible;
  }
  if (toExport.isEmpty) {
    showDesktopToast(context, 'Nothing to export.');
    return;
  }

  final pgn = [
    for (final analysis in toExport) exportGameToPgn(analysis.chessGame).trim(),
  ].where((text) => text.isNotEmpty).join('\n\n');
  final destination = await FilePicker.platform.saveFile(
    dialogTitle: 'Export My Likes as PGN',
    fileName: 'my_likes.pgn',
    type: FileType.custom,
    allowedExtensions: const ['pgn'],
  );
  if (destination == null) return;
  final path =
      destination.toLowerCase().endsWith('.pgn')
          ? destination
          : '$destination.pgn';
  try {
    await File(path).writeAsString('$pgn\n', flush: true);
    if (!context.mounted) return;
    showDesktopToast(
      context,
      toExport.length == 1
          ? 'Exported 1 game'
          : 'Exported ${toExport.length} games',
    );
  } catch (_) {
    if (!context.mounted) return;
    showDesktopToast(context, "Couldn't write the PGN file.", error: true);
  }
}

Future<_LikeRowAction?> _showRowMenu(
  BuildContext context,
  Offset position,
  SavedAnalysis analysis, {
  required bool canCopyOrMove,
}) {
  final hasLikeId = analysis.sourceGameId?.isNotEmpty == true;
  return showDesktopContextMenu<_LikeRowAction>(
    context: context,
    position: position,
    width: 248,
    entries: [
      const DesktopContextMenuItem(
        value: _LikeRowAction.open,
        icon: Icons.open_in_new_rounded,
        label: 'Open in board',
      ),
      const DesktopContextMenuItem(
        value: _LikeRowAction.openWindow,
        icon: Icons.open_in_new_rounded,
        label: 'Open in new window',
      ),
      const DesktopContextMenuDivider(),
      DesktopContextMenuItem(
        value: _LikeRowAction.tags,
        icon: Icons.sell_outlined,
        label: 'Edit tags',
        enabled: hasLikeId,
      ),
      const DesktopContextMenuItem(
        value: _LikeRowAction.copyPgn,
        icon: Icons.content_copy_rounded,
        label: 'Copy PGN',
      ),
      DesktopContextMenuItem(
        value: _LikeRowAction.copyTo,
        icon: Icons.library_add_outlined,
        label: 'Save a copy to database',
        enabled: canCopyOrMove,
      ),
      DesktopContextMenuItem(
        value: _LikeRowAction.moveTo,
        icon: Icons.drive_file_move_outline,
        label: 'Move to database',
        enabled: canCopyOrMove,
      ),
      const DesktopContextMenuDivider(),
      const DesktopContextMenuItem(
        value: _LikeRowAction.remove,
        icon: Icons.heart_broken_outlined,
        label: 'Remove like',
        destructive: true,
      ),
    ],
  );
}

Future<void> _pickSort(
  BuildContext context,
  WidgetRef ref,
  LikedAnalysesQuery query,
) async {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null) return;
  final origin = box.localToGlobal(Offset(0, box.size.height + 4));
  final picked = await showDesktopContextMenu<LikedGamesSort>(
    context: context,
    position: origin,
    width: 220,
    entries: [
      for (final sort in LikedGamesSort.values)
        DesktopContextMenuItem(
          value: sort,
          icon:
              sort == query.sort
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
          label: sort.label,
        ),
    ],
  );
  if (picked != null) ref.read(myLikesQueryProvider.notifier).setSort(picked);
}

Future<void> _pickFilters(
  BuildContext context,
  WidgetRef ref,
  LikedAnalysesQuery query,
) async {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null) return;
  final origin = box.localToGlobal(Offset(0, box.size.height + 4));
  final picked = await showDesktopContextMenu<Object>(
    context: context,
    position: origin,
    width: 220,
    entries: [
      for (final result in LikedGamesResultFilter.values)
        DesktopContextMenuItem<Object>(
          value: result,
          icon:
              result == query.result
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
          label: result.label,
        ),
      const DesktopContextMenuDivider<Object>(),
      for (final speed in LikedGamesTimeControlFilter.values)
        DesktopContextMenuItem<Object>(
          value: speed,
          icon:
              speed == query.timeControl
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
          label: speed.label,
        ),
    ],
  );
  final notifier = ref.read(myLikesQueryProvider.notifier);
  if (picked is LikedGamesResultFilter) notifier.setResult(picked);
  if (picked is LikedGamesTimeControlFilter) notifier.setTimeControl(picked);
}

Future<LibraryFolder?> _pickDatabase(
  BuildContext context,
  List<LibraryFolder> targets, {
  required String title,
}) {
  return showDesktopDialog<LibraryFolder>(
    context,
    builder: (_) => _DatabasePickerDialog(title: title, targets: targets),
  );
}

class _MyLikesList extends StatelessWidget {
  const _MyLikesList({
    required this.data,
    required this.sortLabel,
    required this.selectedId,
    required this.collapsed,
    required this.onToggleSection,
    required this.onSelect,
    required this.onOpen,
    required this.onContextMenu,
  });

  final MyLikesData data;
  final String sortLabel;
  final String? selectedId;
  final Set<String> collapsed;
  final ValueChanged<String> onToggleSection;
  final ValueChanged<SavedAnalysis> onSelect;
  final ValueChanged<SavedAnalysis> onOpen;
  final void Function(SavedAnalysis analysis, Offset position) onContextMenu;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        const SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          sliver: SliverToBoxAdapter(child: _MyLikesColumnsHeader()),
        ),
        for (var i = 0; i < data.sections.length; i++) ...[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(24, i == 0 ? 8 : 16, 24, 6),
            sliver: SliverToBoxAdapter(
              child: DesktopDateGroupCard(
                label:
                    data.sections[i].key == kMyLikesSortedSectionKey
                        ? sortLabel
                        : formatLikedDateHeader(data.sections[i].key),
                gameCount: data.sections[i].value.length,
                collapsed: collapsed.contains(data.sections[i].key),
                onToggle: () => onToggleSection(data.sections[i].key),
              ),
            ),
          ),
          if (!collapsed.contains(data.sections[i].key))
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              sliver: SliverList.builder(
                itemCount: data.sections[i].value.length,
                itemBuilder: (context, index) {
                  final entry = data.sections[i].value[index];
                  return _MyLikesRow(
                    entry: entry,
                    showFullDate:
                        data.sections[i].key == kMyLikesSortedSectionKey,
                    selected: entry.analysis.id == selectedId,
                    onSelect: () => onSelect(entry.analysis),
                    onOpen: () => onOpen(entry.analysis),
                    onContextMenu:
                        (position) => onContextMenu(entry.analysis, position),
                  );
                },
              ),
            ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

const double _kLockColumn = 28;
const double _kResultColumn = 64;
const double _kEcoColumn = 56;
const double _kLikedColumn = 96;

TextStyle get _headerStyle => const TextStyle(
  color: kLightGreyColor,
  fontSize: 11.5,
  fontWeight: FontWeight.w600,
);

class _MyLikesColumnsHeader extends StatelessWidget {
  const _MyLikesColumnsHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 0, 12, 0),
      child: Row(
        children: [
          const SizedBox(width: _kLockColumn),
          Expanded(flex: 4, child: Text('White', style: _headerStyle)),
          Expanded(flex: 4, child: Text('Black', style: _headerStyle)),
          SizedBox(
            width: _kResultColumn,
            child: Text(
              'Result',
              textAlign: TextAlign.center,
              style: _headerStyle,
            ),
          ),
          Expanded(flex: 4, child: Text('Event', style: _headerStyle)),
          SizedBox(width: _kEcoColumn, child: Text('ECO', style: _headerStyle)),
          Expanded(flex: 3, child: Text('Tags', style: _headerStyle)),
          SizedBox(
            width: _kLikedColumn,
            child: Text(
              'Liked',
              textAlign: TextAlign.right,
              style: _headerStyle,
            ),
          ),
        ],
      ),
    );
  }
}

class _MyLikesRow extends StatefulWidget {
  const _MyLikesRow({
    required this.entry,
    required this.showFullDate,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
    required this.onContextMenu,
  });

  final MyLikesEntry entry;
  final bool showFullDate;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final ValueChanged<Offset> onContextMenu;

  @override
  State<_MyLikesRow> createState() => _MyLikesRowState();
}

class _MyLikesRowState extends State<_MyLikesRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final md = entry.analysis.chessGame.metadata;
    String meta(String key) => (md[key]?.toString() ?? '').trim();
    final event = entry.game.eventName ?? '';
    final liked =
        widget.showFullDate
            ? DateFormat('MMM d, y').format(entry.likedAt)
            : DateFormat.Hm().format(entry.likedAt);

    final cells = Row(
      children: [
        Expanded(
          flex: 4,
          child: LibraryTablePlayerCell(
            name: entry.game.whitePlayer.name,
            federation: entry.game.whitePlayer.federation,
            fideId: entry.game.whitePlayer.fideId,
            title: entry.game.whitePlayer.title,
            rating: meta('WhiteElo'),
          ),
        ),
        Expanded(
          flex: 4,
          child: LibraryTablePlayerCell(
            name: entry.game.blackPlayer.name,
            federation: entry.game.blackPlayer.federation,
            fideId: entry.game.blackPlayer.fideId,
            title: entry.game.blackPlayer.title,
            rating: meta('BlackElo'),
          ),
        ),
        SizedBox(
          width: _kResultColumn,
          child: LibraryTableResultPill(result: meta('Result')),
        ),
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              event,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kWhiteColor70, fontSize: 12.5),
            ),
          ),
        ),
        SizedBox(
          width: _kEcoColumn,
          child: Align(
            alignment: Alignment.centerLeft,
            child: LibraryTableEcoCell(eco: meta('ECO')),
          ),
        ),
        Expanded(flex: 3, child: _TagLine(tags: entry.analysis.tags)),
        SizedBox(
          width: _kLikedColumn,
          child: Text(
            liked,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        onDoubleTap: widget.onOpen,
        onSecondaryTapUp: (details) {
          widget.onSelect();
          widget.onContextMenu(details.globalPosition);
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.only(right: 12),
          decoration: librarySelectedRowDecoration(
            selected: widget.selected,
            hovered: _hovered,
          ),
          child: Row(
            children: [
              SizedBox(
                width: _kLockColumn,
                child: Center(
                  child:
                      entry.isLocked
                          ? const DesktopLockGlyph(reason: kLikeLockedReason)
                          : null,
                ),
              ),
              Expanded(
                child: DesktopDesaturated(
                  enabled: entry.isLocked,
                  child: cells,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TagLine extends StatelessWidget {
  const _TagLine({required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        children: [
          for (final label in tags.take(2)) ...[
            SizedBox.square(
              dimension: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: likeTagByLabel(label)?.color ?? kLightGreyColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kWhiteColor70, fontSize: 12),
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (tags.length > 2)
            Text(
              '+${tags.length - 2}',
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

class _MyLikesMessage extends StatelessWidget {
  const _MyLikesMessage({
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              DesktopToolbarPillButton(
                label: actionLabel!,
                icon: Icons.refresh_rounded,
                onPress: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ExportSliceDialog extends StatelessWidget {
  const _ExportSliceDialog({required this.accessible, required this.locked});

  final int accessible;
  final int locked;

  @override
  Widget build(BuildContext context) {
    final lockedCopy =
        locked == 1 ? '1 older like needs' : '$locked older likes need';
    return DesktopDateGateDialog(
      title: 'Export likes from the last 7 days?',
      body:
          accessible == 0
              ? 'Free exports likes from today and the previous 6 days. '
                  '$lockedCopy Premium.'
              : '$accessible ${accessible == 1 ? 'game' : 'games'} can be '
                  'exported free. $lockedCopy Premium.',
      dismissLabel: accessible == 0 ? 'Not now' : 'Export $accessible',
      premiumLabel: 'See Premium',
      onDismiss:
          () => Navigator.of(
            context,
          ).pop(accessible == 0 ? null : _ExportChoice.slice),
      onPremium: () => Navigator.of(context).pop(_ExportChoice.premium),
    );
  }
}

class _DatabasePickerDialog extends StatelessWidget {
  const _DatabasePickerDialog({required this.title, required this.targets});

  final String title;
  final List<LibraryFolder> targets;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 480),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kDividerColor),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 18, 8, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final folder in targets)
                        _DatabasePickerRow(
                          folder: folder,
                          onTap: () => Navigator.of(context).pop(folder),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DatabasePickerRow extends StatefulWidget {
  const _DatabasePickerRow({required this.folder, required this.onTap});

  final LibraryFolder folder;
  final VoidCallback onTap;

  @override
  State<_DatabasePickerRow> createState() => _DatabasePickerRowState();
}

class _DatabasePickerRowState extends State<_DatabasePickerRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: _hovered ? kBlack3Color : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                Icons.storage_rounded,
                size: 16,
                color: _hovered ? kWhiteColor : kWhiteColor70,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.folder.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _hovered ? kWhiteColor : kWhiteColor70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
