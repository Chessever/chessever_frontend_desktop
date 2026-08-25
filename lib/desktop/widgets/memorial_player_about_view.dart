import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/repository/gamebase/memorial_player_about.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/theme/app_theme.dart';

class MemorialPlayerAboutView extends ConsumerWidget {
  const MemorialPlayerAboutView({
    super.key,
    required this.sourceIdentity,
    required this.playerName,
  });

  final String sourceIdentity;
  final String playerName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(memorialPlayerOverviewProvider(sourceIdentity));
    return overview.when(
      data:
          (data) =>
              data == null
                  ? const _MemorialAboutStatus(
                    message: 'Historical profile details are unavailable.',
                  )
                  : _MemorialAboutContent(
                    overview: data,
                    fallbackName: playerName,
                  ),
      loading:
          () => const _MemorialAboutStatus(
            message: 'Loading historical profile…',
            loading: true,
          ),
      error:
          (_, _) => const _MemorialAboutStatus(
            message: 'Historical profile details are unavailable.',
          ),
    );
  }
}

class _MemorialAboutContent extends StatelessWidget {
  const _MemorialAboutContent({
    required this.overview,
    required this.fallbackName,
  });

  final MemorialPlayerOverview overview;
  final String fallbackName;

  @override
  Widget build(BuildContext context) {
    final player = overview.player;
    final about = overview.about;
    final name = _naturalName(player.name.isEmpty ? fallbackName : player.name);
    final summary =
        about?.summary.isNotEmpty == true
            ? about!.summary
            : <String>[
              _fallbackSummary(
                name: name,
                title: player.title,
                federation: player.fed,
                birthDate: player.birthDate,
                deathDate: player.deathDate,
              ),
            ];
    final highlights = (about?.achievements ?? const [])
        .where((item) => !_isPeakRatingAchievement(item.label))
        .toList(growable: false);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Container(
            padding: const EdgeInsets.fromLTRB(28, 26, 28, 30),
            decoration: BoxDecoration(
              color: kBlack2Color,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Life & career',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: kWhiteColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 22),
                Wrap(
                  spacing: 48,
                  runSpacing: 18,
                  children: [
                    _LifeFact(
                      label: 'Born',
                      value: formatMemorialProfileDate(player.birthDate),
                      detail: about?.birthPlace,
                    ),
                    _LifeFact(
                      label: 'Died',
                      value: formatMemorialProfileDate(player.deathDate),
                      detail: about?.deathPlace,
                    ),
                    if (player.ratingClassical > 0)
                      _LifeFact(
                        label: 'Peak classical',
                        value: player.ratingClassical.toString(),
                      ),
                  ],
                ),
                const SizedBox(height: 30),
                for (var index = 0; index < summary.length; index++) ...[
                  Text(
                    summary[index],
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 15,
                      height: 1.65,
                    ),
                  ),
                  if (index != summary.length - 1) const SizedBox(height: 12),
                ],
                if (highlights.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  const Text(
                    'Career highlights',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 15),
                  for (final highlight in highlights)
                    _CareerHighlight(highlight: highlight),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LifeFact extends StatelessWidget {
  const _LifeFact({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (detail?.isNotEmpty == true) ...[
            const SizedBox(height: 4),
            Text(
              detail!,
              style: const TextStyle(
                color: kSecondaryTextColor,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CareerHighlight extends StatelessWidget {
  const _CareerHighlight({required this.highlight});

  final MemorialPlayerAchievement highlight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              highlight.year,
              style: const TextStyle(
                color: kPrimaryColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Text(
              highlight.label,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemorialAboutStatus extends StatelessWidget {
  const _MemorialAboutStatus({required this.message, this.loading = false});

  final String message;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 10),
          ],
          Text(message, style: const TextStyle(color: kSecondaryTextColor)),
        ],
      ),
    );
  }
}

String formatMemorialProfileDate(String? value) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return 'Unknown';
  final match = RegExp(r'^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$').firstMatch(raw);
  if (match == null) return raw;
  final year = int.tryParse(match.group(1) ?? '');
  final month = int.tryParse(match.group(2) ?? '');
  final day = int.tryParse(match.group(3) ?? '');
  if (year == null) return raw;
  if (month == null) return year.toString();
  const months = <String>[
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
  if (month < 1 || month > 12) return raw;
  if (day == null) return '${months[month - 1]} $year';
  return '${months[month - 1]} $day, $year';
}

String _naturalName(String value) {
  final parts = value.split(',');
  if (parts.length < 2) return value.trim();
  return '${parts.skip(1).join(' ').trim()} ${parts.first.trim()}'.trim();
}

String _fallbackSummary({
  required String name,
  required String? title,
  required String federation,
  required String? birthDate,
  required String? deathDate,
}) {
  final titleText = title?.trim().isNotEmpty == true ? ' ${title!.trim()}' : '';
  final federationText =
      federation.trim().isEmpty ? '' : ' who represented ${federation.trim()}';
  return '$name was a$titleText chess player$federationText. ChessEver’s reviewed historical record lists ${formatMemorialProfileDate(birthDate)} – ${formatMemorialProfileDate(deathDate)}.';
}

bool _isPeakRatingAchievement(String label) {
  return RegExp(
    r'^(?:Peak\b.*\brating\b|Reached a peak\b.*\brating\b)',
    caseSensitive: false,
  ).hasMatch(label);
}
