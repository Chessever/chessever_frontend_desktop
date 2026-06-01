import 'dart:math';

import 'package:faker/faker.dart' as fk;
import 'package:flutter/foundation.dart';

/// A generated bot persona — surfaces in the active-game header, tournament
/// pairings, and the player list. Deterministic by seed so re-rolling the
/// same seed in a replay produces the same persona.
///
/// IMPORTANT: names are drawn from the [`faker`](https://pub.dev/packages/faker)
/// package and are intentionally **not** sourced from any real chess player.
/// We never want a real human to see themselves "represented" by a bot.
@immutable
class BotIdentity {
  const BotIdentity({
    required this.firstName,
    required this.lastName,
    required this.countryCode,
    required this.elo,
    this.title,
    this.nickname,
  });

  final String firstName;
  final String lastName;

  /// ISO-3166-1 alpha-2 country code (uppercase). Matches the format the
  /// `country_flags` package expects. The country is picked **independently**
  /// of the generated name so we can't accidentally reconstruct a real
  /// player's identity by combining a name with a federation.
  final String countryCode;

  /// Display-only ELO — the *target* the engine is throttled to, not its
  /// actual rating after the game. Stored on the identity so the same bot
  /// can play multiple games at the same rating without reroll churn.
  final int elo;

  /// Optional chess title shown the same way live tournament views do:
  /// a compact prefix next to the player name.
  final String? title;

  /// Human-ish online/event handle. It is display-only, deterministic by
  /// generator seed, and intentionally separate from the formal player name.
  final String? nickname;

  String get fullName => '$firstName $lastName';

  String get displayName => [
    title,
    fullName,
  ].where((part) => part != null && part.isNotEmpty).join(' ');

  String get profileLine =>
      nickname == null || nickname!.isEmpty ? countryCode : '@$nickname';

  BotIdentity copyWith({
    String? firstName,
    String? lastName,
    String? countryCode,
    int? elo,
    String? title,
    String? nickname,
  }) {
    return BotIdentity(
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      countryCode: countryCode ?? this.countryCode,
      elo: elo ?? this.elo,
      title: title ?? this.title,
      nickname: nickname ?? this.nickname,
    );
  }
}

/// Generates plausible-but-fictional bot personas. Names come from the
/// `faker` package; the country code is sampled from a fixed weighted list
/// (roughly mirroring FIDE-active federation sizes) so flags look plausible
/// without tying a name to any specific federation. The pools used by faker
/// are large and generic — see https://pub.dev/packages/faker — so the
/// chance of accidentally minting a real top-player name is effectively
/// zero, and the country pick is independent of the name draw.
class BotIdentityGenerator {
  /// Builds a generator with [seed]. Same seed → same sequence of identities.
  /// Both the country picker and the underlying faker share the seed.
  BotIdentityGenerator({int? seed})
      : _rng = Random(seed),
        _faker = fk.Faker(seed: seed);

  final Random _rng;
  final fk.Faker _faker;

  BotIdentity next({required int elo}) {
    final first = _faker.person.firstName();
    final last = _faker.person.lastName();
    final countryCode = _weightedCountryCodes[
      _rng.nextInt(_weightedCountryCodes.length)
    ];
    return BotIdentity(
      firstName: first,
      lastName: last,
      countryCode: countryCode,
      elo: elo,
      title: _titleForElo(elo),
      nickname: _nickname(first: first, last: last, elo: elo),
    );
  }

  /// Generate [count] unique identities. Uniqueness is checked on
  /// `displayName`; if the pools are exhausted (very unlikely at reasonable
  /// [count]) the loop falls back to allowing duplicates rather than
  /// spinning forever.
  List<BotIdentity> batch({
    required int count,
    required int elo,
    int? eloJitter,
  }) {
    final seen = <String>{};
    final out = <BotIdentity>[];
    var attempts = 0;
    while (out.length < count && attempts < count * 12) {
      final jittered =
          eloJitter == null || eloJitter == 0
              ? elo
              : elo + _rng.nextInt(eloJitter * 2 + 1) - eloJitter;
      final id = next(elo: jittered);
      final key = id.displayName;
      if (seen.add(key)) {
        out.add(id);
      }
      attempts++;
    }
    while (out.length < count) {
      out.add(next(elo: elo));
    }
    return out;
  }

  String? _titleForElo(int elo) {
    final roll = _rng.nextInt(100);
    if (elo >= 2550) {
      return roll < 72 ? 'GM' : (roll < 90 ? 'IM' : 'WGM');
    }
    if (elo >= 2400) {
      return roll < 34 ? 'GM' : (roll < 78 ? 'IM' : 'FM');
    }
    if (elo >= 2200) {
      return roll < 38 ? 'IM' : (roll < 82 ? 'FM' : 'CM');
    }
    if (elo >= 2000) {
      return roll < 22 ? 'FM' : (roll < 52 ? 'CM' : null);
    }
    if (elo >= 1800) {
      return roll < 10 ? 'CM' : null;
    }
    return null;
  }

  String _nickname({
    required String first,
    required String last,
    required int elo,
  }) {
    final adjective = _handleAdjectives[_rng.nextInt(_handleAdjectives.length)];
    final noun = _handleNouns[_rng.nextInt(_handleNouns.length)];
    final style = _rng.nextInt(4);
    final suffix = (elo + _rng.nextInt(97)).toString();
    final safeLast = _asciiHandle(last);
    final safeFirst = _asciiHandle(first);
    return switch (style) {
      0 => '$adjective$noun',
      1 => '$safeLast$noun',
      2 => '$safeFirst$suffix',
      _ => '$noun$suffix',
    };
  }
}

const List<String> _handleAdjectives = [
  'Quiet',
  'Sharp',
  'Rapid',
  'Golden',
  'Hidden',
  'Patient',
  'Tactical',
  'Velvet',
  'Iron',
  'Silent',
  'Brave',
  'Deep',
];

const List<String> _handleNouns = [
  'Knight',
  'File',
  'Tempo',
  'Rook',
  'Bishop',
  'Endgame',
  'Gambit',
  'Castle',
  'Rank',
  'Fork',
  'Zugzwang',
  'King',
];

String _asciiHandle(String value) {
  return value
      .replaceAll('ı', 'i')
      .replaceAll('İ', 'I')
      .replaceAll('ğ', 'g')
      .replaceAll('Ğ', 'G')
      .replaceAll('ü', 'u')
      .replaceAll('Ü', 'U')
      .replaceAll('ş', 's')
      .replaceAll('Ş', 'S')
      .replaceAll('ö', 'o')
      .replaceAll('Ö', 'O')
      .replaceAll('ç', 'c')
      .replaceAll('Ç', 'C')
      .replaceAll('é', 'e')
      .replaceAll('É', 'E')
      .replaceAll('è', 'e')
      .replaceAll('á', 'a')
      .replaceAll('Á', 'A')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u')
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '');
}

/// Weighted ISO-3166-1 alpha-2 country codes for bot federations. The
/// weights roughly mirror FIDE-active federation sizes so the flag
/// distribution looks plausible. **No connection to the name draw** —
/// faker picks the name, this list picks the flag, independently.
final List<String> _weightedCountryCodes = _expandWeights(const {
  'RU': 18,
  'IN': 14,
  'US': 12,
  'DE': 8,
  'FR': 7,
  'CN': 7,
  'UA': 6,
  'ES': 5,
  'AM': 4,
  'PL': 4,
  'BR': 4,
  'TR': 4,
  'NL': 3,
  'HU': 2,
  'GE': 2,
});

List<String> _expandWeights(Map<String, int> weights) {
  final out = <String>[];
  weights.forEach((code, weight) {
    for (var i = 0; i < weight; i++) {
      out.add(code);
    }
  });
  return out;
}
