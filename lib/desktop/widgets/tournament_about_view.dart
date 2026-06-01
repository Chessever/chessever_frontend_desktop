import 'package:cached_network_image/cached_network_image.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/tournament_detail_pane.dart'
    show tournamentDetailAboutScrollByTabIdProvider;
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/screens/group_event/model/about_tour_model.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/location_service_provider.dart';
import 'package:chessever/utils/url_launcher_provider.dart';
import 'package:chessever/widgets/logo_pattern_fallback.dart';

final desktopTournamentAboutModelProvider =
    Provider<AsyncValue<AboutTourModel?>>((ref) {
      final detail = ref.watch(tourDetailScreenProvider);
      return detail.whenData((data) {
        final about = data.aboutTourModel;
        return about.id.isEmpty ? null : about;
      });
    });

/// Desktop About sub-view for the focused event.
///
/// Uses the same mobile-shared [tourDetailScreenProvider] as the Games and
/// Standings tabs so category switches surface the selected tour's real image,
/// roster, time control, dates, location, and official links.
class TournamentAboutView extends ConsumerWidget {
  const TournamentAboutView({
    super.key,
    required this.tabId,
    required this.tournamentId,
  });

  final String tabId;
  final String tournamentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tournament = ref.watch(activeTournamentProvider);
    if (tournament == null || tournament.id != tournamentId) {
      return const _LoadingAbout();
    }

    final detail = ref.watch(desktopTournamentAboutModelProvider);
    final locationService = ref.read(locationServiceProvider);
    final urlLauncher = ref.read(urlLauncherProvider);

    return detail.when(
      data: (aboutModel) {
        final about =
            aboutModel == null
                ? _EventAboutData.fromEvent(tournament, locationService)
                : _EventAboutData.fromAbout(aboutModel, locationService);
        return _AboutContent(
          tabId: tabId,
          about: about,
          urlLauncher: urlLauncher,
        );
      },
      loading:
          () => _AboutContent(
            tabId: tabId,
            about: _EventAboutData.fromEvent(tournament, locationService),
            urlLauncher: urlLauncher,
            loading: true,
          ),
      error:
          (_, __) => _AboutContent(
            tabId: tabId,
            about: _EventAboutData.fromEvent(tournament, locationService),
            urlLauncher: urlLauncher,
          ),
    );
  }
}

class _EventAboutData {
  const _EventAboutData({
    required this.title,
    required this.description,
    required this.imageUrl,
    required this.players,
    required this.timeControl,
    required this.date,
    required this.locationTitle,
    required this.locationDescription,
    required this.countryCode,
    required this.isOnlineLocation,
    required this.websiteUrl,
    required this.websiteDomain,
    required this.standingsUrl,
    required this.tourUrl,
  });

  final String title;
  final String description;
  final String imageUrl;
  final List<String> players;
  final String timeControl;
  final String date;
  final String locationTitle;
  final String locationDescription;
  final String countryCode;
  final bool isOnlineLocation;
  final String websiteUrl;
  final String websiteDomain;
  final String standingsUrl;
  final String tourUrl;

  factory _EventAboutData.fromAbout(
    AboutTourModel about,
    LocationService locationService,
  ) {
    final ratedPlayers =
        about.players.where((p) => p.rating != null).toList()
          ..sort((a, b) => b.rating!.compareTo(a.rating!));
    final location = _LocationDisplay.from(about.location, locationService);

    return _EventAboutData(
      title: about.name,
      description: about.description.trim(),
      imageUrl: about.imageUrl.trim(),
      players: ratedPlayers.take(4).map((p) => p.displayName).toList(),
      timeControl: about.timeControl.trim(),
      date: about.date.trim(),
      locationTitle: location.title,
      locationDescription: location.description,
      countryCode: location.countryCode,
      isOnlineLocation: location.isOnline,
      websiteUrl: about.websiteUrl.trim(),
      websiteDomain: about.extractDomain(),
      standingsUrl: about.standingsUrl.trim(),
      tourUrl: about.tourUrl.trim(),
    );
  }

  factory _EventAboutData.fromEvent(
    GroupEventCardModel event,
    LocationService locationService,
  ) {
    final location = _LocationDisplay.from(
      event.location ?? '',
      locationService,
    );
    return _EventAboutData(
      title: event.title,
      description: '',
      imageUrl: '',
      players: const <String>[],
      timeControl: event.timeControl.trim(),
      date: event.dates.trim(),
      locationTitle: location.title,
      locationDescription: location.description,
      countryCode: location.countryCode,
      isOnlineLocation: location.isOnline,
      websiteUrl: '',
      websiteDomain: '',
      standingsUrl: '',
      tourUrl: '',
    );
  }

  bool get hasImage => imageUrl.isNotEmpty;
  bool get hasDescription => description.isNotEmpty;
  bool get hasPlayers => players.isNotEmpty;
  bool get hasTimeControl => timeControl.isNotEmpty;
  bool get hasDate => date.isNotEmpty;
  bool get hasLocation => locationDescription.isNotEmpty;
  bool get hasWebsite => websiteUrl.isNotEmpty;
  bool get hasStandings => standingsUrl.isNotEmpty;
  bool get hasTourUrl => tourUrl.isNotEmpty;
}

class _LocationDisplay {
  const _LocationDisplay({
    required this.title,
    required this.description,
    required this.countryCode,
    required this.isOnline,
  });

  final String title;
  final String description;
  final String countryCode;
  final bool isOnline;

  factory _LocationDisplay.from(
    String rawLocation,
    LocationService locationService,
  ) {
    final location = rawLocation.trim();
    if (location.isEmpty) {
      return const _LocationDisplay(
        title: 'Location',
        description: '',
        countryCode: '',
        isOnline: false,
      );
    }

    final isOnline = locationService.isOnlinePlatform(location);
    if (isOnline) {
      return _LocationDisplay(
        title: 'Online',
        description: locationService.prettifyPlatformName(location),
        countryCode: '',
        isOnline: true,
      );
    }

    return _LocationDisplay(
      title: 'Location',
      description: location,
      countryCode: locationService.getCountryCode(location),
      isOnline: false,
    );
  }
}

class _AboutContent extends ConsumerStatefulWidget {
  const _AboutContent({
    required this.tabId,
    required this.about,
    required this.urlLauncher,
    this.loading = false,
  });

  final String tabId;
  final _EventAboutData about;
  final UrlLauncherService urlLauncher;
  final bool loading;

  @override
  ConsumerState<_AboutContent> createState() => _AboutContentState();
}

class _AboutContentState extends ConsumerState<_AboutContent> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    final initial = ref.read(
      tournamentDetailAboutScrollByTabIdProvider(widget.tabId),
    );
    _controller = ScrollController(initialScrollOffset: initial);
    _controller.addListener(_persistOffset);
  }

  void _persistOffset() {
    if (!_controller.hasClients) return;
    final offset = _controller.offset;
    final current = ref.read(
      tournamentDetailAboutScrollByTabIdProvider(widget.tabId),
    );
    if ((current - offset).abs() < 0.5) return;
    ref
        .read(
          tournamentDetailAboutScrollByTabIdProvider(widget.tabId).notifier,
        )
        .state = offset;
  }

  @override
  void dispose() {
    _controller.removeListener(_persistOffset);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final about = widget.about;
    return SingleChildScrollView(
      controller: _controller,
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 940),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HeroImage(about: about, loading: widget.loading),
              const SizedBox(height: 22),
              if (about.hasDescription) ...[
                Text(
                  about.description,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 14,
                    height: 1.55,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 20),
              ],
              _DetailsPanel(about: about),
              if (about.hasTourUrl || about.hasWebsite || about.hasStandings)
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: _EventLinks(
                    about: about,
                    urlLauncher: widget.urlLauncher,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroImage extends StatelessWidget {
  const _HeroImage({required this.about, required this.loading});

  final _EventAboutData about;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 3.1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: kBlack2Color,
            border: Border.all(color: kDividerColor),
          ),
          child:
              loading
                  ? const _HeroFallback()
                  : (about.hasImage
                      ? CachedNetworkImage(
                        imageUrl: about.imageUrl,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        fadeInDuration: const Duration(milliseconds: 220),
                        fadeOutDuration: const Duration(milliseconds: 120),
                        placeholder: (_, __) => const _HeroFallback(),
                        errorWidget: (_, __, ___) => const _HeroFallback(),
                      )
                      : const _HeroFallback()),
        ),
      ),
    );
  }
}

class _HeroFallback extends StatelessWidget {
  const _HeroFallback();

  @override
  Widget build(BuildContext context) {
    return const LogoPatternFallback(
      logoSize: 42,
      opacity: 0.7,
      borderRadius: BorderRadius.all(Radius.circular(8)),
    );
  }
}

class _DetailsPanel extends StatelessWidget {
  const _DetailsPanel({required this.about});

  final _EventAboutData about;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      if (about.hasPlayers)
        _DetailRow(title: 'Players', description: about.players.join(', ')),
      if (about.hasTimeControl)
        _DetailRow(title: 'Time Control', description: about.timeControl),
      if (about.hasDate) _DetailRow(title: 'Date', description: about.date),
      if (about.hasLocation)
        _DetailRow(
          title: about.locationTitle,
          description: about.locationDescription,
          leading:
              about.isOnlineLocation
                  ? const Icon(
                    Icons.language_rounded,
                    size: 15,
                    color: kLightGreyColor,
                  )
                  : (about.countryCode.isEmpty
                      ? null
                      : CountryFlag.fromCountryCode(
                        about.countryCode,
                        theme: const ImageTheme(width: 18, height: 13),
                      )),
        ),
    ];

    if (rows.isEmpty) {
      return _DetailRow(title: 'Event', description: about.title);
    }

    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: kDividerColor),
          bottom: BorderSide(color: kDividerColor),
        ),
      ),
      child: Column(children: rows),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.title,
    required this.description,
    this.leading,
  });

  final String title;
  final String description;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 124,
            child: Text(
              title,
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 8)],
                Expanded(
                  child: Text(
                    description,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      height: 1.45,
                      fontWeight: FontWeight.w500,
                    ),
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

class _EventLinks extends StatelessWidget {
  const _EventLinks({required this.about, required this.urlLauncher});

  final _EventAboutData about;
  final UrlLauncherService urlLauncher;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      runSpacing: 10,
      spacing: 22,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (about.hasTourUrl)
          _InlineLinkRow(
            prefix: 'Powered by:',
            label: 'Lichess',
            onTap: () => urlLauncher.launchCustomUrl(about.tourUrl),
          ),
        if (about.hasWebsite)
          _InlineLink(
            label:
                about.websiteDomain.isEmpty
                    ? 'Official website'
                    : about.websiteDomain,
            semanticsLabel: 'Open official website',
            onTap: () => urlLauncher.launchCustomUrl(about.websiteUrl),
          ),
        if (about.hasStandings)
          _InlineLink(
            label: 'Official Standings',
            semanticsLabel: 'Open official standings',
            onTap: () => urlLauncher.launchCustomUrl(about.standingsUrl),
          ),
      ],
    );
  }
}

class _InlineLinkRow extends StatelessWidget {
  const _InlineLinkRow({
    required this.prefix,
    required this.label,
    required this.onTap,
  });

  final String prefix;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '$prefix ',
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        _InlineLink(label: label, onTap: onTap),
      ],
    );
  }
}

class _InlineLink extends StatefulWidget {
  const _InlineLink({
    required this.label,
    required this.onTap,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback onTap;
  final String? semanticsLabel;

  @override
  State<_InlineLink> createState() => _InlineLinkState();
}

class _InlineLinkState extends State<_InlineLink> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _focused || _pressed;
    final color =
        _pressed ? kPrimaryColor.withValues(alpha: 0.78) : kPrimaryColor;

    return Semantics(
      button: true,
      link: true,
      label: widget.semanticsLabel ?? widget.label,
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: ClickCursor(
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit:
                (_) => setState(() {
                  _hovered = false;
                  _pressed = false;
                }),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      decoration:
                          active
                              ? TextDecoration.underline
                              : TextDecoration.none,
                      decorationColor: kPrimaryColor,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.open_in_new_rounded, size: 13, color: color),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingAbout extends StatelessWidget {
  const _LoadingAbout();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
        ),
      ),
    );
  }
}
