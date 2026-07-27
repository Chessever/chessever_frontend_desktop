import 'dart:async';
import 'dart:io';
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
import 'package:chessever/desktop/panes/player_workspace_pane.dart';
import 'package:chessever/desktop/panes/play_pane.dart';
import 'package:chessever/desktop/panes/play_profile_pane.dart';
import 'package:chessever/desktop/panes/players_pane.dart';
import 'package:chessever/desktop/panes/settings_pane.dart';
import 'package:chessever/desktop/panes/desktop_smart_games_pane.dart';
import 'package:chessever/desktop/panes/tournament_detail_pane.dart';
import 'package:chessever/desktop/panes/tournaments_pane.dart';
import 'package:chessever/desktop/services/board_unsaved_analysis_guard.dart';
import 'package:chessever/desktop/services/local_chess_drop_zone.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart'
    show LocalChessScanProgress, localChessDatabaseDisplayNameForPaths;
import 'package:chessever/desktop/widgets/paywall/desktop_billing_issue_dialog.dart';
import 'package:chessever/desktop/services/library_pgn_import_picker.dart';
import 'package:chessever/desktop/services/pgn_file_picker.dart';
import 'package:chessever/desktop/shell/command_palette.dart';
import 'package:chessever/desktop/shell/desktop_main_routes.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/shell/desktop_pane_navigation.dart';
import 'package:chessever/desktop/shell/desktop_shell_intents.dart';
import 'package:chessever/desktop/shell/desktop_sidebar.dart';
import 'package:chessever/desktop/shell/desktop_tab_bar.dart';
import 'package:chessever/desktop/widgets/board_unsaved_analysis_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
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
import 'package:chessever/desktop/state/player_workspace.dart';
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
/// (`Cmd/Ctrl+1..9`) jump through sidebar panes in visual order. Tab
/// management keeps new/close tab, `Ctrl+Tab`, and bracket cycling; the
/// last-tab jump moves to `Cmd/Ctrl+Alt+9` because plain 9 now belongs to
/// the ninth sidebar route.
class DesktopShell extends HookConsumerWidget {
  const DesktopShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabsState = ref.watch(desktopTabsProvider);
    final tabsNotifier = ref.read(desktopTabsProvider.notifier);
    final boardArgsByTabId = ref.watch(boardTabGameArgsByTabIdProvider);
    final activeSidebarPane = sidebarPaneForActiveTab(
      tabsState.active,
      boardArgsByTabId: boardArgsByTabId,
    );
    final shellDropZoneEnabled =
        activeSidebarPane != DesktopPane.library &&
        activeSidebarPane != DesktopPane.boardEditor;
    final isLocalPgnLoading = ref.watch(
      localChessLibraryProvider.select((state) => state.isScanning),
    );
    final localPgnProgress = ref.watch(
      localChessLibraryProvider.select((state) => state.scanProgress),
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
    final closeConfirmationOpen = useRef<bool>(false);

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
          ref
              .read(boardTabAttachedLibrarySaveOriginByTabIdProvider.notifier)
              .clear(t.id);
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
          ref.read(playerProfileSectionByTabIdProvider.notifier).update((m) {
            if (!m.containsKey(t.id)) return m;
            return <String, PlayerProfileSection>{...m}..remove(t.id);
          });
          ref.read(playerWorkspacePlayerByTabIdProvider.notifier).update((m) {
            if (!m.containsKey(t.id)) return m;
            return <String, String>{...m}..remove(t.id);
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

    // File intake is available from the Library toolbar, drag-and-drop,
    // database tiles, and shell shortcuts. Report failures at the shell so an
    // unreadable/locked PGN is never silently mistaken for an empty database.
    ref.listen<String?>(
      localChessLibraryProvider.select((state) => state.error),
      (previous, next) {
        final message = next?.trim();
        if (message == null || message.isEmpty || message == previous?.trim()) {
          return;
        }
        showDesktopToast(
          context,
          message,
          error: true,
          duration: const Duration(seconds: 7),
        );
      },
    );
    ref.listen<String?>(
      localChessLibraryProvider.select((state) => state.warning),
      (previous, next) {
        final message = next?.trim();
        if (message == null || message.isEmpty || message == previous?.trim()) {
          return;
        }
        showDesktopToast(
          context,
          message,
          error: true,
          duration: const Duration(seconds: 7),
        );
      },
    );

    /// Sidebar nav handler — plain clicks open or activate the destination's
    /// category tab without rewriting the active tab. Cmd/Ctrl-click forces an
    /// additional destination tab.
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

        // Sidebar tap from the rail. Clicking the icon for the current pane
        // toggles expansion. Other pane selections should not undo the user's
        // manual desktop-width preference; compact widths still collapse after
        // navigation because the rail behaves like a temporary drawer.
        void handleSidebarSelect(DesktopPane pane, {required bool inNewTab}) {
          if (!inNewTab && pane == activeSidebarPane) {
            toggleSidebar();
            return;
          }
          openPane(pane, inNewTab: inNewTab);
          if (shouldCollapseDesktopSidebarAfterPaneSelection(
            autoCollapsed: autoCollapsed,
            sidebarExpanded: sidebarExpanded,
            selectedCurrentPane: pane == activeSidebarPane,
            inNewTab: inNewTab,
          )) {
            setSidebarExpanded(false);
          }
        }

        void showPgnOpenError(String message) {
          showDesktopToast(
            context,
            message,
            error: true,
            duration: const Duration(seconds: 7),
          );
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
                  await PgnFilePicker(
                    ref,
                    onError: showPgnOpenError,
                  ).pickAndLoad();
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

        Future<void> closeActiveTabWithUnsavedAnalysisGuard() async {
          final id = ref.read(desktopTabsProvider).activeId;
          if (id == null) return;
          final session = ref.read(boardPaneSessionByTabIdProvider)[id];
          if (boardSessionHasUnsavedAnalysis(session)) {
            if (closeConfirmationOpen.value) return;
            closeConfirmationOpen.value = true;
            final confirmed = await confirmDiscardBoardAnalysis(
              context,
            ).whenComplete(() => closeConfirmationOpen.value = false);
            if (!context.mounted || !confirmed) return;
          }
          ref.read(desktopTabsProvider.notifier).close(id);
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
                LogicalKeyboardKey.digit9,
                meta: true,
                alt: true,
              ):
              const _SwitchLastTabIntent(),
          const SingleActivator(
                LogicalKeyboardKey.digit9,
                control: true,
                alt: true,
              ):
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
        for (final binding in desktopMainRouteShortcutBindings()) {
          shellShortcuts[SingleActivator(
            binding.key,
            meta: true,
          )] = SwitchPaneIntent(binding.pane);
          shellShortcuts[SingleActivator(
            binding.key,
            control: true,
          )] = SwitchPaneIntent(binding.pane);
        }
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
                    await PgnFilePicker(
                      ref,
                      onError: showPgnOpenError,
                    ).pickAndLoad();
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
                  unawaited(closeActiveTabWithUnsavedAnalysisGuard());
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
                        enabled: shellDropZoneEnabled,
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
                                sourceLabel:
                                    localChessDatabaseDisplayNameForPaths(
                                      paths,
                                    ),
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
                                current: activeSidebarPane,
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
                                      showSidebarToggle:
                                          Platform.isMacOS && !sidebarExpanded,
                                      sidebarAutoCollapsed: autoCollapsed,
                                      onToggleSidebar: toggleSidebar,
                                    ),
                                  Expanded(
                                    child: PageStorage(
                                      bucket: tabPageStorageBucket,
                                      child: _DesktopTabStack(
                                        tabs: tabsState.tabs,
                                        activeId: tabsState.activeId,
                                        feedbackScreenshotKey:
                                            feedbackScreenshotKey,
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
                    if (isLocalPgnLoading)
                      _DesktopPgnLoadingOverlay(progress: localPgnProgress),
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
  const _DesktopPgnLoadingOverlay({this.progress});

  final LocalChessScanProgress? progress;

  @override
  Widget build(BuildContext context) {
    final fraction = progress?.fraction;
    final percentLabel =
        progress == null ? null : '${progress!.percent.clamp(0, 100)}%';
    final phase = progress?.message.trim();
    final title = _localProgressTitle(phase);
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints.tightFor(width: 280),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        value: fraction,
                        strokeWidth: 2.5,
                        valueColor: const AlwaysStoppedAnimation(kPrimaryColor),
                        backgroundColor: kWhiteColor.withValues(alpha: 0.12),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            percentLabel == null
                                ? title
                                : '$title $percentLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kWhiteColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (phase != null && phase.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              phase,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: kWhiteColor.withValues(alpha: 0.72),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: fraction,
                              minHeight: 4,
                              valueColor: const AlwaysStoppedAnimation(
                                kPrimaryColor,
                              ),
                              backgroundColor: kWhiteColor.withValues(
                                alpha: 0.12,
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
    );
  }
}

String _localProgressTitle(String? phase) {
  final lower = phase?.toLowerCase() ?? '';
  if (lower.contains('waiting')) {
    return 'Waiting for local database...';
  }
  if (lower.contains('cache') ||
      lower.contains('migrat') ||
      lower.contains('local database')) {
    return 'Preparing local database...';
  }
  if (lower.contains('importing file') || lower.startsWith('file ')) {
    return 'Importing PGN...';
  }
  return 'Loading PGN...';
}

class _DesktopTabStack extends StatelessWidget {
  const _DesktopTabStack({
    required this.tabs,
    required this.activeId,
    required this.feedbackScreenshotKey,
  });

  final List<DesktopTab> tabs;
  final String? activeId;
  final GlobalKey feedbackScreenshotKey;

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty || activeId == null) {
      return DesktopWhatsNewHomePane(
        feedbackScreenshotKey: feedbackScreenshotKey,
      );
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
            child: PaneKeyboardScroll(child: resolveDesktopTabContent(tab)),
          ),
      ],
    );
  }
}

Widget resolveDesktopTabContent(DesktopTab? tab) {
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
    case TabKind.smartGames:
      return DesktopSmartGamesPane(tabId: tab.id);
    case TabKind.library:
      return const LibraryPane();
    case TabKind.databaseWorkspace:
      return DatabaseWorkspacePane(tabId: tab.id);
    case TabKind.favorites:
      return const FavoritesPane();
    case TabKind.players:
      return PlayerWorkspacePane(tabId: tab.id);
    case TabKind.rankings:
      return const RankingsPane();
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
      return ProviderScope(
        key: ValueKey('opening-explorer-scope-${tab.id}'),
        overrides: [
          gamebaseExplorerProvider.overrideWith(
            (ref) => GamebaseExplorerNotifier(ref),
          ),
        ],
        child: OpeningExplorerPane(tabId: tab.id),
      );
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
bool shouldCollapseDesktopSidebarAfterPaneSelection({
  required bool autoCollapsed,
  required bool sidebarExpanded,
  required bool selectedCurrentPane,
  required bool inNewTab,
}) {
  if (!autoCollapsed || !sidebarExpanded || selectedCurrentPane || inNewTab) {
    return false;
  }
  return true;
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
