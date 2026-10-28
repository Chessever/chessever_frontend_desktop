import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/auth/desktop_guest_gate.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/state/desktop_window_role.dart';
import 'package:chessever/providers/guest_session_provider.dart';
import 'package:chessever/repository/local_storage/guest_session/guest_session_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final start = DateTime(2026, 9, 1, 9);
  DateTime day(int n, {int hours = 0}) =>
      start.add(Duration(days: n, hours: hours));

  group('GuestSessionState.gateAt', () {
    final fresh = GuestSessionState(startedAt: start);

    test('stays silent before day 7', () {
      expect(fresh.gateAt(day(0)), GuestGate.none);
      expect(fresh.gateAt(day(6)), GuestGate.none);
      expect(fresh.gateAt(day(6, hours: 23)), GuestGate.none);
    });

    test('soft prompt from day 7 through day 27', () {
      expect(fresh.gateAt(day(7)), GuestGate.softPrompt);
      expect(fresh.gateAt(day(8)), GuestGate.softPrompt);
      expect(fresh.gateAt(day(14)), GuestGate.softPrompt);
      expect(fresh.gateAt(day(27)), GuestGate.softPrompt);
    });

    test('forced sign-up from day 28', () {
      expect(fresh.gateAt(day(28)), GuestGate.forcedSignUp);
      expect(fresh.gateAt(day(29)), GuestGate.forcedSignUp);
    });

    test('constants match mobile', () {
      expect(kGuestSoftPromptAfter, const Duration(days: 7));
      expect(kGuestSoftPromptInterval, const Duration(days: 7));
      expect(kGuestForcedSignUpAfter, const Duration(days: 28));
    });

    test('a prompt shown 3 days ago does not re-fire', () {
      final state = GuestSessionState(startedAt: start, lastPromptAt: day(7));
      expect(state.gateAt(day(10)), GuestGate.none);
      expect(state.gateAt(day(13, hours: 23)), GuestGate.none);
    });

    test('re-prompts once a full week has passed since the last prompt', () {
      final state = GuestSessionState(startedAt: start, lastPromptAt: day(7));
      expect(state.gateAt(day(14)), GuestGate.softPrompt);
      expect(state.gateAt(day(21)), GuestGate.softPrompt);
    });

    test('a recent prompt never delays the day 28 requirement', () {
      final state = GuestSessionState(startedAt: start, lastPromptAt: day(27));
      expect(state.gateAt(day(28)), GuestGate.forcedSignUp);
    });

    test('clock moved backwards yields none, never a crash or forced', () {
      expect(
        GuestSessionState(startedAt: day(40)).gateAt(day(0)),
        GuestGate.none,
      );
      expect(
        GuestSessionState(startedAt: day(3)).gateAt(start),
        GuestGate.none,
      );
    });

    test('no clock yields none', () {
      expect(const GuestSessionState.unknown().gateAt(day(90)), GuestGate.none);
    });
  });

  group('GuestSessionRepository stamps', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('startIfMissing never moves an existing stamp', () async {
      final repository = GuestSessionRepository();
      await repository.clear();

      expect(await repository.startIfMissing(day(0)), day(0));
      expect(await repository.startIfMissing(day(20)), day(0));
      expect((await repository.read()).startedAt, day(0));
    });

    test('replaying guest start through the notifier keeps the clock', () async {
      final repository = GuestSessionRepository();
      await repository.clear();
      await repository.startIfMissing(day(0));

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(guestSessionProvider.future);
      await container
          .read(guestSessionProvider.notifier)
          .startGuestSession(now: day(15));

      expect(container.read(guestSessionProvider).value?.startedAt, day(0));
      expect((await repository.read()).startedAt, day(0));
    });

    test('markPromptShown persists the last prompt time', () async {
      final repository = GuestSessionRepository();
      await repository.clear();
      await repository.markPromptShown(day(9));
      expect((await repository.read()).lastPromptAt, day(9));
    });
  });

  group('reminder interruption rules', () {
    bool allowed({
      DesktopWindowRole role = DesktopWindowRole.main,
      bool startupComplete = true,
      bool modalOpen = false,
      bool armed = true,
      bool handling = false,
    }) {
      return canInterruptForDesktopGuestGate(
        windowRole: role,
        startupComplete: startupComplete,
        modalOpen: modalOpen,
        entryCheckArmed: armed,
        handlingGate: handling,
      );
    }

    test('fires only in the settled main window with no dialog', () {
      expect(allowed(), isTrue);
    });

    test('never fires in a detached window', () {
      expect(allowed(role: DesktopWindowRole.detached), isFalse);
    });

    test('never fires over an open dialog', () {
      expect(allowed(modalOpen: true), isFalse);
    });

    test('never fires during startup', () {
      expect(allowed(startupComplete: false), isFalse);
    });

    test('one check per app entry, never twice at once', () {
      expect(allowed(armed: false), isFalse);
      expect(allowed(handling: true), isFalse);
    });

    test('window role defaults to main and is overridable', () {
      final main = ProviderContainer();
      addTearDown(main.dispose);
      expect(main.read(desktopWindowRoleProvider), DesktopWindowRole.main);

      final detached = ProviderContainer(
        overrides: [
          desktopWindowRoleProvider.overrideWithValue(
            DesktopWindowRole.detached,
          ),
        ],
      );
      addTearDown(detached.dispose);
      expect(
        detached.read(desktopWindowRoleProvider),
        DesktopWindowRole.detached,
      );
    });

    test('dialog observer counts popup routes, not pages', () {
      final observer = DesktopGuestGateObserver.instance;
      observer.modalDepth.value = 0;
      addTearDown(() => observer.modalDepth.value = 0);

      final page = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      final dialog = RawDialogRoute<void>(
        pageBuilder: (_, _, _) => const SizedBox(),
      );

      observer.didPush(page, null);
      expect(observer.isModalOpen, isFalse);
      observer.didPush(dialog, page);
      expect(observer.isModalOpen, isTrue);
      observer.didPop(dialog, page);
      expect(observer.isModalOpen, isFalse);
      observer.didPop(dialog, page);
      expect(observer.modalDepth.value, 0);
    });
  });

  group('reminder decision', () {
    test('only guests are ever prompted', () {
      expect(
        resolveDesktopGuestGateAction(
          isGuest: false,
          session: GuestSessionState(startedAt: start),
          now: day(30),
        ),
        DesktopGuestGateAction.none,
      );
    });

    test('waits while the stamps are still loading', () {
      expect(
        resolveDesktopGuestGateAction(isGuest: true, session: null, now: day(30)),
        DesktopGuestGateAction.none,
      );
    });

    test('legacy guest with no stamp gets a clock, not a lockout', () {
      expect(
        resolveDesktopGuestGateAction(
          isGuest: true,
          session: const GuestSessionState.unknown(),
          now: day(90),
        ),
        DesktopGuestGateAction.startClock,
      );
    });

    test('maps the gate onto desktop surfaces', () {
      final state = GuestSessionState(startedAt: start);
      expect(
        resolveDesktopGuestGateAction(isGuest: true, session: state, now: day(7)),
        DesktopGuestGateAction.softPrompt,
      );
      expect(
        resolveDesktopGuestGateAction(
          isGuest: true,
          session: state,
          now: day(28),
        ),
        DesktopGuestGateAction.forcedSignIn,
      );
    });
  });

  group('account identity across windows', () {
    test('a new account bumps the generation, a token refresh does not', () {
      const guest = DesktopAccountIdentity(
        userId: 'guest',
        isAnonymous: true,
        generation: 3,
      );
      expect(
        advanceDesktopAccountIdentity(
          guest,
          userId: 'guest',
          isAnonymous: true,
        ),
        same(guest),
      );
      final upgraded = advanceDesktopAccountIdentity(
        guest,
        userId: 'member',
        isAnonymous: false,
      );
      expect(upgraded.generation, 4);
      expect(upgraded.isPermanent, isTrue);
    });

    test('linking in place still counts as an account change', () {
      const guest = DesktopAccountIdentity(userId: 'u1', isAnonymous: true);
      final linked = advanceDesktopAccountIdentity(
        guest,
        userId: 'u1',
        isAnonymous: false,
      );
      expect(linked.generation, 1);
    });

    test('results that land after the account changed are rejected', () {
      const before = DesktopAccountIdentity(userId: 'guest', isAnonymous: true);
      final after = advanceDesktopAccountIdentity(
        before,
        userId: 'member',
        isAnonymous: false,
      );
      expect(
        isDesktopAccountResultCurrent(capturedGeneration: 0, current: before),
        isTrue,
      );
      expect(
        isDesktopAccountResultCurrent(capturedGeneration: 0, current: after),
        isFalse,
      );
    });

    test('a detached window marks itself stale when the main window moved', () {
      const board = DesktopAccountIdentity(userId: 'guest', isAnonymous: true);
      final stale = reconcileDetachedAccountIdentity(
        board,
        publishedUserId: 'member',
        publishedIsAnonymous: false,
      );
      expect(stale.staleSession, isTrue);
      expect(stale.userId, 'guest');
      expect(stale.generation, 1);
      expect(
        isDesktopAccountResultCurrent(capturedGeneration: 1, current: stale),
        isFalse,
      );
      expect(
        reconcileDetachedAccountIdentity(
          stale,
          publishedUserId: 'member',
          publishedIsAnonymous: false,
        ),
        same(stale),
      );
    });

    test('nothing published is never treated as a change', () {
      const board = DesktopAccountIdentity(userId: 'guest', isAnonymous: true);
      expect(
        reconcileDetachedAccountIdentity(
          board,
          publishedUserId: null,
          publishedIsAnonymous: false,
        ),
        same(board),
      );
    });
  });
}
