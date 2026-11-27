import 'dart:math';

import 'package:faker/faker.dart' as fk;
import 'package:flutter/foundation.dart';

/// A generated bot persona — surfaces in the active-game header, tournament
/// pairings, and the player list. Deterministic by seed so re-rolling the
/// same seed in a replay produces the same persona.
///
/// IMPORTANT: names are random pairings of very common first names and
/// surnames for the bot's country (or [`faker`](https://pub.dev/packages/faker)
/// names where there is no pool) and are intentionally **not** sourced from
/// any real chess player.
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
  /// `country_flags` package expects. The name is drawn from that country's
  /// pool of common first names and surnames, combined at random, so it
  /// reads as plausible for the flag without being any particular person.
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
    final countryCode =
        _weightedCountryCodes[_rng.nextInt(_weightedCountryCodes.length)];
    // A name from the bot's own country, so "Ivan Petrov" plays for Russia
    // and "Arjun Iyer" for India. Countries without a pool fall back to
    // faker's generic names.
    final pool = _namePools[countryCode];
    final String first;
    final String last;
    if (pool != null) {
      final female = _rng.nextInt(100) < 22;
      final firsts = female ? pool.femaleFirst : pool.maleFirst;
      final lasts = female ? (pool.femaleLast ?? pool.maleLast) : pool.maleLast;
      first = firsts[_rng.nextInt(firsts.length)];
      last = lasts[_rng.nextInt(lasts.length)];
    } else {
      first = _faker.person.firstName();
      last = _faker.person.lastName();
    }
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

/// Common first names and surnames of one country, romanised, paired at
/// random. Surnames carried by well-known titled players of that federation
/// are kept out of the pools (Petrosyan, Sokolov, Hakobyan, Xu, Papp ...),
/// which makes a pairing that names a real titled player unlikely; it cannot
/// rule one out for every common name. Add to the exclusions whenever a
/// collision is reported.
class _NamePool {
  const _NamePool({
    required this.maleFirst,
    required this.femaleFirst,
    required this.maleLast,
    this.femaleLast,
  });

  final List<String> maleFirst;
  final List<String> femaleFirst;
  final List<String> maleLast;

  /// Where surnames change with gender (Petrov / Petrova); null when not.
  final List<String>? femaleLast;
}

const Map<String, _NamePool> _namePools = {
  'RU': _NamePool(
    maleFirst: [
      'Ivan',
      'Dmitry',
      'Sergey',
      'Alexei',
      'Mikhail',
      'Nikolai',
      'Pavel',
      'Andrei',
      'Yuri',
      'Oleg',
      'Kirill',
      'Maxim',
    ],
    femaleFirst: [
      'Anna',
      'Olga',
      'Elena',
      'Natalia',
      'Irina',
      'Daria',
      'Polina',
      'Ksenia',
    ],
    maleLast: [
      'Petrov',
      'Gusev',
      'Titov',
      'Kudryavtsev',
      'Kuznetsov',
      'Lebedev',
      'Morozov',
      'Novikov',
      'Sorokin',
      'Orlov',
      'Belov',
      'Zaitsev',
    ],
    femaleLast: [
      'Petrova',
      'Guseva',
      'Titova',
      'Kudryavtseva',
      'Kuznetsova',
      'Lebedeva',
      'Morozova',
      'Novikova',
      'Sorokina',
      'Orlova',
      'Belova',
      'Zaitseva',
    ],
  ),
  'IN': _NamePool(
    maleFirst: [
      'Arjun',
      'Rahul',
      'Vikram',
      'Aditya',
      'Karthik',
      'Rohan',
      'Siddharth',
      'Pranav',
      'Nikhil',
      'Varun',
      'Kunal',
      'Harsha',
    ],
    femaleFirst: [
      'Priya',
      'Ananya',
      'Divya',
      'Meera',
      'Kavya',
      'Shreya',
      'Lakshmi',
      'Nandini',
    ],
    maleLast: [
      'Iyer',
      'Sharma',
      'Reddy',
      'Nair',
      'Patel',
      'Menon',
      'Rao',
      'Kulkarni',
      'Pillai',
      'Desai',
      'Bhat',
      'Joshi',
    ],
  ),
  'US': _NamePool(
    maleFirst: [
      'James',
      'Michael',
      'David',
      'Daniel',
      'Matthew',
      'Ryan',
      'Tyler',
      'Brandon',
      'Kevin',
      'Jason',
      'Eric',
      'Sean',
    ],
    femaleFirst: [
      'Emily',
      'Sarah',
      'Jessica',
      'Ashley',
      'Megan',
      'Rachel',
      'Lauren',
      'Hannah',
    ],
    maleLast: [
      'Miller',
      'Johnson',
      'Brooks',
      'Carter',
      'Hayes',
      'Bennett',
      'Coleman',
      'Parker',
      'Reed',
      'Sullivan',
      'Foster',
      'Walsh',
    ],
  ),
  'DE': _NamePool(
    maleFirst: [
      'Lukas',
      'Jonas',
      'Felix',
      'Tobias',
      'Matthias',
      'Florian',
      'Stefan',
      'Jan',
      'Moritz',
      'Niklas',
      'Sebastian',
      'Tim',
    ],
    femaleFirst: [
      'Laura',
      'Lena',
      'Julia',
      'Katharina',
      'Sophie',
      'Anja',
      'Lisa',
      'Hannah',
    ],
    maleLast: [
      'Becker',
      'Hoffmann',
      'Schneider',
      'Wagner',
      'Fischer',
      'Schulz',
      'Koch',
      'Richter',
      'Wolf',
      'Neumann',
      'Braun',
      'Krause',
    ],
  ),
  'FR': _NamePool(
    maleFirst: [
      'Julien',
      'Thomas',
      'Nicolas',
      'Antoine',
      'Maxime',
      'Hugo',
      'Lucas',
      'Pierre',
      'Mathieu',
      'Romain',
      'Louis',
      'Baptiste',
    ],
    femaleFirst: [
      'Camille',
      'Chloé',
      'Manon',
      'Léa',
      'Claire',
      'Juliette',
      'Sophie',
      'Élise',
    ],
    maleLast: [
      'Martin',
      'Bernard',
      'Dubois',
      'Moreau',
      'Laurent',
      'Lefèvre',
      'Girard',
      'Fournier',
      'Mercier',
      'Rousseau',
      'Blanc',
      'Garnier',
    ],
  ),
  'CN': _NamePool(
    maleFirst: [
      'Wei',
      'Jun',
      'Rui',
      'Lei',
      'Tao',
      'Yang',
      'Peng',
      'Bo',
      'Chen',
      'Zhen',
      'Kai',
      'Ming',
    ],
    femaleFirst: ['Mei', 'Lin', 'Xin', 'Yan', 'Jing', 'Hui', 'Ling', 'Fang'],
    maleLast: [
      'Wang',
      'Li',
      'Zhang',
      'Liu',
      'Chen',
      'Yang',
      'Feng',
      'Huang',
      'Zhou',
      'Wu',
      'Tang',
      'Sun',
    ],
  ),
  'UA': _NamePool(
    maleFirst: [
      'Oleksandr',
      'Andriy',
      'Taras',
      'Bohdan',
      'Mykola',
      'Vasyl',
      'Yaroslav',
      'Dmytro',
      'Serhiy',
      'Petro',
      'Ivan',
      'Roman',
    ],
    femaleFirst: [
      'Oksana',
      'Olena',
      'Iryna',
      'Kateryna',
      'Yulia',
      'Nataliya',
      'Sofiya',
      'Mariya',
    ],
    maleLast: [
      'Shevchenko',
      'Kovalenko',
      'Bondarenko',
      'Tkachenko',
      'Kravchenko',
      'Melnyk',
      'Boyko',
      'Oliynyk',
      'Lysenko',
      'Marchenko',
      'Rudenko',
      'Savchenko',
    ],
  ),
  'ES': _NamePool(
    maleFirst: [
      'Javier',
      'Alejandro',
      'Pablo',
      'Sergio',
      'Daniel',
      'Álvaro',
      'Diego',
      'Marcos',
      'Adrián',
      'Raúl',
      'Iván',
      'Carlos',
    ],
    femaleFirst: [
      'Lucía',
      'María',
      'Paula',
      'Elena',
      'Carmen',
      'Marta',
      'Sara',
      'Irene',
    ],
    maleLast: [
      'García',
      'Fernández',
      'Martínez',
      'Sánchez',
      'Romero',
      'Navarro',
      'Torres',
      'Domínguez',
      'Ruiz',
      'Moreno',
      'Ortega',
      'Delgado',
    ],
  ),
  'AM': _NamePool(
    maleFirst: [
      'Aram',
      'Tigran',
      'Hayk',
      'Armen',
      'Davit',
      'Gor',
      'Vahe',
      'Karen',
      'Arsen',
      'Narek',
      'Levon',
      'Samvel',
    ],
    femaleFirst: [
      'Ani',
      'Lilit',
      'Mariam',
      'Anush',
      'Nare',
      'Gayane',
      'Sona',
      'Elen',
    ],
    maleLast: [
      'Simonyan',
      'Melkonyan',
      'Sargsyan',
      'Danielyan',
      'Harutyunyan',
      'Khachatryan',
      'Avetisyan',
      'Ghazaryan',
      'Gevorgyan',
      'Vardanyan',
      'Hovhannisyan',
      'Karapetyan',
    ],
  ),
  'PL': _NamePool(
    maleFirst: [
      'Piotr',
      'Tomasz',
      'Krzysztof',
      'Paweł',
      'Michał',
      'Marcin',
      'Jakub',
      'Łukasz',
      'Kamil',
      'Bartosz',
      'Mateusz',
      'Wojciech',
    ],
    femaleFirst: [
      'Anna',
      'Katarzyna',
      'Magdalena',
      'Agnieszka',
      'Joanna',
      'Monika',
      'Natalia',
      'Zofia',
    ],
    maleLast: [
      'Nowak',
      'Kowalski',
      'Wiśniewski',
      'Wójcik',
      'Kamiński',
      'Lewandowski',
      'Zieliński',
      'Szymański',
      'Woźniak',
      'Dąbrowski',
      'Mazur',
      'Krawczyk',
    ],
    femaleLast: [
      'Nowak',
      'Kowalska',
      'Wiśniewska',
      'Wójcik',
      'Kamińska',
      'Lewandowska',
      'Zielińska',
      'Szymańska',
      'Woźniak',
      'Dąbrowska',
      'Mazur',
      'Krawczyk',
    ],
  ),
  'BR': _NamePool(
    maleFirst: [
      'João',
      'Pedro',
      'Lucas',
      'Gabriel',
      'Rafael',
      'Mateus',
      'Thiago',
      'Felipe',
      'Bruno',
      'Gustavo',
      'Rodrigo',
      'Vinícius',
    ],
    femaleFirst: [
      'Ana',
      'Beatriz',
      'Juliana',
      'Larissa',
      'Camila',
      'Fernanda',
      'Mariana',
      'Letícia',
    ],
    maleLast: [
      'Silva',
      'Santos',
      'Oliveira',
      'Souza',
      'Pereira',
      'Costa',
      'Rodrigues',
      'Almeida',
      'Carvalho',
      'Ribeiro',
      'Gomes',
      'Barbosa',
    ],
  ),
  'TR': _NamePool(
    maleFirst: [
      'Emre',
      'Mehmet',
      'Burak',
      'Can',
      'Kerem',
      'Murat',
      'Onur',
      'Serkan',
      'Tolga',
      'Barış',
      'Oğuz',
      'Deniz',
    ],
    femaleFirst: [
      'Elif',
      'Zeynep',
      'Ayşe',
      'Selin',
      'Ece',
      'Merve',
      'Defne',
      'Ebru',
    ],
    maleLast: [
      'Yılmaz',
      'Kaya',
      'Demir',
      'Şahin',
      'Çelik',
      'Yıldız',
      'Aydın',
      'Öztürk',
      'Arslan',
      'Doğan',
      'Kılıç',
      'Aslan',
    ],
  ),
  'NL': _NamePool(
    maleFirst: [
      'Daan',
      'Sem',
      'Bram',
      'Thijs',
      'Joris',
      'Ruben',
      'Jeroen',
      'Sander',
      'Wouter',
      'Lars',
      'Niels',
      'Pieter',
    ],
    femaleFirst: [
      'Sanne',
      'Fleur',
      'Lotte',
      'Anouk',
      'Eva',
      'Femke',
      'Iris',
      'Noor',
    ],
    maleLast: [
      'de Vries',
      'Jansen',
      'Bakker',
      'Visser',
      'Smit',
      'Meijer',
      'Mulder',
      'de Boer',
      'Bos',
      'Vos',
      'Peters',
      'Hendriks',
    ],
  ),
  'HU': _NamePool(
    maleFirst: [
      'Bence',
      'Máté',
      'Dávid',
      'Levente',
      'Balázs',
      'Gábor',
      'Tamás',
      'Zoltán',
      'Péter',
      'Ádám',
      'Krisztián',
      'Attila',
    ],
    femaleFirst: [
      'Anna',
      'Réka',
      'Eszter',
      'Dóra',
      'Zsófia',
      'Petra',
      'Kata',
      'Lilla',
    ],
    maleLast: [
      'Nagy',
      'Kovács',
      'Tóth',
      'Szabó',
      'Horváth',
      'Fekete',
      'Kiss',
      'Molnár',
      'Németh',
      'Farkas',
      'Balogh',
      'Takács',
    ],
  ),
  'GE': _NamePool(
    maleFirst: [
      'Giorgi',
      'Levan',
      'Davit',
      'Nikoloz',
      'Irakli',
      'Luka',
      'Tornike',
      'Zurab',
      'Lasha',
      'Sandro',
      'Beka',
      'Vakhtang',
    ],
    femaleFirst: [
      'Nino',
      'Tamar',
      'Mariam',
      'Ana',
      'Salome',
      'Eka',
      'Ketevan',
      'Natia',
    ],
    maleLast: [
      'Beridze',
      'Kapanadze',
      'Gelashvili',
      'Tsereteli',
      'Lomidze',
      'Tsiklauri',
      'Giorgadze',
      'Chkheidze',
      'Abashidze',
      'Mamaladze',
      'Gogoladze',
      'Nozadze',
    ],
  ),
};
