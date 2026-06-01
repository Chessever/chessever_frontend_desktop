import 'dart:async';
import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/auth/desktop_subscription_view.dart';
import 'package:chessever/desktop/services/auth/desktop_auth_service.dart';
import 'package:chessever/desktop/widgets/desktop_country_picker.dart';
import 'package:chessever/desktop/widgets/desktop_icon.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/providers/pending_favorite_players_provider.dart';
import 'package:chessever/screens/players/providers/player_providers.dart';
import 'package:chessever/services/fide_photo_service.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/country_utils.dart';
import 'package:chessever/utils/favorite_constants.dart';
import 'package:chessever/utils/favorites_migration.dart';
import 'package:chessever/utils/svg_asset.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';

final _desktopOnboardingSelectedFideIdsProvider = StateProvider<Set<String>>(
  (ref) => <String>{},
);

/// Desktop onboarding (premium-only app — sign-in and a subscription are
/// required to leave it):
///
///   1. Welcome — explains the desktop-specific affordances.
///   2. Country — drives Countrymen / "from your federation" filters.
///   3. Favorite players — desktop Forui list backed by mobile providers.
///   4. Account — sign in with Google or Apple. No guest path.
///   5. Subscribe — Stripe Checkout in the browser, or restore an existing
///      App Store / Play Store / web subscription.
class DesktopOnboardingScreen extends HookConsumerWidget {
  const DesktopOnboardingScreen({super.key, required this.onCompleted});

  final Future<void> Function(String? userId) onCompleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = useState<int>(0);
    final country = useState<Country?>(null);
    final countryWasPicked = useState<bool>(false);
    final completing = useState<bool>(false);
    final authError = useState<String?>(null);
    final savedCountry = ref.watch(countryDropdownProvider).valueOrNull;

    useEffect(() {
      if (country.value == null && savedCountry != null) {
        country.value = savedCountry;
      }
      return null;
    }, [savedCountry?.countryCode]);

    void persistCountry() {
      if (!countryWasPicked.value) return;
      final selected = country.value;
      if (selected == null) return;
      ref
          .read(countryDropdownProvider.notifier)
          .selectCountry(selected.countryCode);
    }

    Future<void> flushFavorites() async {
      await FavoritesMigration.cleanupBadMigrationDataIfNeeded();
      await ref
          .read(pendingFavoriteSelectionsProvider.notifier)
          .flushToSupabase();
      ref.invalidate(_desktopOnboardingSelectedFideIdsProvider);
    }

    Future<void> completeOnboarding() async {
      completing.value = true;
      authError.value = null;
      try {
        persistCountry();
        final user = Supabase.instance.client.auth.currentUser;
        if (user == null) {
          authError.value =
              'Session lost. Please sign in again to finish setup.';
          return;
        }
        await flushFavorites();
        await onCompleted(user.id);
      } catch (e) {
        authError.value = _friendlyAuthError(e);
      } finally {
        completing.value = false;
      }
    }

    Future<void> signIn(Future<Session?> Function() action) async {
      completing.value = true;
      authError.value = null;
      try {
        persistCountry();
        final session = await action();
        final userId =
            session?.user.id ?? Supabase.instance.client.auth.currentUser?.id;

        if (userId == null) {
          authError.value = 'Could not finish sign-in. Please try again.';
          return;
        }

        // Flush picks now while we have a real user id; the next step
        // (Subscribe) does the actual onCompleted handoff.
        await flushFavorites();
        // Advance to the subscription step.
        step.value = 4;
      } catch (e) {
        authError.value = _friendlyAuthError(e);
      } finally {
        completing.value = false;
      }
    }

    Future<void> switchAccount() async {
      completing.value = true;
      authError.value = null;
      try {
        await DesktopAuthService.instance.signOut();
        step.value = 3;
      } catch (e) {
        authError.value = _friendlyAuthError(e);
      } finally {
        completing.value = false;
      }
    }

    final user = Supabase.instance.client.auth.currentUser;
    final isFullyAuthenticated = user != null && user.isAnonymous != true;
    final accountEmail =
        user?.email ?? user?.userMetadata?['email']?.toString();
    final selectedCountryCode =
        country.value?.countryCode ?? savedCountry?.countryCode;

    return FTheme(
      data: FThemes.zinc.dark,
      child: Scaffold(
        backgroundColor: kBackgroundColor,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120, maxHeight: 760),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 268,
                    child: _OnboardingRail(
                      step: step.value,
                      selectedCountry: country.value ?? savedCountry,
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      children: [
                        _StepperHeader(step: step.value, total: 5),
                        const SizedBox(height: 18),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            child: KeyedSubtree(
                              key: ValueKey(step.value),
                              child: switch (step.value) {
                                0 => const _WelcomeStep(),
                                1 => _CountryStep(
                                  selected: country.value ?? savedCountry,
                                  onPicked: (c) {
                                    country.value = c;
                                    countryWasPicked.value = true;
                                  },
                                ),
                                2 => _DesktopPlayerSelectionStep(
                                  countryCode: selectedCountryCode,
                                  onComplete: () async => step.value = 3,
                                ),
                                3 => _AccountStep(
                                  isFullyAuthenticated: isFullyAuthenticated,
                                  email: user?.email,
                                  busy: completing.value,
                                  error: authError.value,
                                  onContinue: () {
                                    // Already signed in — go straight to
                                    // the Subscribe step.
                                    step.value = 4;
                                  },
                                  onGoogle:
                                      () => signIn(
                                        DesktopAuthService
                                            .instance
                                            .signInWithGoogle,
                                      ),
                                  onApple:
                                      () => signIn(
                                        DesktopAuthService
                                            .instance
                                            .signInWithApple,
                                      ),
                                ),
                                _ => _SubscribeStep(
                                  onSubscribed: completeOnboarding,
                                  onSwitchAccount: switchAccount,
                                  email: accountEmail,
                                  switchingAccount: completing.value,
                                  error: authError.value,
                                ),
                              },
                            ),
                          ),
                        ),
                        if (step.value < 2) ...[
                          const SizedBox(height: 16),
                          _Footer(
                            isFirstStep: step.value == 0,
                            completing: completing.value,
                            onBack: () => step.value -= 1,
                            onNext: () {
                              persistCountry();
                              step.value += 1;
                            },
                          ),
                        ],
                      ],
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

String _friendlyAuthError(Object error) {
  final text = error.toString();
  if (text.toLowerCase().contains('cancel')) return 'Sign-in was cancelled.';
  if (text.contains('Apple sign-in timed out') ||
      text.contains('Provider sign-in timed out') ||
      text.contains('timed out')) {
    return 'Apple sign-in timed out. Check Supabase Apple OAuth and allow '
        'http://127.0.0.1:*/auth/callback as a redirect URL.';
  }
  if (text.contains('AuthApiException') ||
      text.contains('exchangeCodeForSession')) {
    return 'Supabase rejected the provider sign-in. Make sure Apple OAuth is '
        'enabled with its Services ID and secret in the Supabase dashboard.';
  }
  if (text.length <= 220) return text;
  return '${text.substring(0, 220)}...';
}

class _StepperHeader extends StatelessWidget {
  const _StepperHeader({required this.step, required this.total});

  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < total; i++) ...[
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 4,
              decoration: BoxDecoration(
                color: i <= step ? kPrimaryColor : kDividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (i < total - 1) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _OnboardingRail extends StatelessWidget {
  const _OnboardingRail({required this.step, required this.selectedCountry});

  final int step;
  final Country? selectedCountry;

  @override
  Widget build(BuildContext context) {
    final items = [
      _RailItemData(Icons.waving_hand_outlined, 'Start', 'Desktop basics'),
      _RailItemData(
        Icons.flag_outlined,
        'Country',
        selectedCountry?.countryCode ?? 'Federation',
      ),
      _RailItemData(Icons.star_outline_rounded, 'Players', 'Follow 3'),
      _RailItemData(Icons.lock_open_rounded, 'Account', 'Sign in to sync'),
      _RailItemData(Icons.workspace_premium_rounded, 'Subscribe', 'Premium'),
    ];

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/pngs/new_app_logo.png',
              width: 44,
              height: 44,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'ChessEver setup',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'A short setup so desktop opens with the same personalized feeds as mobile.',
            style: TextStyle(color: kWhiteColor70, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 22),
          for (var i = 0; i < items.length; i++) ...[
            _RailItem(
              data: items[i],
              index: i,
              active: i == step,
              complete: i < step,
            ),
            if (i < items.length - 1) const SizedBox(height: 8),
          ],
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kBlack3Color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kDividerColor),
            ),
            child: const Text(
              'Your picks are saved before the app opens, so Favorites and Countrymen work immediately.',
              style: TextStyle(
                color: kLightGreyColor,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailItemData {
  const _RailItemData(this.icon, this.title, this.subtitle);

  final IconData icon;
  final String title;
  final String subtitle;
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.data,
    required this.index,
    required this.active,
    required this.complete,
  });

  final _RailItemData data;
  final int index;
  final bool active;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final color = active || complete ? kPrimaryColor : kWhiteColor70;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color:
            active ? kPrimaryColor.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color:
              active
                  ? kPrimaryColor.withValues(alpha: 0.35)
                  : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color:
                    complete
                        ? kPrimaryColor
                        : kBlackColor.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                complete ? Icons.check_rounded : data.icon,
                color: complete ? kBackgroundColor : color,
                size: 15,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.title,
                  style: TextStyle(
                    color: active ? kWhiteColor : kWhiteColor70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  data.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kLightGreyColor, fontSize: 11),
                ),
              ],
            ),
          ),
          Text(
            '${index + 1}',
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep();

  @override
  Widget build(BuildContext context) {
    return _StepSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Welcome to ChessEver Desktop',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 30,
              fontWeight: FontWeight.w700,
              height: 1.08,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Set up the same account, federation, and favorite-player feed you use on mobile.',
            style: TextStyle(color: kWhiteColor70, fontSize: 14, height: 1.45),
          ),
          const SizedBox(height: 26),
          LayoutBuilder(
            builder: (context, constraints) {
              final twoColumns = constraints.maxWidth >= 700;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final tip in _welcomeTips)
                    SizedBox(
                      width:
                          twoColumns
                              ? (constraints.maxWidth - 12) / 2
                              : constraints.maxWidth,
                      child: _Tip(tip: tip),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

const _welcomeTips = [
  _TipData(
    Icons.login_rounded,
    'Existing account or fresh start',
    'Sign in if you already use ChessEver, or continue as a guest and upgrade later.',
  ),
  _TipData(
    Icons.star_rounded,
    'Favorite-player feed',
    'Pick three players now so Favorites and For You are useful immediately.',
  ),
  _TipData(
    Icons.flag_rounded,
    'Countrymen filters',
    'Your federation drives country-based player and game highlights.',
  ),
  _TipData(
    Icons.desktop_windows_rounded,
    'Desktop board workflow',
    'Drag pieces, use keyboard navigation, and drop PGNs straight into the app.',
  ),
];

class _TipData {
  const _TipData(this.icon, this.title, this.body);

  final IconData icon;
  final String title;
  final String body;
}

class _Tip extends StatelessWidget {
  const _Tip({required this.tip});

  final _TipData tip;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(tip.icon, size: 18, color: kPrimaryColor),
          const SizedBox(height: 10),
          Text(
            tip.title,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            tip.body,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _CountryStep extends ConsumerWidget {
  const _CountryStep({required this.selected, required this.onPicked});

  final Country? selected;
  final ValueChanged<Country> onPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _StepSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Pick your federation',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 26,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'This powers Countrymen filtering and players-from-your-federation recommendations. You can change it later.',
            style: TextStyle(color: kWhiteColor70, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 24),
          _CountryPickerButton(selected: selected, onPicked: onPicked),
          const SizedBox(height: 20),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kDividerColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'What this changes',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const _CountryBenefit(
                    icon: Icons.people_alt_outlined,
                    text: 'Countrymen pane opens with your federation.',
                  ),
                  const _CountryBenefit(
                    icon: Icons.auto_awesome_outlined,
                    text:
                        'Player suggestions are ordered toward your country first.',
                  ),
                  const _CountryBenefit(
                    icon: Icons.push_pin_outlined,
                    text: 'Auto-pin can prioritize games from your country.',
                  ),
                  const Spacer(),
                  if (selected != null)
                    Text(
                      '${selected!.flagEmoji} ${selected!.name}',
                      style: const TextStyle(
                        color: kPrimaryColor,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountryBenefit extends StatelessWidget {
  const _CountryBenefit({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 16, color: kPrimaryColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountryPickerButton extends StatefulWidget {
  const _CountryPickerButton({required this.selected, required this.onPicked});

  final Country? selected;
  final ValueChanged<Country> onPicked;

  @override
  State<_CountryPickerButton> createState() => _CountryPickerButtonState();
}

class _CountryPickerButtonState extends State<_CountryPickerButton> {
  Future<void> _pickCountry() async {
    final picked = await showDesktopCountryPicker(
      context,
      initialCountry: widget.selected,
    );
    if (picked != null) {
      widget.onPicked(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.selected;

    return SizedBox(
      width: double.infinity,
      height: 58,
      child: _OnboardingButton(
        tone: _OnboardingButtonTone.secondary,
        onPress: () => unawaited(_pickCountry()),
        prefix:
            c == null
                ? const Icon(Icons.flag_outlined, size: 16)
                : Text(c.flagEmoji, style: const TextStyle(fontSize: 20)),
        suffix: const Icon(Icons.expand_more_rounded, size: 18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            c?.name ?? 'Choose your country',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: c == null ? kLightGreyColor : kWhiteColor,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopPlayerSelectionStep extends HookConsumerWidget {
  const _DesktopPlayerSelectionStep({
    required this.countryCode,
    required this.onComplete,
  });

  final String? countryCode;
  final Future<void> Function() onComplete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchController = useTextEditingController();
    final scrollController = useScrollController();
    final searchQuery = useState('');
    final debounceTimer = useRef<Timer?>(null);
    final selectedIds = ref.watch(_desktopOnboardingSelectedFideIdsProvider);
    final playerState = ref.watch(onboardingPlayerProvider);
    final existingFavorites = ref.watch(favoritePlayersProviderNew);
    final players = playerState.valueOrNull ?? const <Map<String, dynamic>>[];
    final code = countryCode ?? 'US';

    useEffect(() {
      void listener() {
        final text = searchController.text;
        searchQuery.value = text;
        ref.read(playerSearchQueryProvider.notifier).state = text;
        debounceTimer.value?.cancel();
        debounceTimer.value = Timer(const Duration(milliseconds: 300), () {
          ref.read(onboardingPlayerProvider.notifier).setSearchQuery(text);
        });
      }

      searchController.addListener(listener);
      return () {
        debounceTimer.value?.cancel();
        searchController.removeListener(listener);
      };
    }, [searchController]);

    useEffect(() {
      if (code.isNotEmpty) {
        ref.read(onboardingPlayerProvider.notifier).setCountry(code);
      }
      return null;
    }, [code]);

    useEffect(() {
      Future.microtask(() {
        ref.read(onboardingPlayerProvider.notifier).initFirstPage();
      });
      return null;
    }, const []);

    final existingFavoriteIds = existingFavorites.maybeWhen(
      data:
          (favorites) =>
              favorites
                  .map((favorite) => favorite.fideId ?? '')
                  .where((id) => id.isNotEmpty)
                  .toSet(),
      orElse: () => <String>{},
    );
    final existingFavoriteIdsKey = existingFavoriteIds.toList()..sort();
    useEffect(() {
      if (existingFavoriteIds.isEmpty) return null;
      Future.microtask(() {
        final notifier = ref.read(
          _desktopOnboardingSelectedFideIdsProvider.notifier,
        );
        if (notifier.state.isEmpty) {
          notifier.state = {...existingFavoriteIds};
        }
      });
      return null;
    }, [existingFavoriteIdsKey.join(',')]);

    useEffect(() {
      void onScroll() {
        if (!scrollController.hasClients) return;
        final remaining =
            scrollController.position.maxScrollExtent -
            scrollController.position.pixels;
        if (remaining <= 260) {
          ref.read(onboardingPlayerProvider.notifier).fetchNextPage();
        }
      }

      scrollController.addListener(onScroll);
      return () => scrollController.removeListener(onScroll);
    }, [scrollController]);

    final recommended = _recommendedPlayers(players, countryCode: code);
    final isSearching = searchQuery.value.trim().isNotEmpty;
    final visiblePlayers = isSearching ? players : recommended.players;
    final isLoading = playerState.isLoading && players.isEmpty;
    final selectedCount = selectedIds.length;
    final canContinue = selectedCount >= kFreeFavoriteLimit;

    return _StepSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Follow 3 players',
                        style: TextStyle(
                          color: kWhiteColor,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        recommended.hasCountryMatches && !isSearching
                            ? 'Players from your federation are shown first. Search any FIDE player.'
                            : 'Search any FIDE player, or pick from the global recommendations.',
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                _SelectionCounter(count: selectedCount),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
            child: Row(
              children: [
                const Icon(
                  Icons.search_rounded,
                  color: kLightGreyColor,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FTextField(
                    controller: searchController,
                    hint: 'Find any player...',
                    textInputAction: TextInputAction.search,
                  ),
                ),
                if (searchQuery.value.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  _OnboardingIconButton(
                    onPress: searchController.clear,
                    child: const Icon(Icons.close_rounded, size: 16),
                  ),
                ],
              ],
            ),
          ),
          Container(height: 1, color: kDividerColor),
          Expanded(
            child:
                isLoading
                    ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: kPrimaryColor,
                        ),
                      ),
                    )
                    : playerState.hasError && players.isEmpty
                    ? _OnboardingError(
                      message:
                          'Could not load players. Check your connection and retry.',
                      onRetry:
                          () =>
                              ref
                                  .read(onboardingPlayerProvider.notifier)
                                  .initFirstPage(),
                    )
                    : visiblePlayers.isEmpty
                    ? _EmptyPlayersState(isSearching: isSearching)
                    : _PlayerList(
                      controller: scrollController,
                      players: visiblePlayers,
                      selectedIds: selectedIds,
                      onToggle:
                          (player) =>
                              _toggleDesktopOnboardingFavorite(ref, player),
                      hasMore:
                          ref.read(onboardingPlayerProvider.notifier).hasMore,
                      isFetching:
                          ref
                              .read(onboardingPlayerProvider.notifier)
                              .isFetching,
                    ),
          ),
          Container(height: 1, color: kDividerColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    canContinue
                        ? 'Good. These favorites will be saved to your account or guest session.'
                        : 'Pick ${kFreeFavoriteLimit - selectedCount} more to continue.',
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 180,
                  child: _OnboardingButton(
                    tone: _OnboardingButtonTone.primary,
                    onPress: canContinue ? () => unawaited(onComplete()) : null,
                    suffix: const Icon(Icons.arrow_forward_rounded, size: 16),
                    child: const Text('Continue'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectionCounter extends StatelessWidget {
  const _SelectionCounter({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final ready = count >= kFreeFavoriteLimit;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: ready ? kPrimaryColor.withValues(alpha: 0.12) : kBlack3Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: ready ? kPrimaryColor.withValues(alpha: 0.45) : kDividerColor,
        ),
      ),
      child: Text(
        '$count / $kFreeFavoriteLimit selected',
        style: TextStyle(
          color: ready ? kPrimaryColor : kWhiteColor70,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _PlayerList extends StatelessWidget {
  const _PlayerList({
    required this.controller,
    required this.players,
    required this.selectedIds,
    required this.onToggle,
    required this.hasMore,
    required this.isFetching,
  });

  final ScrollController controller;
  final List<Map<String, dynamic>> players;
  final Set<String> selectedIds;
  final ValueChanged<Map<String, dynamic>> onToggle;
  final bool hasMore;
  final bool isFetching;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      itemCount: players.length + (hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= players.length) {
          return AnimatedOpacity(
            opacity: isFetching ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: kLightGreyColor,
                  ),
                ),
              ),
            ),
          );
        }

        final player = players[index];
        final fideId = player['fideId']?.toString() ?? '';
        return _PlayerTile(
          key: ValueKey(fideId),
          player: player,
          isSelected: selectedIds.contains(fideId),
          onTap: () => onToggle(player),
        );
      },
    );
  }
}

class _PlayerTile extends StatefulWidget {
  const _PlayerTile({
    required this.player,
    required this.isSelected,
    required this.onTap,
    super.key,
  });

  final Map<String, dynamic> player;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_PlayerTile> createState() => _PlayerTileState();
}

class _PlayerTileState extends State<_PlayerTile> {
  String get _name {
    final title = (widget.player['title'] ?? '').toString().trim();
    final name = (widget.player['name'] ?? '').toString().trim();
    return [title, name].where((part) => part.isNotEmpty).join(' ');
  }

  String get _initials {
    final name = (widget.player['name'] ?? '').toString().trim();
    if (name.isEmpty) return '?';
    final commaParts = name.split(', ');
    if (commaParts.length >= 2 &&
        commaParts[0].isNotEmpty &&
        commaParts[1].isNotEmpty) {
      return '${commaParts[1][0]}${commaParts[0][0]}'.toUpperCase();
    }
    final words =
        name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length >= 2) return '${words[0][0]}${words[1][0]}'.toUpperCase();
    return name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final rating = widget.player['rating'] ?? 0;
    final countryCode = widget.player['fed']?.toString() ?? '';
    final fideId = widget.player['fideId']?.toString() ?? '';
    final flagEmoji = CountryUtils.toFlagEmoji(countryCode);
    final selected = widget.isSelected;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FTheme(
        data: FThemes.zinc.dark,
        child: FButton.raw(
          style: _playerTileButtonStyle(selected: selected),
          onPress: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                _PlayerAvatar(fideId: fideId, initials: _initials, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (flagEmoji.isNotEmpty) ...[
                            Text(
                              flagEmoji,
                              style: const TextStyle(fontSize: 14),
                            ),
                            const SizedBox(width: 7),
                          ],
                          Expanded(
                            child: Text(
                              _name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: kWhiteColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$rating · $countryCode',
                        style: const TextStyle(
                          color: kLightGreyColor,
                          fontSize: 11,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: selected ? kPrimaryColor : Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color:
                          selected
                              ? kPrimaryColor
                              : kWhiteColor.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Icon(
                    selected ? Icons.check_rounded : Icons.add_rounded,
                    size: selected ? 15 : 14,
                    color: selected ? kBackgroundColor : kWhiteColor70,
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

FBaseButtonStyle Function(FButtonStyle style) _playerTileButtonStyle({
  required bool selected,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.14) : kBlack3Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.62)
                    : kDividerColor.withValues(alpha: 0.90),
          ),
        ),
        WidgetState.any: BoxDecoration(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.10) : kBlack2Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.55)
                    : kDividerColor.withValues(alpha: 0.55),
          ),
        ),
      }),
    ),
  );
}

class _PlayerAvatar extends HookWidget {
  const _PlayerAvatar({
    required this.fideId,
    required this.initials,
    required this.size,
  });

  final String fideId;
  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    final photoUrl = useState<String?>(null);

    useEffect(() {
      photoUrl.value = null;
      if (fideId.isNotEmpty) {
        FidePhotoService.getPhotoUrlOrNull(fideId).then((url) {
          photoUrl.value = url;
        });
      }
      return null;
    }, [fideId]);

    return PlayerInitialsAvatarCompact(
      photoUrl: photoUrl.value,
      initials: initials,
      size: size,
      borderRadius: size / 2,
    );
  }
}

class _EmptyPlayersState extends StatelessWidget {
  const _EmptyPlayersState({required this.isSearching});

  final bool isSearching;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        isSearching ? 'No players found' : 'No player suggestions available.',
        style: const TextStyle(color: kWhiteColor70, fontSize: 13),
      ),
    );
  }
}

class _OnboardingError extends StatelessWidget {
  const _OnboardingError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: kRedColor, size: 28),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            const SizedBox(height: 14),
            _OnboardingButton(
              tone: _OnboardingButtonTone.secondary,
              onPress: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

RecommendedPlayersResult _recommendedPlayers(
  List<Map<String, dynamic>> players, {
  required String countryCode,
}) {
  if (players.isEmpty) {
    return RecommendedPlayersResult(players: [], hasCountryMatches: false);
  }

  final normalizedCode = countryCode.toUpperCase();
  final fromCountry =
      players
          .where(
            (player) =>
                (player['fed']?.toString().toUpperCase() ?? '') ==
                normalizedCode,
          )
          .toList()
        ..sort((a, b) => (b['rating'] ?? 0).compareTo(a['rating'] ?? 0));

  final others =
      players
          .where(
            (player) =>
                (player['fed']?.toString().toUpperCase() ?? '') !=
                normalizedCode,
          )
          .toList()
        ..sort((a, b) => (b['rating'] ?? 0).compareTo(a['rating'] ?? 0));

  final hasCountryMatches = fromCountry.isNotEmpty;
  return RecommendedPlayersResult(
    players: hasCountryMatches ? [...fromCountry, ...others] : others,
    hasCountryMatches: hasCountryMatches,
  );
}

class RecommendedPlayersResult {
  const RecommendedPlayersResult({
    required this.players,
    required this.hasCountryMatches,
  });

  final List<Map<String, dynamic>> players;
  final bool hasCountryMatches;
}

void _toggleDesktopOnboardingFavorite(
  WidgetRef ref,
  Map<String, dynamic> player,
) {
  final fideId = player['fideId']?.toString();
  if (fideId == null || fideId.isEmpty) return;

  final notifier = ref.read(_desktopOnboardingSelectedFideIdsProvider.notifier);
  final updated = Set<String>.from(notifier.state);
  final isAdding = !updated.contains(fideId);
  if (isAdding && updated.length >= kFreeFavoriteLimit) return;

  if (isAdding) {
    updated.add(fideId);
  } else {
    updated.remove(fideId);
  }
  notifier.state = updated;
  final isSelected = updated.contains(fideId);

  ref
      .read(pendingFavoriteSelectionsProvider.notifier)
      .setSelection(
        PendingFavoritePlayer(
          fideId: fideId,
          playerName: (player['name'] ?? '').toString().trim(),
          countryCode: player['fed']?.toString(),
          rating: player['rating'] as int?,
          title: player['title']?.toString(),
          isSelected: isSelected,
        ),
      );

  unawaited(
    ref.read(onboardingPlayerProvider.notifier).setFavorite(fideId, isSelected),
  );
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.isFirstStep,
    required this.completing,
    required this.onBack,
    required this.onNext,
  });

  final bool isFirstStep;
  final bool completing;
  final VoidCallback onBack;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (!isFirstStep)
          SizedBox(
            width: 120,
            child: _OnboardingButton(
              tone: _OnboardingButtonTone.secondary,
              onPress: completing ? null : onBack,
              prefix: const Icon(Icons.arrow_back_rounded, size: 16),
              child: const Text('Back'),
            ),
          )
        else
          const SizedBox(width: 120),
        const Spacer(),
        SizedBox(
          width: 120,
          child: _OnboardingButton(
            tone: _OnboardingButtonTone.primary,
            onPress: completing ? null : onNext,
            suffix: const Icon(Icons.arrow_forward_rounded, size: 16),
            child: const Text('Next'),
          ),
        ),
      ],
    );
  }
}

class _SubscribeStep extends StatelessWidget {
  const _SubscribeStep({
    required this.onSubscribed,
    required this.onSwitchAccount,
    required this.email,
    required this.switchingAccount,
    required this.error,
  });

  final Future<void> Function() onSubscribed;
  final Future<void> Function() onSwitchAccount;
  final String? email;
  final bool switchingAccount;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return _StepSurface(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Unlock ChessEver Desktop',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 26,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'A single subscription covers desktop, mobile, and web. '
              'Already subscribed on iPhone or Android? Tap '
              '“I already subscribed — refresh”.',
              style: TextStyle(
                color: kWhiteColor70,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 20),
            DesktopSubscriptionView(
              onSubscribed: () {
                unawaited(onSubscribed());
              },
            ),
            const SizedBox(height: 14),
            _SwitchAccountPanel(
              email: email,
              switching: switchingAccount,
              onSwitchAccount: onSwitchAccount,
            ),
            if (error != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: kRedColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kRedColor.withValues(alpha: 0.35)),
                ),
                child: Text(
                  error!,
                  style: const TextStyle(color: kRedColor, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SwitchAccountPanel extends StatelessWidget {
  const _SwitchAccountPanel({
    required this.email,
    required this.switching,
    required this.onSwitchAccount,
  });

  final String? email;
  final bool switching;
  final Future<void> Function() onSwitchAccount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_circle_rounded, color: kWhiteColor70),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              email == null
                  ? 'Signed in to this account'
                  : 'Signed in as $email',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kWhiteColor70, fontSize: 12),
            ),
          ),
          const SizedBox(width: 12),
          _OnboardingButton(
            tone: _OnboardingButtonTone.ghost,
            onPress:
                switching
                    ? null
                    : () {
                      unawaited(onSwitchAccount());
                    },
            prefix: const Icon(Icons.logout_rounded, size: 16),
            child: Text(switching ? 'Signing out...' : 'Use another account'),
          ),
        ],
      ),
    );
  }
}

class _AccountStep extends StatelessWidget {
  const _AccountStep({
    required this.isFullyAuthenticated,
    required this.email,
    required this.busy,
    required this.error,
    required this.onContinue,
    required this.onGoogle,
    required this.onApple,
  });

  final bool isFullyAuthenticated;
  final String? email;
  final bool busy;
  final String? error;
  final VoidCallback onContinue;
  final VoidCallback onGoogle;
  final VoidCallback onApple;

  String get _displayName {
    final value = email;
    if (value == null || !value.contains('@')) return 'Chess Player';
    return value.split('@').first;
  }

  @override
  Widget build(BuildContext context) {
    final title =
        isFullyAuthenticated
            ? 'Welcome back, $_displayName'
            : 'Sign in to continue';
    final subtitle =
        isFullyAuthenticated
            ? 'Your country and player picks will sync with this account. Next step: subscribe to unlock ChessEver Desktop.'
            : 'Create an account or sign in to an existing one. ChessEver Desktop is a premium app — your subscription works across desktop, mobile, and web.';

    return _StepSurface(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: kPrimaryColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: kPrimaryColor.withValues(alpha: 0.30),
                      ),
                    ),
                    child: Icon(
                      isFullyAuthenticated
                          ? Icons.verified_user_rounded
                          : Icons.lock_open_rounded,
                      color: kPrimaryColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const _FeatureGrid(),
              if (error != null) ...[
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: kRedColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: kRedColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    error!,
                    style: const TextStyle(color: kRedColor, fontSize: 12),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              if (isFullyAuthenticated)
                Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 240,
                    child: _OnboardingButton(
                      tone: _OnboardingButtonTone.primary,
                      onPress: busy ? null : onContinue,
                      suffix: const Icon(Icons.arrow_forward_rounded, size: 16),
                      child: Text(busy ? 'Working…' : 'Continue to subscribe'),
                    ),
                  ),
                )
              else
                _AccountActions(
                  busy: busy,
                  onGoogle: onGoogle,
                  onApple: onApple,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountActions extends StatelessWidget {
  const _AccountActions({
    required this.busy,
    required this.onGoogle,
    required this.onApple,
  });

  final bool busy;
  final VoidCallback onGoogle;
  final VoidCallback onApple;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _OnboardingButton(
          tone: _OnboardingButtonTone.primary,
          onPress: busy ? null : onGoogle,
          prefix: const _SocialIconBadge(
            child: DesktopIcon(SvgAsset.googleIcon, size: 15),
          ),
          child: Text(busy ? 'Opening browser…' : 'Continue with Google'),
        ),
        const SizedBox(height: 12),
        _OnboardingButton(
          tone: _OnboardingButtonTone.secondary,
          onPress: busy ? null : onApple,
          prefix: const _SocialIconBadge(
            child: DesktopIcon(
              SvgAsset.appleIcon,
              size: 15,
              color: kWhiteColor,
            ),
          ),
          child: Text(busy ? 'Opening Apple…' : 'Continue with Apple'),
        ),
        const SizedBox(height: 10),
        const Text(
          'A single ChessEver subscription covers desktop, mobile, and web. '
          'If you already subscribed on iPhone or Android, sign in with the '
          'same account to restore your membership.',
          textAlign: TextAlign.right,
          style: TextStyle(color: kLightGreyColor, fontSize: 11, height: 1.35),
        ),
      ],
    );
  }
}

enum _OnboardingButtonTone { primary, secondary, ghost }

class _OnboardingButton extends StatefulWidget {
  const _OnboardingButton({
    required this.tone,
    required this.onPress,
    required this.child,
    this.prefix,
    this.suffix,
  });

  final _OnboardingButtonTone tone;
  final VoidCallback? onPress;
  final Widget child;
  final Widget? prefix;
  final Widget? suffix;

  @override
  State<_OnboardingButton> createState() => _OnboardingButtonState();
}

class _OnboardingButtonState extends State<_OnboardingButton> {
  bool _hovered = false;
  bool _pressed = false;

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() {
      _hovered = hovered;
      if (!hovered) _pressed = false;
    });
  }

  void _setStates(FWidgetStatesDelta delta) {
    final pressed = delta.current.contains(WidgetState.pressed);
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPress == null;
    final motionValue =
        disabled ? 0.0 : (_pressed ? -1.0 : (_hovered ? 1.0 : 0.0));

    return SingleMotionBuilder(
      value: motionValue,
      motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
      builder: (context, value, child) {
        final scale = value < 0 ? 1 + (value * 0.035) : 1 + (value * 0.012);
        final dy = -value;

        return Transform.translate(
          offset: Offset(0, dy),
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.center,
            child: child,
          ),
        );
      },
      child: FButton(
        style: _onboardingButtonStyle(widget.tone),
        onPress: widget.onPress,
        onHoverChange: disabled ? null : _setHovered,
        onStateChange: disabled ? null : _setStates,
        prefix: widget.prefix,
        suffix: widget.suffix,
        child: widget.child,
      ),
    );
  }
}

class _OnboardingIconButton extends StatefulWidget {
  const _OnboardingIconButton({required this.onPress, required this.child});

  final VoidCallback? onPress;
  final Widget child;

  @override
  State<_OnboardingIconButton> createState() => _OnboardingIconButtonState();
}

class _OnboardingIconButtonState extends State<_OnboardingIconButton> {
  bool _hovered = false;
  bool _pressed = false;

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() {
      _hovered = hovered;
      if (!hovered) _pressed = false;
    });
  }

  void _setStates(FWidgetStatesDelta delta) {
    final pressed = delta.current.contains(WidgetState.pressed);
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPress == null;
    final scale = disabled ? 1.0 : (_pressed ? 0.94 : (_hovered ? 1.04 : 1.0));

    return SingleMotionBuilder(
      value: scale,
      motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
      builder:
          (context, value, child) => Transform.scale(
            scale: value,
            alignment: Alignment.center,
            child: child,
          ),
      child: FButton.icon(
        style: _onboardingIconButtonStyle(),
        onPress: widget.onPress,
        onHoverChange: disabled ? null : _setHovered,
        onStateChange: disabled ? null : _setStates,
        child: widget.child,
      ),
    );
  }
}

class _SocialIconBadge extends StatelessWidget {
  const _SocialIconBadge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kBackgroundColor.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: kWhiteColor.withValues(alpha: 0.12)),
      ),
      child: child,
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _onboardingButtonStyle(
  _OnboardingButtonTone tone,
) {
  final base = switch (tone) {
    _OnboardingButtonTone.primary => FButtonStyle.primary,
    _OnboardingButtonTone.secondary => FButtonStyle.outline,
    _OnboardingButtonTone.ghost => FButtonStyle.ghost,
  };

  return base(
    (style) => style.copyWith(
      decoration: _onboardingButtonDecoration(tone),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            spacing: 8,
            textStyle: _onboardingButtonTextStyle(tone),
            iconStyle: _onboardingButtonIconStyle(tone),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _onboardingIconButtonStyle() {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: _onboardingButtonDecoration(_OnboardingButtonTone.ghost),
      iconContentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.all(8),
            iconStyle: _onboardingIconOnlyStyle(),
          ),
    ),
  );
}

FWidgetStateMap<BoxDecoration> _onboardingButtonDecoration(
  _OnboardingButtonTone tone,
) {
  final primary = tone == _OnboardingButtonTone.primary;
  final ghost = tone == _OnboardingButtonTone.ghost;

  return FWidgetStateMap({
    WidgetState.disabled: BoxDecoration(
      color:
          primary
              ? kPrimaryColor.withValues(alpha: 0.24)
              : kBlack2Color.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color:
            primary
                ? kPrimaryColor.withValues(alpha: 0.18)
                : kDividerColor.withValues(alpha: 0.48),
      ),
    ),
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color:
          primary
              ? const Color(0xFF22C4F4)
              : (ghost ? kBlack3Color.withValues(alpha: 0.74) : kBlack3Color),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color:
            primary
                ? kLightYellowColor.withValues(alpha: 0.58)
                : kPrimaryColor.withValues(alpha: ghost ? 0.26 : 0.44),
      ),
      boxShadow: [
        BoxShadow(
          color:
              primary
                  ? kPrimaryColor.withValues(alpha: 0.22)
                  : Colors.black.withValues(alpha: 0.25),
          blurRadius: primary ? 18 : 14,
          offset: const Offset(0, 5),
        ),
      ],
    ),
    WidgetState.any: BoxDecoration(
      color:
          primary ? kPrimaryColor : (ghost ? Colors.transparent : kBlack2Color),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color:
            primary
                ? kPrimaryColor.withValues(alpha: 0.65)
                : (ghost
                    ? kWhiteColor.withValues(alpha: 0.08)
                    : kDividerColor.withValues(alpha: 0.86)),
      ),
      boxShadow: [
        BoxShadow(
          color:
              primary
                  ? kPrimaryColor.withValues(alpha: 0.12)
                  : Colors.black.withValues(alpha: ghost ? 0 : 0.16),
          blurRadius: primary ? 12 : 10,
          offset: const Offset(0, 3),
        ),
      ],
    ),
  });
}

FWidgetStateMap<TextStyle> _onboardingButtonTextStyle(
  _OnboardingButtonTone tone,
) {
  final primary = tone == _OnboardingButtonTone.primary;
  return FWidgetStateMap({
    WidgetState.disabled: TextStyle(
      color:
          primary
              ? kBackgroundColor.withValues(alpha: 0.48)
              : kWhiteColor.withValues(alpha: 0.34),
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
    WidgetState.hovered | WidgetState.pressed: TextStyle(
      color: primary ? kBackgroundColor : kWhiteColor,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
    WidgetState.any: TextStyle(
      color:
          primary
              ? kBackgroundColor
              : (tone == _OnboardingButtonTone.ghost
                  ? kWhiteColor70
                  : kWhiteColor),
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
  });
}

FWidgetStateMap<IconThemeData> _onboardingButtonIconStyle(
  _OnboardingButtonTone tone,
) {
  final primary = tone == _OnboardingButtonTone.primary;
  return FWidgetStateMap({
    WidgetState.disabled: IconThemeData(
      color:
          primary
              ? kBackgroundColor.withValues(alpha: 0.48)
              : kWhiteColor.withValues(alpha: 0.34),
      size: 16,
    ),
    WidgetState.hovered | WidgetState.pressed: IconThemeData(
      color: primary ? kBackgroundColor : kPrimaryColor,
      size: 16,
    ),
    WidgetState.any: IconThemeData(
      color:
          primary
              ? kBackgroundColor
              : (tone == _OnboardingButtonTone.ghost
                  ? kWhiteColor70
                  : kPrimaryColor),
      size: 16,
    ),
  });
}

FWidgetStateMap<IconThemeData> _onboardingIconOnlyStyle() {
  return FWidgetStateMap({
    WidgetState.disabled: IconThemeData(
      color: kWhiteColor.withValues(alpha: 0.34),
      size: 16,
    ),
    WidgetState.hovered | WidgetState.pressed: const IconThemeData(
      color: kPrimaryColor,
      size: 16,
    ),
    WidgetState.any: const IconThemeData(color: kWhiteColor70, size: 16),
  });
}

class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid();

  @override
  Widget build(BuildContext context) {
    const features = [
      _AccountFeature(
        icon: Icons.favorite_rounded,
        title: 'Save favorites',
        subtitle: 'Players, games, events',
      ),
      _AccountFeature(
        icon: Icons.psychology_rounded,
        title: 'Analysis vault',
        subtitle: 'Keep desktop work',
      ),
      _AccountFeature(
        icon: Icons.cloud_sync_rounded,
        title: 'Sync devices',
        subtitle: 'Mobile and desktop',
      ),
      _AccountFeature(
        icon: Icons.palette_rounded,
        title: 'Personal setup',
        subtitle: 'Country and themes',
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 620 ? 2 : 1;
        final width =
            columns == 2
                ? (constraints.maxWidth - 10) / 2
                : constraints.maxWidth;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final feature in features)
              SizedBox(width: width, child: feature),
          ],
        );
      },
    );
  }
}

class _AccountFeature extends StatelessWidget {
  const _AccountFeature({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor.withValues(alpha: 0.75)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: kBlack3Color,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: kPrimaryColor, size: 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 11,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepSurface extends StatelessWidget {
  const _StepSurface({
    required this.child,
    this.padding = const EdgeInsets.all(24),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: kBlackColor.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: child,
    );
  }
}
