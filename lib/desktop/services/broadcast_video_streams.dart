/// Desktop port of the web broadcast video-stream contract.
///
/// The web Board screen reads `…/video-streams` for the round or tour it is
/// showing and renders the editor-curated Twitch / YouTube / Kick players
/// in the top-right corner. The desktop Board pane carries the same panel,
/// so the models, language grouping and selection defaults below mirror
/// `chessever_web_frontend/src/broadcast/lib/video-streams.ts`,
/// `video-language.ts` and `video-playback.ts` one-for-one.
///
/// Playback itself is never a provider player loaded top-level: the desktop
/// WebView loads chessever.com's own `/embed/video/…` document, which frames
/// the provider exactly as the site does. Twitch's `parent` and YouTube's
/// referrer are therefore the real host serving that page, not values the
/// app asserts about itself. See docs/broadcast_video_embed_compliance.md.
library;

import 'dart:convert';

import 'package:country_picker/country_picker.dart' show CountryService;
import 'package:http/http.dart' as http;

/// Public broadcast API host. Same origin the web spectator bridge proxies to.
const String broadcastApiOrigin = 'https://api.broadcast.chessever.com';

/// Public site origin: hosts the `/watch` pages the toolbar links to and the
/// `/embed/video` documents the panel plays through.
const String broadcastWatchOrigin = 'https://chessever.com';

enum BroadcastVideoProvider { twitch, youtube, kick }

extension BroadcastVideoProviderX on BroadcastVideoProvider {
  String get wireName => switch (this) {
    BroadcastVideoProvider.twitch => 'twitch',
    BroadcastVideoProvider.youtube => 'youtube',
    BroadcastVideoProvider.kick => 'kick',
  };

  String get displayName => switch (this) {
    BroadcastVideoProvider.twitch => 'Twitch',
    BroadcastVideoProvider.youtube => 'YouTube',
    BroadcastVideoProvider.kick => 'Kick',
  };

  /// Provider minimum player size, matching the web adapters.
  double get minWidth => switch (this) {
    BroadcastVideoProvider.twitch => 400,
    BroadcastVideoProvider.youtube => 200,
    BroadcastVideoProvider.kick => 200,
  };

  double get minHeight => switch (this) {
    BroadcastVideoProvider.twitch => 300,
    BroadcastVideoProvider.youtube => 200,
    BroadcastVideoProvider.kick => 200,
  };
}

BroadcastVideoProvider? broadcastVideoProviderFromWire(String? value) {
  return switch (value) {
    'twitch' => BroadcastVideoProvider.twitch,
    'youtube' => BroadcastVideoProvider.youtube,
    'kick' => BroadcastVideoProvider.kick,
    _ => null,
  };
}

/// Spectator surfaces that may see a stream. Omitted on the wire means all.
enum BroadcastVideoClientPlatform { web, mobile, desktop }

const Set<String> _broadcastVideoClientPlatformNames = <String>{
  'web',
  'mobile',
  'desktop',
};

BroadcastVideoClientPlatform? broadcastVideoClientPlatformFromWire(
  String? value,
) {
  return switch (value) {
    'web' => BroadcastVideoClientPlatform.web,
    'mobile' => BroadcastVideoClientPlatform.mobile,
    'desktop' => BroadcastVideoClientPlatform.desktop,
    _ => null,
  };
}

/// Same rule as the web's `streamSupportsPlatform`: a missing list is public.
bool broadcastStreamSupportsPlatform(
  BroadcastVideoStream stream,
  BroadcastVideoClientPlatform platform,
) {
  final platforms = stream.platforms;
  return platforms == null || platforms.contains(platform);
}

/// Editable facts about one broadcast session. Dates stay ISO strings: the
/// panel only shows title / status, and the API already normalises them.
class BroadcastVideoPublication {
  const BroadcastVideoPublication({
    this.title,
    this.description,
    this.thumbnailUrl,
    this.uploadDate,
    this.language,
    this.scheduledStart,
    this.scheduledEnd,
    this.actualStart,
    this.actualEnd,
    this.status,
    this.confirmedAt,
    this.sessionMismatch,
  });

  final String? title;
  final String? description;
  final String? thumbnailUrl;
  final String? uploadDate;
  final String? language;
  final String? scheduledStart;
  final String? scheduledEnd;
  final String? actualStart;
  final String? actualEnd;
  final String? status;
  final String? confirmedAt;
  final bool? sessionMismatch;

  bool get isLive => status == 'live';

  static BroadcastVideoPublication? fromJson(Object? value) {
    if (value is! Map) return null;
    String? text(String key) {
      final raw = value[key];
      return raw is String && raw.trim().isNotEmpty ? raw : null;
    }

    return BroadcastVideoPublication(
      title: text('title'),
      description: text('description'),
      thumbnailUrl: text('thumbnailUrl'),
      uploadDate: text('uploadDate'),
      language: text('language'),
      scheduledStart: text('scheduledStart'),
      scheduledEnd: text('scheduledEnd'),
      actualStart: text('actualStart'),
      actualEnd: text('actualEnd'),
      status: text('status'),
      confirmedAt: text('confirmedAt'),
      sessionMismatch: value['sessionMismatch'] == true ? true : null,
    );
  }
}

/// Channel audience snapshot. Counts are channel totals, not per-video.
class BroadcastVideoAudience {
  const BroadcastVideoAudience({
    required this.channelId,
    this.count,
    this.checkedOn,
  });

  final String channelId;
  final int? count;
  final String? checkedOn;

  static BroadcastVideoAudience? fromJson(Object? value) {
    if (value is! Map) return null;
    final channelId = value['channelId'];
    if (channelId is! String || channelId.isEmpty) return null;
    return BroadcastVideoAudience(
      channelId: channelId,
      count: value['count'] is num ? (value['count'] as num).toInt() : null,
      checkedOn:
          value['checkedOn'] is String ? value['checkedOn'] as String : null,
    );
  }
}

class BroadcastVideoStream {
  const BroadcastVideoStream({
    required this.id,
    required this.label,
    required this.provider,
    required this.sourceId,
    required this.url,
    this.countryCode,
    this.language,
    this.platforms,
    this.publication,
    this.audience,
    this.preferred,
  });

  final String id;
  final String label;
  final String? countryCode;

  /// Top-level language tag from the API (`en`, `hi`, `en-IN`). Distinct
  /// from [BroadcastVideoPublication.language]. Grouping, flags, and FIDE
  /// camera detection all read this first, matching mobile
  /// `inferredLanguage` and the web's `primaryLanguage`.
  final String? language;

  /// When set, only these spectator surfaces may show the stream.
  final Set<BroadcastVideoClientPlatform>? platforms;
  final BroadcastVideoProvider provider;
  final String sourceId;
  final String url;
  final BroadcastVideoPublication? publication;
  final BroadcastVideoAudience? audience;
  final bool? preferred;

  BroadcastVideoStream copyWith({
    String? countryCode,
    String? language,
    Set<BroadcastVideoClientPlatform>? platforms,
    BroadcastVideoPublication? publication,
    BroadcastVideoAudience? audience,
    bool? preferred,
  }) {
    return BroadcastVideoStream(
      id: id,
      label: label,
      provider: provider,
      sourceId: sourceId,
      url: url,
      countryCode: countryCode ?? this.countryCode,
      language: language ?? this.language,
      platforms: platforms ?? this.platforms,
      publication: publication ?? this.publication,
      audience: audience ?? this.audience,
      preferred: preferred ?? this.preferred,
    );
  }

  static BroadcastVideoStream? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final label = value['label'];
    final sourceId = value['sourceId'];
    final url = value['url'];
    final provider = broadcastVideoProviderFromWire(
      value['provider'] is String ? value['provider'] as String : null,
    );
    if (id is! String ||
        id.isEmpty ||
        label is! String ||
        label.isEmpty ||
        sourceId is! String ||
        sourceId.isEmpty ||
        url is! String ||
        url.isEmpty ||
        provider == null) {
      return null;
    }
    Set<BroadcastVideoClientPlatform>? platforms;
    if (value.containsKey('platforms')) {
      final raw = value['platforms'];
      if (raw is! List ||
          raw.any(
            (entry) =>
                entry is! String ||
                !_broadcastVideoClientPlatformNames.contains(entry),
          )) {
        return null;
      }
      platforms =
          raw
              .cast<String>()
              .map(broadcastVideoClientPlatformFromWire)
              .whereType<BroadcastVideoClientPlatform>()
              .toSet();
    }
    String? language;
    if (value.containsKey('language')) {
      final raw = value['language'];
      if (raw == null || raw == '') {
        language = null;
      } else if (raw is String && raw.trim().isNotEmpty && raw.length <= 80) {
        language = raw.trim();
      } else {
        return null;
      }
    }
    final country = value['countryCode'];
    return BroadcastVideoStream(
      id: id,
      label: label,
      countryCode:
          country is String && country.trim().isNotEmpty
              ? country.trim().toUpperCase()
              : null,
      language: language,
      platforms: platforms,
      provider: provider,
      sourceId: sourceId,
      url: url,
      publication: BroadcastVideoPublication.fromJson(value['publication']),
      audience: BroadcastVideoAudience.fromJson(value['audience']),
      preferred: value['preferred'] == true ? true : null,
    );
  }
}

/// Where a resolved stream list came from. Groups inherit down
/// round → tour → group on the API, so the desktop only ever asks for the
/// narrowest scope it knows.
class BroadcastVideoScope {
  const BroadcastVideoScope({required this.tourId, this.roundId});

  final String tourId;
  final String? roundId;

  bool get hasRound => roundId != null && roundId!.trim().isNotEmpty;

  String get effectiveRoundId => roundId!.trim();

  List<String> get apiPathSegments =>
      hasRound ? <String>['round', effectiveRoundId] : <String>[tourId];

  @override
  bool operator ==(Object other) =>
      other is BroadcastVideoScope &&
      other.tourId == tourId &&
      other.roundId == roundId;

  @override
  int get hashCode => Object.hash(tourId, roundId);

  @override
  String toString() => hasRound ? 'round/$effectiveRoundId' : 'tour/$tourId';
}

class BroadcastVideoSourceRef {
  const BroadcastVideoSourceRef({required this.scope, required this.id});

  final String scope;
  final String id;

  static BroadcastVideoSourceRef? fromJson(Object? value) {
    if (value is! Map) return null;
    final scope = value['scope'];
    final id = value['id'];
    if (scope is! String || id is! String || scope.isEmpty || id.isEmpty) {
      return null;
    }
    return BroadcastVideoSourceRef(scope: scope, id: id);
  }
}

class ResolvedBroadcastVideoStreams {
  const ResolvedBroadcastVideoStreams({required this.streams, this.source});

  final List<BroadcastVideoStream> streams;
  final BroadcastVideoSourceRef? source;

  static const ResolvedBroadcastVideoStreams empty =
      ResolvedBroadcastVideoStreams(streams: <BroadcastVideoStream>[]);

  static ResolvedBroadcastVideoStreams fromJson(Object? value) {
    if (value is! Map) return empty;
    final rawStreams = value['streams'];
    final streams = <BroadcastVideoStream>[];
    if (rawStreams is List) {
      for (final entry in rawStreams) {
        final stream = BroadcastVideoStream.fromJson(entry);
        if (stream != null) streams.add(stream);
      }
    }
    return ResolvedBroadcastVideoStreams(
      streams: streams,
      source: BroadcastVideoSourceRef.fromJson(value['source']),
    );
  }
}

class BroadcastVideoStreamsException implements Exception {
  const BroadcastVideoStreamsException(this.message, {this.permanent = false});

  final String message;

  /// A permanent failure (4xx / malformed body) clears an already playing
  /// panel on the web; transient failures leave the current frame alone.
  final bool permanent;

  @override
  String toString() => 'BroadcastVideoStreamsException: $message';
}

/// Reads the editor-curated stream list for one scope.
class BroadcastVideoStreamsClient {
  BroadcastVideoStreamsClient({
    http.Client? httpClient,
    Uri? baseUrl,
    this.timeout = const Duration(seconds: 12),
  }) : _http = httpClient ?? http.Client(),
       baseUrl = baseUrl ?? Uri.parse(broadcastApiOrigin);

  final http.Client _http;
  final Uri baseUrl;
  final Duration timeout;

  Uri endpointFor(BroadcastVideoScope scope) {
    final segments = <String>[
      ...baseUrl.pathSegments.where((segment) => segment.isNotEmpty),
      'api',
      'broadcast',
      ...scope.apiPathSegments,
      'video-streams',
    ];
    return baseUrl.replace(pathSegments: segments);
  }

  Future<ResolvedBroadcastVideoStreams> fetch(BroadcastVideoScope scope) async {
    final uri = endpointFor(scope);
    final http.Response response;
    try {
      response = await _http
          .get(
            uri,
            headers: const <String, String>{'accept': 'application/json'},
          )
          .timeout(timeout);
    } on Exception catch (error) {
      throw BroadcastVideoStreamsException('Request failed: $error');
    }
    if (response.statusCode != 200) {
      throw BroadcastVideoStreamsException(
        'Broadcast video service returned ${response.statusCode}.',
        permanent: response.statusCode >= 400 && response.statusCode < 500,
      );
    }
    try {
      return ResolvedBroadcastVideoStreams.fromJson(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
    } on FormatException catch (error) {
      throw BroadcastVideoStreamsException(
        'Invalid broadcast video payload: ${error.message}',
        permanent: true,
      );
    }
  }

  void dispose() => _http.close();
}

/// The site document the desktop player loads: one editor-curated stream,
/// resolved by the API for its scope, framed by chessever.com itself.
/// `play` mirrors the web's in-game autoplay decision.
Uri broadcastVideoEmbedPageUri({
  required String scope,
  required String scopeId,
  required String streamId,
  required bool play,
}) {
  final path = <String>[
    'embed',
    'video',
    scope,
    scopeId,
    streamId,
  ].map(Uri.encodeComponent).join('/');
  return Uri.parse('$broadcastWatchOrigin/$path?autoplay=${play ? 1 : 0}');
}

/// Hosts a main-frame navigation may stay on inside the desktop player: the
/// embed document itself. Provider frames live inside it; anything that
/// tries to take over the top frame (a "Watch on Twitch" link, a channel
/// page) belongs in the real browser.
final Set<String> broadcastEmbedPageHosts = <String>{
  Uri.parse(broadcastWatchOrigin).host,
  'www.${Uri.parse(broadcastWatchOrigin).host}',
};

/// Public watch page for one stream, mirroring `watchPath` on the web.
Uri broadcastVideoWatchUri({
  required String scope,
  required String scopeId,
  required String streamId,
}) {
  final path = <String>[
    'watch',
    scope,
    scopeId,
    streamId,
  ].map(Uri.encodeComponent).join('/');
  return Uri.parse('$broadcastWatchOrigin/$path');
}

// ---------------------------------------------------------------------------
// Language grouping and default selection (ports of video-language.ts and
// video-playback.ts).
// ---------------------------------------------------------------------------

class BroadcastStreamLanguage {
  const BroadcastStreamLanguage({
    required this.code,
    required this.label,
    this.countryCode,
  });

  final String code;
  final String label;
  final String? countryCode;
}

class _KnownLanguage {
  const _KnownLanguage({
    required this.codes,
    required this.names,
    required this.label,
    required this.countryCode,
  });

  final List<String> codes;
  final List<String> names;
  final String label;
  final String countryCode;
}

const List<_KnownLanguage> _knownLanguages = <_KnownLanguage>[
  _KnownLanguage(
    codes: ['en'],
    names: ['english'],
    label: 'English',
    countryCode: 'GB',
  ),
  _KnownLanguage(
    codes: ['fi'],
    names: ['finnish', 'suomi'],
    label: 'Finnish',
    countryCode: 'FI',
  ),
  _KnownLanguage(
    codes: ['uk'],
    names: ['ukrainian', 'українська'],
    label: 'Ukrainian',
    countryCode: 'UA',
  ),
  _KnownLanguage(
    codes: ['vi'],
    names: ['vietnamese', 'tiếng việt'],
    label: 'Vietnamese',
    countryCode: 'VN',
  ),
  _KnownLanguage(
    codes: ['hinglish'],
    names: ['hinglish'],
    label: 'Hinglish',
    countryCode: 'IN',
  ),
  _KnownLanguage(
    codes: ['hi'],
    names: ['hindi'],
    label: 'Hindi',
    countryCode: 'IN',
  ),
  _KnownLanguage(
    codes: ['es'],
    names: ['spanish', 'español'],
    label: 'Spanish',
    countryCode: 'ES',
  ),
  _KnownLanguage(
    codes: ['de'],
    names: ['german', 'deutsch'],
    label: 'German',
    countryCode: 'DE',
  ),
  _KnownLanguage(
    codes: ['fr'],
    names: ['french', 'français'],
    label: 'French',
    countryCode: 'FR',
  ),
  _KnownLanguage(
    codes: ['it'],
    names: ['italian', 'italiano'],
    label: 'Italian',
    countryCode: 'IT',
  ),
  _KnownLanguage(
    codes: ['pt'],
    names: ['portuguese', 'português'],
    label: 'Portuguese',
    countryCode: 'PT',
  ),
  _KnownLanguage(
    codes: ['pl'],
    names: ['polish', 'polski'],
    label: 'Polish',
    countryCode: 'PL',
  ),
  _KnownLanguage(
    codes: ['ru'],
    names: ['russian', 'русский'],
    label: 'Russian',
    countryCode: 'RU',
  ),
  _KnownLanguage(
    codes: ['tr'],
    names: ['turkish', 'türkçe'],
    label: 'Turkish',
    countryCode: 'TR',
  ),
  _KnownLanguage(
    codes: ['uz'],
    names: ['uzbek', 'oʻzbek', "o'zbek", 'ozbek'],
    label: 'Uzbek',
    countryCode: 'UZ',
  ),
  _KnownLanguage(
    codes: ['zh'],
    names: ['chinese', '中文'],
    label: 'Chinese',
    countryCode: 'CN',
  ),
  _KnownLanguage(
    codes: ['ja'],
    names: ['japanese', '日本語'],
    label: 'Japanese',
    countryCode: 'JP',
  ),
  _KnownLanguage(
    codes: ['ko'],
    names: ['korean', '한국어'],
    label: 'Korean',
    countryCode: 'KR',
  ),
  _KnownLanguage(
    codes: ['ms'],
    names: ['malay'],
    label: 'Malay',
    countryCode: 'MY',
  ),
  _KnownLanguage(
    codes: ['ar'],
    names: ['arabic', 'العربية'],
    label: 'Arabic',
    countryCode: 'SA',
  ),
];

_KnownLanguage? _knownLanguageFromCode(String code) {
  final normalized = code.trim().toLowerCase();
  if (normalized.isEmpty) return null;
  final primary = normalized.split(RegExp('[-_]')).first;
  for (final entry in _knownLanguages) {
    if (entry.codes.contains(primary) || entry.names.contains(normalized)) {
      return entry;
    }
  }
  return null;
}

final RegExp _letterPattern = RegExp(r'\p{L}', unicode: true);

bool _isLetter(String character) => _letterPattern.hasMatch(character);

/// Whole-word match mirroring the web's `(^|[^\p{L}])name([^\p{L}]|$)` rule.
bool _containsWord(String haystack, String needle) {
  if (needle.isEmpty) return false;
  final text = haystack.toLowerCase();
  final word = needle.toLowerCase();
  var index = text.indexOf(word);
  while (index >= 0) {
    final before = index == 0 ? '' : text[index - 1];
    final afterIndex = index + word.length;
    final after = afterIndex >= text.length ? '' : text[afterIndex];
    if ((before.isEmpty || !_isLetter(before)) &&
        (after.isEmpty || !_isLetter(after))) {
      return true;
    }
    index = text.indexOf(word, index + 1);
  }
  return false;
}

BroadcastStreamLanguage broadcastStreamLanguage(BroadcastVideoStream stream) {
  const unknown = BroadcastStreamLanguage(
    code: 'und',
    label: 'Language unknown',
  );
  // Editor-set stream.language first (mobile inferredLanguage / web
  // primaryLanguage), then YouTube publication.language. Title words are
  // only a fallback when neither tag is recognised.
  for (final explicit in <String?>[
    stream.language,
    stream.publication?.language,
  ]) {
    if (explicit == null || explicit.isEmpty) continue;
    final match = _knownLanguageFromCode(explicit);
    if (match != null) {
      return BroadcastStreamLanguage(
        code: match.codes.first,
        label: match.label,
        countryCode: match.countryCode,
      );
    }
  }
  final text = <String>[
    stream.publication?.title ?? '',
    stream.publication?.description ?? '',
    stream.label,
  ].where((value) => value.isNotEmpty).join(' ');
  for (final entry in _knownLanguages) {
    if (entry.names.any((name) => _containsWord(text, name))) {
      return BroadcastStreamLanguage(
        code: entry.codes.first,
        label: entry.label,
        countryCode: entry.countryCode,
      );
    }
  }
  return unknown;
}

/// Strips only a recognised trailing language tag ("Channel · English"),
/// never words that are part of a channel name.
String broadcastVideoStreamDisplayName(BroadcastVideoStream stream) {
  final match = RegExp(
    r'^(.*?)\s+·\s+([^·]+)$',
    unicode: true,
  ).firstMatch(stream.label);
  if (match == null || match.group(1)!.trim().isEmpty) return stream.label;
  final suffix = match.group(2)!.trim().toLowerCase();
  final known =
      _knownLanguages.any(
        (language) => language.names.any((name) => name == suffix),
      ) ||
      const <String>['finnish', 'ukrainian'].contains(suffix);
  return known ? match.group(1)!.trim() : stream.label;
}

String broadcastVideoStreamTitle(BroadcastVideoStream stream) =>
    '${broadcastVideoStreamDisplayName(stream)} · ${stream.provider.displayName}';

class BroadcastVideoStreamGroup {
  const BroadcastVideoStreamGroup({
    required this.key,
    required this.code,
    required this.label,
    this.countryCode,
    required this.streams,
  });

  final String key;
  final String code;
  final String label;
  final String? countryCode;
  final List<BroadcastVideoStream> streams;
}

/// Groups only when language evidence exists. A country is a fallback label,
/// never evidence that all of its streams share one language.
List<BroadcastVideoStreamGroup> groupBroadcastVideoStreams(
  List<BroadcastVideoStream> streams,
) {
  final groups = <String, List<BroadcastVideoStream>>{};
  final display = <String, BroadcastStreamLanguage>{};
  for (final stream in streams) {
    final language = broadcastStreamLanguage(stream);
    final countryName = broadcastCountryName(stream.countryCode);
    final key =
        language.code != 'und'
            ? language.code
            : stream.countryCode != null && countryName != null
            ? 'country-${stream.countryCode}'
            : 'stream-${stream.id}';
    final resolved =
        language.code != 'und'
            ? BroadcastStreamLanguage(
              code: language.code,
              label: language.label,
              countryCode: stream.countryCode ?? language.countryCode,
            )
            : countryName != null
            ? BroadcastStreamLanguage(
              code: key,
              label: countryName,
              countryCode: stream.countryCode,
            )
            : language;
    groups.putIfAbsent(key, () => <BroadcastVideoStream>[]).add(stream);
    display[key] = resolved;
  }
  // Resolve repeated channel snapshots once, newest observation wins. Never
  // add duplicate videos twice.
  final observations = <String, BroadcastVideoAudience>{};
  for (final stream in streams) {
    final audience = stream.audience;
    if (audience == null) continue;
    final key = '${stream.provider.wireName}:${audience.channelId}';
    final old = observations[key];
    final checkedOn = audience.checkedOn ?? '';
    final oldCheckedOn = old?.checkedOn ?? '';
    if (old == null ||
        checkedOn.compareTo(oldCheckedOn) > 0 ||
        (checkedOn == oldCheckedOn &&
            (audience.count ?? -1) > (old.count ?? -1))) {
      observations[key] = audience;
    }
  }
  int count(BroadcastVideoStream stream) {
    final audience = stream.audience;
    if (audience == null) return -1;
    return observations['${stream.provider.wireName}:${audience.channelId}']
            ?.count ??
        -1;
  }

  int total(BroadcastVideoStreamGroup group) {
    final channels = <String>{};
    var value = 0;
    var known = false;
    for (final stream in group.streams) {
      if (stream.audience == null) continue;
      final streamCount = count(stream);
      if (streamCount < 0) continue;
      final key = '${stream.provider.wireName}:${stream.audience!.channelId}';
      if (!channels.add(key)) continue;
      known = true;
      value += streamCount;
    }
    return known ? value : -1;
  }

  int nameOrder(BroadcastVideoStream a, BroadcastVideoStream b) {
    final byName = broadcastVideoStreamDisplayName(
      a,
    ).toLowerCase().compareTo(broadcastVideoStreamDisplayName(b).toLowerCase());
    if (byName != 0) return byName;
    return a.id.compareTo(b.id);
  }

  final ordered =
      groups.entries
          .map(
            (entry) => BroadcastVideoStreamGroup(
              key: entry.key,
              code: display[entry.key]!.code,
              label: display[entry.key]!.label,
              countryCode: display[entry.key]!.countryCode,
              streams:
                  entry.value..sort((a, b) {
                    final byPreferred =
                        (b.preferred == true ? 1 : 0) -
                        (a.preferred == true ? 1 : 0);
                    if (byPreferred != 0) return byPreferred;
                    final byCount = count(b) - count(a);
                    if (byCount != 0) return byCount;
                    return nameOrder(a, b);
                  }),
            ),
          )
          .toList();
  ordered.sort((a, b) {
    final byEnglish = (b.code == 'en' ? 1 : 0) - (a.code == 'en' ? 1 : 0);
    if (byEnglish != 0) return byEnglish;
    final byTotal = total(b) - total(a);
    if (byTotal != 0) return byTotal;
    final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
    if (byLabel != 0) return byLabel;
    return a.key.compareTo(b.key);
  });
  return ordered;
}

/// Same default chain as the web: exact pick, then a non-English remembered
/// language, then FIDE main commentary, then English/any memory, then the
/// legacy per-tournament country fallback, then the group order.
BroadcastVideoStream? resolveBroadcastVideoSelection(
  List<BroadcastVideoStream> streams, {
  String? selectedId,
  String? language,
  String? countryCode,
}) {
  final groups = groupBroadcastVideoStreams(streams);
  final flat = groups.expand((group) => group.streams).toList();
  for (final stream in flat) {
    if (selectedId != null && stream.id == selectedId) return stream;
  }
  BroadcastVideoStream? remembered;
  if (language != null) {
    for (final group in groups) {
      if (group.key == language && group.streams.isNotEmpty) {
        remembered = group.streams.first;
        break;
      }
    }
  }
  if (language != null && language != 'en' && remembered != null) {
    return remembered;
  }
  for (final stream in flat) {
    if (isFideMainCommentary(stream)) return stream;
  }
  if (remembered != null) return remembered;
  if (countryCode != null) {
    for (final stream in flat) {
      if (stream.countryCode == countryCode) return stream;
    }
  }
  return flat.isEmpty ? null : flat.first;
}

/// Language group key remembered across tournaments (`ce-video-language.v1`),
/// identical to the web's `languageGroupKey`.
String broadcastVideoLanguageGroupKey(BroadcastVideoStream stream) {
  final language = broadcastStreamLanguage(stream);
  if (language.code != 'und') return language.code;
  if (stream.countryCode != null) return 'country-${stream.countryCode}';
  return 'stream-${stream.id}';
}

/// English country name for a valid ISO 3166-1 alpha-2 code, else null.
/// Uses the same English source the web's `Intl.DisplayNames` yields.
String? broadcastCountryName(String? code) {
  if (code == null) return null;
  final country = code.trim().toUpperCase();
  if (country.length != 2) return null;
  return _englishRegionNames()[country];
}

Map<String, String>? _cachedRegionNames;

Map<String, String> _englishRegionNames() {
  final cached = _cachedRegionNames;
  if (cached != null) return cached;
  final names = <String, String>{};
  // `country_picker` already ships an English name for every ISO code in the
  // app; reuse it instead of hard-coding another 250-entry table.
  try {
    for (final country in CountryService().getAll()) {
      final code = country.countryCode.trim().toUpperCase();
      if (code.length == 2 && country.name.trim().isNotEmpty) {
        names[code] = country.name.trim();
      }
    }
  } on Exception {
    /* Fall through with whatever was collected. */
  }
  return _cachedRegionNames = names;
}

// ---------------------------------------------------------------------------
// In-game toolbar grouping (ports of video-fide.ts and
// video-language-overflow.ts). Numbered official FIDE cameras stay one
// final control; spare rail width unwraps ordinary languages into
// individual flags.
// ---------------------------------------------------------------------------

const String fideYoutubeChannelId = 'UC9B47GnzCRFHTT1BIBWvStQ';

final RegExp _fideOlympiadTitle = RegExp(
  r'^♟?\s*FIDE Chess Olympiad 2026\s*\|\s*Round\s+\d+\s*\|',
);
final RegExp _fideCameraStream = RegExp(
  r'^♟?\s*FIDE Chess Olympiad 2026\s*\|\s*Round\s+\d+\s*\|\s*(?:Stream\s+(\d+)\s*\|\s*(Open|Women)|(Open|Women)\s+Stream\s+(\d+))\s*$',
);
final RegExp _fideCameraBoard = RegExp(
  r'^♟?\s*FIDE Chess Olympiad 2026\s*\|\s*Round\s+\d+\s*\|\s*(?!Stream\s+\d+\s*\|)(?!(?:Open|Women)\s+Stream\s+\d+\s*$).+\|\s*(Open|Women)\s*$',
);

bool _isFideCameraTitle(String title) {
  return _fideCameraStream.hasMatch(title) || _fideCameraBoard.hasMatch(title);
}

enum BroadcastToolbarVideoKind { language, fide, cameras, camera }

class BroadcastToolbarVideoGroup {
  const BroadcastToolbarVideoGroup({
    required this.key,
    required this.code,
    required this.label,
    required this.streams,
    required this.kind,
    this.countryCode,
    this.cameraNumber,
  });

  final String key;
  final String code;
  final String label;
  final String? countryCode;
  final List<BroadcastVideoStream> streams;
  final BroadcastToolbarVideoKind kind;
  final int? cameraNumber;

  BroadcastToolbarVideoGroup copyWith({
    String? key,
    List<BroadcastVideoStream>? streams,
    BroadcastToolbarVideoKind? kind,
    int? cameraNumber,
  }) {
    return BroadcastToolbarVideoGroup(
      key: key ?? this.key,
      code: code,
      label: label,
      countryCode: countryCode,
      streams: streams ?? this.streams,
      kind: kind ?? this.kind,
      cameraNumber: cameraNumber ?? this.cameraNumber,
    );
  }
}

String? broadcastStreamPrimaryLanguage(BroadcastVideoStream stream) {
  final value = stream.language ?? stream.publication?.language;
  if (value == null) return null;
  final trimmed = value.trim().toLowerCase();
  if (trimmed.isEmpty) return null;
  return trimmed.split(RegExp('[-_]')).first;
}

bool _isFideYoutubeStream(BroadcastVideoStream stream) {
  return stream.provider == BroadcastVideoProvider.youtube &&
      stream.audience?.channelId == fideYoutubeChannelId;
}

bool _isDesktopWebOnly(BroadcastVideoStream stream) {
  final platforms = stream.platforms;
  return platforms != null &&
      platforms.length == 2 &&
      platforms.contains(BroadcastVideoClientPlatform.web) &&
      platforms.contains(BroadcastVideoClientPlatform.desktop);
}

bool _isFideBoardCamera(BroadcastVideoStream stream) {
  return _isFideYoutubeStream(stream) &&
      _isDesktopWebOnly(stream) &&
      broadcastStreamPrimaryLanguage(stream) == null &&
      _isFideCameraTitle(stream.publication?.title ?? '');
}

int? _explicitCameraNumber(BroadcastVideoStream stream) {
  final match = _fideCameraStream.firstMatch(stream.publication?.title ?? '');
  if (match == null) return null;
  final raw = match.group(1) ?? match.group(4);
  final number = int.tryParse(raw ?? '');
  if (number == null || number <= 0) return null;
  return number;
}

final Map<String, int> _assignedCameraNumbers = <String, int>{};

List<({BroadcastVideoStream stream, int number})> numberedFideCameras(
  List<BroadcastVideoStream> streams,
) {
  final candidates = streams.where(_isFideBoardCamera).toList(growable: false);
  final used = <int>{};
  final numbered = <({BroadcastVideoStream stream, int number})>[];
  for (final stream in candidates) {
    final explicit = _explicitCameraNumber(stream);
    if (explicit == null) continue;
    numbered.add((stream: stream, number: explicit));
    used.add(explicit);
  }
  var next = 1;
  for (final stream in candidates) {
    if (_explicitCameraNumber(stream) != null) continue;
    while (used.contains(next)) {
      next++;
    }
    numbered.add((stream: stream, number: next));
    used.add(next);
    next++;
  }
  numbered.sort((a, b) {
    final byNumber = a.number.compareTo(b.number);
    if (byNumber != 0) return byNumber;
    return a.stream.id.compareTo(b.stream.id);
  });
  _assignedCameraNumbers
    ..clear()
    ..addEntries(
      numbered.map((entry) => MapEntry(entry.stream.id, entry.number)),
    );
  return numbered;
}

int? fideCameraNumber(BroadcastVideoStream stream) {
  if (!_isFideBoardCamera(stream)) return null;
  return _explicitCameraNumber(stream) ?? _assignedCameraNumbers[stream.id];
}

bool isFideMainCommentary(BroadcastVideoStream stream) {
  final title = stream.publication?.title ?? '';
  return _isFideYoutubeStream(stream) &&
      broadcastStreamPrimaryLanguage(stream) == 'en' &&
      _fideOlympiadTitle.hasMatch(title) &&
      !_isFideCameraTitle(title);
}

/// Show every exact stream only while the full set fits. Once it does not,
/// keep every language together so the count badges have one meaning.
/// Explicit local pins remain individual.
List<BroadcastToolbarVideoGroup> progressiveBroadcastStreamGroups(
  List<BroadcastToolbarVideoGroup> groups,
  List<String> pins,
  int capacity,
) {
  final pinned = <String>{};
  final pinnedGroups = <BroadcastToolbarVideoGroup>[];
  for (final id in pins) {
    if (!pinned.add(id)) continue;
    BroadcastToolbarVideoGroup? owner;
    BroadcastVideoStream? stream;
    for (final group in groups) {
      for (final candidate in group.streams) {
        if (candidate.id == id) {
          owner = group;
          stream = candidate;
          break;
        }
      }
      if (stream != null) break;
    }
    if (owner == null || stream == null) continue;
    pinnedGroups.add(
      owner.copyWith(
        key: 'stream:$id',
        streams: <BroadcastVideoStream>[stream],
      ),
    );
  }
  final remaining = <BroadcastToolbarVideoGroup>[];
  for (final group in groups) {
    final leftover = group.streams
        .where((stream) => !pinned.contains(stream.id))
        .toList(growable: false);
    if (leftover.isEmpty) continue;
    remaining.add(group.copyWith(streams: leftover));
  }
  final streamCount = groups.fold<int>(
    0,
    (total, group) => total + group.streams.length,
  );
  if (capacity >= streamCount) {
    return <BroadcastToolbarVideoGroup>[
      ...pinnedGroups,
      for (final group in remaining)
        for (final stream in group.streams)
          group.copyWith(
            key: 'stream:${stream.id}',
            streams: <BroadcastVideoStream>[stream],
          ),
    ];
  }
  return <BroadcastToolbarVideoGroup>[
    ...pinnedGroups,
    for (final group in remaining)
      group.streams.length == 1
          ? group.copyWith(key: 'stream:${group.streams.first.id}')
          : group,
  ];
}

/// Product ordering for the compact in-game toolbar.
List<BroadcastToolbarVideoGroup> toolbarBroadcastVideoGroups(
  List<BroadcastVideoStream> streams,
  List<String> pins,
  int capacity, {
  String? selectedId,
}) {
  final main = streams.where(isFideMainCommentary).toList(growable: false);
  final cameras = numberedFideCameras(streams);
  final specialIds = <String>{
    ...main.map((stream) => stream.id),
    ...cameras.map((entry) => entry.stream.id),
  };
  final base = <BroadcastToolbarVideoGroup>[
    if (main.isNotEmpty)
      BroadcastToolbarVideoGroup(
        key: 'fide',
        code: 'en',
        label: 'FIDE',
        streams: main,
        kind: BroadcastToolbarVideoKind.fide,
      ),
    ...groupBroadcastVideoStreams(
      streams.where((stream) => !specialIds.contains(stream.id)).toList(),
    ).map(
      (group) => BroadcastToolbarVideoGroup(
        key: group.key,
        code: group.code,
        label: group.label,
        countryCode: group.countryCode,
        streams: group.streams,
        kind: BroadcastToolbarVideoKind.language,
      ),
    ),
  ];
  BroadcastVideoStream? selected;
  if (selectedId != null) {
    for (final stream in streams) {
      if (stream.id == selectedId) {
        selected = stream;
        break;
      }
    }
  }
  final selectedLanguage =
      selected == null ? null : broadcastStreamPrimaryLanguage(selected);
  if (selectedLanguage != null && selectedLanguage != 'en') {
    final preferredIndex = base.indexWhere(
      (group) => group.streams.any((stream) => stream.id == selectedId),
    );
    if (preferredIndex > 0) {
      final preferred = base.removeAt(preferredIndex);
      base.insert(0, preferred);
    }
  }
  final cameraById = <String, ({BroadcastVideoStream stream, int number})>{
    for (final entry in cameras) entry.stream.id: entry,
  };
  final pinnedCameras = <BroadcastToolbarVideoGroup>[];
  final seenPins = <String>{};
  for (final id in pins) {
    if (!seenPins.add(id)) continue;
    final entry = cameraById[id];
    if (entry == null) continue;
    pinnedCameras.add(
      BroadcastToolbarVideoGroup(
        key: 'camera:$id',
        code: 'und',
        label: 'Camera ${entry.number}',
        streams: <BroadcastVideoStream>[entry.stream],
        kind: BroadcastToolbarVideoKind.camera,
        cameraNumber: entry.number,
      ),
    );
  }
  final pinnedCameraIds =
      pinnedCameras
          .expand((group) => group.streams.map((stream) => stream.id))
          .toSet();
  final remainingCameras = cameras
      .where((entry) => !pinnedCameraIds.contains(entry.stream.id))
      .toList(growable: false);
  final reserved = pinnedCameras.length + (remainingCameras.isEmpty ? 0 : 1);
  final ordinaryPins = pins
      .where((id) => !cameraById.containsKey(id))
      .toList(growable: false);
  final ordinary = progressiveBroadcastStreamGroups(
    base,
    ordinaryPins,
    capacity < reserved ? 0 : capacity - reserved,
  );
  return <BroadcastToolbarVideoGroup>[
    ...pinnedCameras,
    ...ordinary,
    if (remainingCameras.isNotEmpty)
      BroadcastToolbarVideoGroup(
        key: 'fide-cameras',
        code: 'und',
        label: 'Cameras',
        streams: remainingCameras
            .map((entry) => entry.stream)
            .toList(growable: false),
        kind: BroadcastToolbarVideoKind.cameras,
      ),
  ];
}

String broadcastToolbarStreamName(BroadcastVideoStream stream) {
  final number = fideCameraNumber(stream);
  return number == null
      ? broadcastVideoStreamDisplayName(stream)
      : 'Camera $number';
}
