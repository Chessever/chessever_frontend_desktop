import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/board_editor_pane.dart';
import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/panes/desktop_whats_new_home_pane.dart';
import 'package:chessever/desktop/panes/calendar_pane.dart';
import 'package:chessever/desktop/panes/opening_explorer_pane.dart';
import 'package:chessever/desktop/panes/countrymen_pane.dart';
import 'package:chessever/desktop/panes/favorites_pane.dart';
import 'package:chessever/desktop/panes/board_settings_pane.dart';
import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/panes/notification_settings_pane.dart';
import 'package:chessever/desktop/panes/placeholder_pane.dart';
import 'package:chessever/desktop/panes/player_profile_pane.dart';
import 'package:chessever/desktop/panes/player_score_card_pane.dart';
import 'package:chessever/desktop/panes/play_pane.dart';
import 'package:chessever/desktop/panes/play_profile_pane.dart';
import 'package:chessever/desktop/panes/players_pane.dart';
import 'package:chessever/desktop/panes/settings_pane.dart';
import 'package:chessever/desktop/panes/tournament_detail_pane.dart';
import 'package:chessever/desktop/panes/tournaments_pane.dart';
import 'package:chessever/desktop/services/local_chess_drop_zone.dart';
import 'package:chessever/desktop/widgets/paywall/desktop_billing_issue_dialog.dart';
import 'package:chessever/desktop/services/library_pgn_import_picker.dart';
import 'package:chessever/desktop/services/pgn_file_picker.dart';
import 'package:chessever/desktop/shell/command_palette.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/shell/desktop_pane_navigation.dart';
import 'package:chessever/desktop/shell/desktop_shell_intents.dart';
import 'package:chessever/desktop/shell/desktop_sidebar.dart';
import 'package:chessever/desktop/shell/desktop_tab_bar.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/desktop/widgets/pane_keyboard_scroll.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_board_shortcuts.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/board_explorer_scope.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/board_focus_mode.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/current_user_profile.dart';
import 'package:chessever/desktop/state/user_move_nags.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/board_tab_fen.dart';
import 'package:chessever/desktop/state/board_tab_sound_mute.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/persistent_tab_state.dart';

const _sidebarExpandedPreferenceKey = 'desktop_sidebar_expanded_v1';
const _sidebarAutoCollapseBreakpoint = 1500.0;

/// Top-level desktop shell: persistent sidebar + top bar + Chrome-style tab
/// bar + content area for the foreground tab.
///
/// Tabs live in `desktopTabsProvider`. The sidebar is still useful as a
/// category rail — selecting an item navigates the foreground tab, while
/// Cmd/Ctrl-clicking an item opens it in a new tab. Number shortcuts
/// (`Cmd/Ctrl+1..8`) jump through sidebar panes in visual order, while tab
/// management keeps the browser conventions for new/close tab, last tab,
/// `Ctrl+Tab`, and bracket cycling.
class DesktopShell extends HookConsumerWidget {
  const DesktopShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabsState = ref.watch(desktopTabsProvider);
    final tabsNotifier = ref.read(desktopTabsProvider.notifier);
    final activePane = ref.watch(desktopPaneProvider);
    final isLocalPgnLoading = ref.watch(
      localChessLibraryProvider.select((state) => state.isScanning),
    );
    final boardShortcutsActive = tabsState.active?.kind == TabKind.board;
    final boardFocusMode = ref.watch(boardFocusModeProvider);
    final boardFocusActive = boardShortcutsActive && boardFocusMode;
    final activeBoardShortcutDispatcher =
        boardShortcutsActive
            ? ref.watch(activeBoardShortcutDispatcherProvider)
            : null;
    final foregroundBoardShortcutDispatcher =
        activeBoardShortcutDispatcher?.tabId == tabsState.activeId
            ? activeBoardShortcutDispatcher
            : null;
    final boardShortcutMap =
        boardShortcutsActive
            ? (ref.watch(keyboardShortcutsProvider).valueOrNull ??
                BoardShortcutMap(defaultBoardShortcuts()))
            : null;
    final sidebarExpandedPreference = useState<bool>(true);
    final compactSidebarExpanded = useState<bool>(false);
    final sidebarPreferenceTouched = useRef<bool>(false);
    final tabPageStorageBucket = useMemoized(PageStorageBucket.new);
    final feedbackScreenshotKey = useMemoized(GlobalKey.new);

    useEffect(() {
      var disposed = false;
      AppDatabase.instance.getBool(_sidebarExpandedPreferenceKey).then((value) {
        if (disposed || sidebarPreferenceTouched.value || value == null) {
          return;
        }
        sidebarExpandedPreference.value = value;
      });
      return () => disposed = true;
    }, const []);

    void setSidebarExpandedPreference(bool expanded) {
      sidebarPreferenceTouched.value = true;
      sidebarExpandedPreference.value = expanded;
      unawaited(
        AppDatabase.instance.setBool(_sidebarExpandedPreferenceKey, expanded),
      );
    }

    // Prune per-tab metadata when tabs close so closed Board tab FENs,
    // closed Tournament-Detail tab tournaments, and closed Player-* tab
    // args don't accumulate forever.
    ref.listen<DesktopTabsState>(desktopTabsProvider, (prev, next) {
      if (prev == null) return;
      final liveIds = <String>{for (final t in next.tabs) t.id};
      for (final t in prev.tabs) {
        if (!liveIds.contains(t.id)) {
          ref.read(boardTabFenProvider.notifier).clear(t.id);
          ref.read(boardTabSoundMuteProvider.notifier).clear(t.id);
          ref.read(boardPaneSessionByTabIdProvider.notifier).clear(t.id);
          ref.read(tournamentByTabIdProvider.notifier).update((m) {
            if (!m.containsKey(t.id)) return m;
            final next = <String, dynamic>{...m}..remove(t.id);
            return Map<String, GroupEventCardModel>.from(next);
          });
          ref.read(playerScoreCardByTabIdProvider.notifier).update((m) {
            if (!m.containsKey(t.id)) return m;
            final next = <String, dynamic>{...m}..remove(t.id);
            return Map<String, PlayerStandingModel>.from(next);
          });
          ref.read(playerScoreCardContextByTabIdProvider.notifier).update((m) {
            if (!m.containsKey(t.id)) return m;
            final next = <String, dynamic>{...m}..remove(t.id);
            return Map<String, PlayerScoreCardTabContext>.from(next);
          });
          ref.read(playerProfileByTabIdProvider.notifier).update((m) {
            if (!m.containsKey(t.id)) return m;
            final next = <String, dynamic>{...m}..remove(t.id);
            return Map<String, PlayerProfileArgs>.from(next);
          });
          ref.read(boardTabGameArgsByTabIdProvider.notifier).update((m) {
            if (!m.containsKey(t.id)) return m;
            final next = <String, dynamic>{...m}..remove(t.id);
            return Map<String, BoardTabGameArgs>.from(next);
          });
          ref.read(boardExplorerScopeByTabIdProvider.notifier).update((m) {
            if (!m.containsKey(t.id)) return m;
            final next = <String, dynamic>{...m}..remove(t.id);
            return Map<String, BoardExplorerScope>.from(next);
          });
          ref.read(databaseWorkspaceArgsByTabIdProvider.notifier).update((m) {
            if (!m.containsKey(t.id)) return m;
            final next = <String, dynamic>{...m}..remove(t.id);
            return Map<String, DatabaseWorkspaceArgs>.from(next);
          });
          final treePlayerByTab = ref.read(
            playerOpeningTreePlayerByTabIdProvider,
          );
          final treePlayerId = treePlayerByTab[t.id];
          if (treePlayerId != null && treePlayerId.isNotEmpty) {
            final remainingTreeOwners = <String>[
              for (final entry in treePlayerByTab.entries)
                if (entry.key != t.id && entry.value == treePlayerId) entry.key,
            ];
            ref
                .read(playerOpeningTreePlayerByTabIdProvider.notifier)
                .update((m) => <String, String>{...m}..remove(t.id));
            if (remainingTreeOwners.isEmpty) {
              ref
                  .read(playerOpeningTreeProvider(treePlayerId).notifier)
                  .clear();
              ref.invalidate(playerOpeningTreeProvider(treePlayerId));
            }
          }
          // Closing a Play tab tears down its session — first drop the
          // args entry so any lingering watcher rebuilds without the
          // session, then invalidate the per-tab provider so its
          // notifier's `dispose` runs and the engine subprocess is
          // killed. The family is not autoDispose because Play sessions
          // need to survive tab switches.
          final hadPlayArgs = ref
              .read(playSessionArgsByTabIdProvider)
              .containsKey(t.id);
          if (hadPlayArgs) {
            ref
                .read(playSessionArgsByTabIdProvider.notifier)
                .update((m) => <String, PlaySessionArgs>{...m}..remove(t.id));
            ref.invalidate(playSessionProviderFor(t.id));
          }
          ref.read(userMoveNagsProvider.notifier).clearTab(t.id);
        }
      }
    });

    /// Sidebar nav handler — `inNewTab` is `true` when the user
    /// Cmd/Ctrl-clicks. Plain click usually navigates the *active* tab to the
    /// selected pane (main-route semantics), while protected workspace tabs
    /// such as an open game are preserved by the shared navigation helper.
    void openPane(DesktopPane pane, {bool inNewTab = false}) {
      openDesktopPaneFromContainer(
        ProviderScope.containerOf(context, listen: false),
        pane,
        inNewTab: inNewTab,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final autoCollapsed =
            constraints.maxWidth < _sidebarAutoCollapseBreakpoint;
        final sidebarExpanded =
            autoCollapsed
                ? compactSidebarExpanded.value
                : sidebarExpandedPreference.value;

        void setSidebarExpanded(bool expanded) {
          if (autoCollapsed) {
            compactSidebarExpanded.value = expanded;
            return;
          }
          setSidebarExpandedPreference(expanded);
        }

        void toggleSidebar() {
          setSidebarExpanded(!sidebarExpanded);
        }

        // Sidebar tap from the rail. Clicking the icon for the *current*
        // pane toggles sidebar expansion (so a collapsed rail can be
        // expanded by tapping its highlighted item, and re-tapping
        // collapses again). Any other tap navigates and auto-collapses
        // the sidebar so the content pane gets the screen back.
        void handleSidebarSelect(DesktopPane pane, {required bool inNewTab}) {
          if (!inNewTab && pane == activePane) {
            toggleSidebar();
            return;
          }
          openPane(pane, inNewTab: inNewTab);
          if (sidebarExpanded) {
            setSidebarExpanded(false);
          }
        }

        Future<void> openCommandPalette() {
          return CommandPalette.show(
            context,
            onSelectPane: openPane,
            onAction: (action) async {
              switch (action) {
                case CommandAction.toggleSidebar:
                  toggleSidebar();
                case CommandAction.openPreferences:
                  openPane(DesktopPane.settings);
                case CommandAction.importPgn:
                  await PgnFilePicker(ref).pickAndLoad();
                case CommandAction.openLocalChessFiles:
                  final path = await pickAndOpenLibraryPgnDatabase(ref);
                  if (path != null) openPane(DesktopPane.library);
                case CommandAction.flipBoard:
                  // Owned by the Board pane via the F shortcut.
                  break;
              }
            },
          );
        }

        Future<void> pastePgnFromClipboard() async {
          if (tabsState.active?.kind == TabKind.board) {
            foregroundBoardShortcutDispatcher?.invoke(BoardActionKey.pastePgn);
            return;
          }
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          final text = data?.text?.trim();
          if (text == null || text.isEmpty) return;
          try {
            ChessGame.fromPgn('', text);
          } catch (_) {
            return;
          }
          openDetachedPgnTab(ref, label: 'Clipboard PGN', pgn: text);
        }

        final shellShortcuts = <ShortcutActivator, Intent>{
          // Backspace route navigation is handled by the outer Focus below,
          // not by Shortcuts. Registering Backspace here consumes the key
          // before focused search/text fields can delete their text.
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
              const _OpenCommandPaletteIntent(),
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              const _OpenCommandPaletteIntent(),
          const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
              const _ImportPgnIntent(),
          const SingleActivator(LogicalKeyboardKey.keyO, control: true):
              const _ImportPgnIntent(),
          const SingleActivator(LogicalKeyboardKey.f1): const SwitchPaneIntent(
            DesktopPane.settings,
          ),
          const SingleActivator(
            LogicalKeyboardKey.f12,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.library),
          const SingleActivator(
            LogicalKeyboardKey.f2,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.players),
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              const _OpenCommandPaletteIntent(),
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              const _OpenCommandPaletteIntent(),
          const SingleActivator(
            LogicalKeyboardKey.keyL,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.library),
          const SingleActivator(
            LogicalKeyboardKey.keyP,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.players),
          const SingleActivator(
            LogicalKeyboardKey.keyT,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.tournaments),
          const SingleActivator(LogicalKeyboardKey.keyN, control: true):
              const _NewTabIntent(),
          const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
              const _PastePgnIntent(),
          const SingleActivator(LogicalKeyboardKey.keyV, control: true):
              const _PastePgnIntent(),
          const SingleActivator(
            LogicalKeyboardKey.digit1,
            meta: true,
          ): const SwitchPaneIntent(DesktopPane.tournaments),
          const SingleActivator(
            LogicalKeyboardKey.digit2,
            meta: true,
          ): const SwitchPaneIntent(DesktopPane.library),
          const SingleActivator(
            LogicalKeyboardKey.digit3,
            meta: true,
          ): const SwitchPaneIntent(DesktopPane.favorites),
          const SingleActivator(
            LogicalKeyboardKey.digit4,
            meta: true,
          ): const SwitchPaneIntent(DesktopPane.players),
          const SingleActivator(
            LogicalKeyboardKey.digit5,
            meta: true,
          ): const SwitchPaneIntent(DesktopPane.calendar),
          const SingleActivator(
            LogicalKeyboardKey.digit6,
            meta: true,
          ): const SwitchPaneIntent(DesktopPane.countrymen),
          const SingleActivator(
            LogicalKeyboardKey.digit7,
            meta: true,
          ): const SwitchPaneIntent(DesktopPane.board),
          const SingleActivator(
            LogicalKeyboardKey.digit8,
            meta: true,
          ): const SwitchPaneIntent(DesktopPane.play),
          const SingleActivator(LogicalKeyboardKey.digit9, meta: true):
              const _SwitchLastTabIntent(),
          const SingleActivator(
            LogicalKeyboardKey.digit1,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.tournaments),
          const SingleActivator(
            LogicalKeyboardKey.digit2,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.library),
          const SingleActivator(
            LogicalKeyboardKey.digit3,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.favorites),
          const SingleActivator(
            LogicalKeyboardKey.digit4,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.players),
          const SingleActivator(
            LogicalKeyboardKey.digit5,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.calendar),
          const SingleActivator(
            LogicalKeyboardKey.digit6,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.countrymen),
          const SingleActivator(
            LogicalKeyboardKey.digit7,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.board),
          const SingleActivator(
            LogicalKeyboardKey.digit8,
            control: true,
          ): const SwitchPaneIntent(DesktopPane.play),
          const SingleActivator(LogicalKeyboardKey.digit9, control: true):
              const _SwitchLastTabIntent(),
          const SingleActivator(LogicalKeyboardKey.tab, control: true):
              const _NextTabIntent(),
          const SingleActivator(
                LogicalKeyboardKey.tab,
                control: true,
                shift: true,
              ):
              const _PreviousTabIntent(),
          const SingleActivator(
                LogicalKeyboardKey.bracketRight,
                meta: true,
                shift: true,
              ):
              const _NextTabIntent(),
          const SingleActivator(
                LogicalKeyboardKey.bracketLeft,
                meta: true,
                shift: true,
              ):
              const _PreviousTabIntent(),
          const SingleActivator(
                LogicalKeyboardKey.arrowRight,
                meta: true,
                alt: true,
              ):
              const _NextTabIntent(),
          const SingleActivator(
                LogicalKeyboardKey.arrowLeft,
                meta: true,
                alt: true,
              ):
              const _PreviousTabIntent(),
          const SingleActivator(
            LogicalKeyboardKey.comma,
            meta: true,
          ): const SwitchPaneIntent(DesktopPane.settings),
          const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
              const _CloseTabIntent(),
          const SingleActivator(LogicalKeyboardKey.keyW, control: true):
              const _CloseTabIntent(),
          // Esc closes the active tab from any pane. The Board pane also
          // maps `closeWindow` (BoardActionKey) to Esc — that mapping is
          // applied later in this builder so the board's path takes
          // precedence when a board tab is active. Both paths route to
          // the same `desktopTabsProvider.close(activeTabId)` call.
          const SingleActivator(LogicalKeyboardKey.escape):
              const _CloseTabIntent(),
          const SingleActivator(LogicalKeyboardKey.keyT, meta: true):
              const _NewTabIntent(),
          const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
              const _ToggleSidebarIntent(),
        };
        final dispatcher = foregroundBoardShortcutDispatcher;
        final boardBindings = boardShortcutMap;
        if (dispatcher != null && boardBindings != null) {
          for (final action in BoardActionKey.values) {
            for (final chord in boardBindings.chordsFor(action)) {
              shellShortcuts[chord.toActivator()] = _BoardShortcutIntent(
                action,
              );
            }
          }
        }
        // Global search must win everywhere, including Board tabs with custom
        // keymaps. Re-apply after board bindings so Ctrl/Cmd+F always opens
        // the compact shell search instead of being swallowed by a pane.
        shellShortcuts[const SingleActivator(
              LogicalKeyboardKey.keyF,
              meta: true,
            )] =
            const _OpenCommandPaletteIntent();
        shellShortcuts[const SingleActivator(
              LogicalKeyboardKey.keyF,
              control: true,
            )] =
            const _OpenCommandPaletteIntent();

        return Focus(
          onKeyEvent: (node, event) {
            final searchResult = handleDesktopShellSearchKeyEvent(
              event: event,
              onSearch: () => unawaited(openCommandPalette()),
            );
            if (searchResult == KeyEventResult.handled) {
              return KeyEventResult.handled;
            }
            return handleDesktopShellBackspaceKeyEvent(
              event: event,
              canGoBack: tabsState.canGoBack,
              primaryFocus: FocusManager.instance.primaryFocus,
              onBack: tabsNotifier.goBack,
            );
          },
          child: FocusableActionDetector(
            autofocus: true,
            shortcuts: shellShortcuts,
            actions: <Type, Action<Intent>>{
              SwitchPaneIntent: CallbackAction<SwitchPaneIntent>(
                onInvoke: (intent) {
                  openPane(intent.pane);
                  return null;
                },
              ),
              _ToggleSidebarIntent: CallbackAction<_ToggleSidebarIntent>(
                onInvoke: (_) {
                  toggleSidebar();
                  return null;
                },
              ),
              _OpenCommandPaletteIntent:
                  CallbackAction<_OpenCommandPaletteIntent>(
                    onInvoke: (_) {
                      openCommandPalette();
                      return null;
                    },
                  ),
              _ImportPgnIntent: CallbackAction<_ImportPgnIntent>(
                onInvoke: (_) {
                  () async {
                    await PgnFilePicker(ref).pickAndLoad();
                  }();
                  return null;
                },
              ),
              _PastePgnIntent: CallbackAction<_PastePgnIntent>(
                onInvoke: (_) {
                  unawaited(pastePgnFromClipboard());
                  return null;
                },
              ),
              _CloseTabIntent: CallbackAction<_CloseTabIntent>(
                onInvoke: (_) {
                  final id = tabsState.activeId;
                  if (id != null) tabsNotifier.close(id);
                  return null;
                },
              ),
              _NewTabIntent: CallbackAction<_NewTabIntent>(
                onInvoke: (_) {
                  tabsNotifier.open(
                    TabKind.board,
                    reuseExisting: false,
                    focus: true,
                  );
                  return null;
                },
              ),
              _SwitchLastTabIntent: CallbackAction<_SwitchLastTabIntent>(
                onInvoke: (_) {
                  tabsNotifier.activateLast();
                  return null;
                },
              ),
              _NextTabIntent: CallbackAction<_NextTabIntent>(
                onInvoke: (_) {
                  tabsNotifier.activateNext();
                  return null;
                },
              ),
              _PreviousTabIntent: CallbackAction<_PreviousTabIntent>(
                onInvoke: (_) {
                  tabsNotifier.activatePrevious();
                  return null;
                },
              ),
              _BoardShortcutIntent: CallbackAction<_BoardShortcutIntent>(
                onInvoke: (intent) {
                  if (tabsState.active?.kind != TabKind.board) return null;
                  foregroundBoardShortcutDispatcher?.invoke(intent.action);
                  return null;
                },
              ),
            },
            child: Scaffold(
              backgroundColor: kBackgroundColor,
              body: DesktopBillingIssueGate(
                child: Stack(
                children: [
                  RepaintBoundary(
                    key: feedbackScreenshotKey,
                    child: LocalChessDropZone(
                      onChessPathsDropped: (paths) async {
                        // The Library and Board Editor panes wrap their own drop
                        // zones with pane-specific local-file handling.
                        // desktop_drop's nested targets *both* fire, so when
                        // either is foreground we leave handling to the pane.
                        final activePane = ref.read(desktopPaneProvider);
                        if (activePane == DesktopPane.library ||
                            activePane == DesktopPane.boardEditor) {
                          return;
                        }
                        final opened = await ref
                            .read(localChessLibraryProvider.notifier)
                            .openPaths(
                              paths,
                              sourceLabel: 'Dropped local files',
                            );
                        if (!opened) return;
                        ref
                            .read(desktopTabsProvider.notifier)
                            .open(TabKind.library);
                      },
                      // The "Update" chip used to float here as a Positioned overlay
                      // at top:8, left:8 — that landed on top of the sidebar's brand
                      // header and looked misaligned. It now lives inside DesktopTopBar
                      // (right after the sidebar-toggle button) so it aligns to the
                      // top bar's baseline like a real toolbar chip.
                      child: Row(
                        children: [
                          if (!boardFocusActive)
                            DesktopSidebar(
                              current: activePane,
                              expanded: sidebarExpanded,
                              autoCollapsed: autoCollapsed,
                              onToggleExpanded: toggleSidebar,
                              onSearch: () => unawaited(openCommandPalette()),
                              onSelect: handleSidebarSelect,
                              feedbackScreenshotKey: feedbackScreenshotKey,
                            ),
                          Expanded(
                            child: Column(
                              children: [
                                if (!boardFocusActive)
                                  DesktopTabBar(
                                    onOpenUserProfile:
                                        () => openCurrentUserProfileTab(ref),
                                  ),
                                Expanded(
                                  // One cursor-proximity field over all pane content:
                                  // every MotionCard inside magnifies by the cursor's
                                  // nearness instead of binary hover.
                                  child: CursorProximityScope(
                                    child: PageStorage(
                                      bucket: tabPageStorageBucket,
                                      child: _DesktopTabStack(
                                        tabs: tabsState.tabs,
                                        activeId: tabsState.activeId,
                                      ),
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
                  if (isLocalPgnLoading) const _DesktopPgnLoadingOverlay(),
                ],
              ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DesktopPgnLoadingOverlay extends StatelessWidget {
  const _DesktopPgnLoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: kBackgroundColor.withValues(alpha: 0.72),
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: kBlack2Color.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kPrimaryColor.withValues(alpha: 0.28)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 28,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                    ),
                  ),
                  SizedBox(width: 16),
                  Text(
                    'Loading PGN...',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopTabStack extends StatelessWidget {
  const _DesktopTabStack({required this.tabs, required this.activeId});

  final List<DesktopTab> tabs;
  final String? activeId;

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty || activeId == null) {
      return const DesktopWhatsNewHomePane();
    }

    final activeIndex = tabs.indexWhere((tab) => tab.id == activeId);
    if (activeIndex < 0) {
      return const PlaceholderPane(
        title: 'No tab',
        description: 'Open a tab from the sidebar to start.',
      );
    }

    return PersistentIndexedStack(
      index: activeIndex,
      sizing: StackFit.expand,
      children: [
        for (final tab in tabs)
          KeyedSubtree(
            key: ValueKey<String>('desktop-tab:${tab.id}:${tab.kind.name}'),
            child: PaneKeyboardScroll(child: _resolveTab(tab)),
          ),
      ],
    );
  }
}

Widget _resolveTab(DesktopTab? tab) {
  if (tab == null) {
    return const PlaceholderPane(
      title: 'No tab',
      description: 'Open a tab from the sidebar to start.',
    );
  }
  switch (tab.kind) {
    case TabKind.board:
      return BoardPane(tabId: tab.id);
    case TabKind.tournaments:
      return TournamentsPane(tabId: tab.id);
    case TabKind.tournamentDetail:
      return TournamentDetailPane(tabId: tab.id);
    case TabKind.library:
      return const LibraryPane();
    case TabKind.databaseWorkspace:
      return DatabaseWorkspacePane(tabId: tab.id);
    case TabKind.favorites:
      return const FavoritesPane();
    case TabKind.players:
      return const PlayersPane();
    case TabKind.calendar:
      return const CalendarPane();
    case TabKind.countrymen:
      return const CountrymenPane();
    case TabKind.settings:
      return const SettingsPane();
    case TabKind.openingExplorer:
      // Desktop-native master/detail layout — board on the left,
      // move-stats table in the middle, persistent filter panel on the
      // right. Replaces embedding the mobile screen (which spawned
      // bottom sheets for filters / sort / position-games).
      return OpeningExplorerPane(tabId: tab.id);
    case TabKind.boardEditor:
      return const BoardEditorPane();
    case TabKind.watch:
      return const PlaceholderPane(
        title: 'Watch',
        description: 'Coming next — live broadcasts list.',
      );
    case TabKind.playerScoreCard:
      return PlayerScoreCardPane(tabId: tab.id);
    case TabKind.playerProfile:
      return PlayerProfilePane(tabId: tab.id);
    case TabKind.userProfile:
      return const PlayProfilePane();
    case TabKind.boardSettings:
      return const BoardSettingsPane();
    case TabKind.notificationSettings:
      return const NotificationSettingsPane();
    case TabKind.play:
      return PlayPane(tabId: tab.id);
  }
}

@visibleForTesting
KeyEventResult handleDesktopShellSearchKeyEvent({
  required KeyEvent event,
  required VoidCallback onSearch,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  if (event.logicalKey != LogicalKeyboardKey.keyF) {
    return KeyEventResult.ignored;
  }

  final pressed = HardwareKeyboard.instance.logicalKeysPressed;
  final hasSearchModifier =
      pressed.contains(LogicalKeyboardKey.control) ||
      pressed.contains(LogicalKeyboardKey.controlLeft) ||
      pressed.contains(LogicalKeyboardKey.controlRight) ||
      pressed.contains(LogicalKeyboardKey.meta) ||
      pressed.contains(LogicalKeyboardKey.metaLeft) ||
      pressed.contains(LogicalKeyboardKey.metaRight);
  if (!hasSearchModifier) return KeyEventResult.ignored;

  onSearch();
  return KeyEventResult.handled;
}

@visibleForTesting
KeyEventResult handleDesktopShellBackspaceKeyEvent({
  required KeyEvent event,
  required bool canGoBack,
  required FocusNode? primaryFocus,
  required VoidCallback onBack,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  if (event.logicalKey != LogicalKeyboardKey.backspace) {
    return KeyEventResult.ignored;
  }
  final pressed = HardwareKeyboard.instance.logicalKeysPressed;
  final hasModifier =
      pressed.contains(LogicalKeyboardKey.control) ||
      pressed.contains(LogicalKeyboardKey.controlLeft) ||
      pressed.contains(LogicalKeyboardKey.controlRight) ||
      pressed.contains(LogicalKeyboardKey.meta) ||
      pressed.contains(LogicalKeyboardKey.metaLeft) ||
      pressed.contains(LogicalKeyboardKey.metaRight) ||
      pressed.contains(LogicalKeyboardKey.alt) ||
      pressed.contains(LogicalKeyboardKey.altLeft) ||
      pressed.contains(LogicalKeyboardKey.altRight) ||
      pressed.contains(LogicalKeyboardKey.shift) ||
      pressed.contains(LogicalKeyboardKey.shiftLeft) ||
      pressed.contains(LogicalKeyboardKey.shiftRight);
  if (hasModifier) return KeyEventResult.ignored;

  if (!shouldHandleDesktopBackspaceNavigation(
    canGoBack: canGoBack,
    primaryFocus: primaryFocus,
  )) {
    return KeyEventResult.ignored;
  }

  onBack();
  return KeyEventResult.handled;
}

@visibleForTesting
bool shouldHandleDesktopBackspaceNavigation({
  required bool canGoBack,
  required FocusNode? primaryFocus,
}) {
  if (!canGoBack) return false;
  final context = primaryFocus?.context;
  if (context == null) return true;
  if (context.widget is EditableText) return false;

  var insideEditableText = false;
  context.visitAncestorElements((element) {
    if (element.widget is EditableText) {
      insideEditableText = true;
      return false;
    }
    return true;
  });
  return !insideEditableText;
}

class _ToggleSidebarIntent extends Intent {
  const _ToggleSidebarIntent();
}

class _OpenCommandPaletteIntent extends Intent {
  const _OpenCommandPaletteIntent();
}

class _ImportPgnIntent extends Intent {
  const _ImportPgnIntent();
}

class _PastePgnIntent extends Intent {
  const _PastePgnIntent();
}

class _CloseTabIntent extends Intent {
  const _CloseTabIntent();
}

class _NewTabIntent extends Intent {
  const _NewTabIntent();
}

class _SwitchLastTabIntent extends Intent {
  const _SwitchLastTabIntent();
}

class _NextTabIntent extends Intent {
  const _NextTabIntent();
}

class _PreviousTabIntent extends Intent {
  const _PreviousTabIntent();
}

class _BoardShortcutIntent extends Intent {
  const _BoardShortcutIntent(this.action);

  final BoardActionKey action;
}
