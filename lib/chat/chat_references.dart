// Pure chat helpers shared by every Botvinnik surface.
//
// Lifted from the phone app's `chat_screen.dart` so the desktop pane and the
// tests read one implementation instead of copies. Nothing in here touches
// widgets, providers or the network.

import 'package:chessever/chat/chat_api.dart';

/// Only `https` links with a host are ever launched from an answer.
Uri? safeChatSourceUri(String? href) {
  if (href == null) return null;
  final uri = Uri.tryParse(href.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri;
}

/// Composer gate. The three non-enabled states carry different copy and a
/// different action, so they must never collapse into one.
enum ChatComposerAccess { signedOut, enabled, upgradeRequired, exhausted }

ChatComposerAccess chatComposerAccess({
  required bool isSignedIn,
  required ChatQuotaStatus? quota,
}) {
  if (!isSignedIn) return ChatComposerAccess.signedOut;
  if (quota != null && quota.remaining <= 0) {
    if (!quota.isPremium && quota.limit <= 0) {
      return ChatComposerAccess.upgradeRequired;
    }
    return ChatComposerAccess.exhausted;
  }
  return ChatComposerAccess.enabled;
}

ChatConversation chatConversationForOpen(
  List<ChatConversation> conversations,
  String? preferredId,
) {
  if (preferredId != null) {
    for (final conversation in conversations) {
      if (conversation.id == preferredId) return conversation;
    }
  }
  return conversations.first;
}

/// Maximum characters accepted by the composer, matching the phone app.
const int kChatComposerMaxLength = 2000;

/// Outcome of comparing an interrupted send against persisted history.
enum ChatReconcileOutcome {
  /// The server already stored the question. Adopt its history, never resend.
  alreadyDelivered,

  /// The server has no trace of the question. Sending it is safe.
  notDelivered,
}

/// Decides whether [pendingContent] reached the server.
///
/// Closing the client can leave generation running server-side, so before a
/// retry the caller fetches `GET .../messages` and asks this function. A
/// question is considered delivered when a persisted user message with the
/// same trimmed text appears after the last persisted message the client
/// already knew about ([knownMessageIds]).
ChatReconcileOutcome chatReconcilePendingSend({
  required List<ChatMessage> serverMessages,
  required String pendingContent,
  Set<String> knownMessageIds = const <String>{},
}) {
  final pending = pendingContent.trim();
  if (pending.isEmpty) return ChatReconcileOutcome.alreadyDelivered;
  var start = 0;
  for (var index = serverMessages.length - 1; index >= 0; index--) {
    if (knownMessageIds.contains(serverMessages[index].id)) {
      start = index + 1;
      break;
    }
  }
  for (var index = start; index < serverMessages.length; index++) {
    final message = serverMessages[index];
    if (message.role == 'user' && message.content.trim() == pending) {
      return ChatReconcileOutcome.alreadyDelivered;
    }
  }
  return ChatReconcileOutcome.notDelivered;
}

final RegExp _chatOpeningCodePattern = RegExp(r'^[A-E][0-9]{2}$');

/// The canonical form of an opening reference id: trimmed and upper case,
/// matching mobile, which normalizes before it validates.
String normalizeChatOpeningReferenceId(String id) => id.trim().toUpperCase();

/// Opening references are only routable for an ECO volume code such as `B14`.
/// Case and surrounding whitespace are normalized first, so `b14` routes too.
bool isChatOpeningReferenceId(String id) =>
    _chatOpeningCodePattern.hasMatch(normalizeChatOpeningReferenceId(id));

String normalizeChatMarkdown(String source) {
  final breakTag = RegExp(r'<br\s*/?>', caseSensitive: false);
  return source
      .split('\n')
      .map((line) {
        if (!breakTag.hasMatch(line)) return line;
        final trimmed = line.trim();
        final isTableRow = trimmed.startsWith('|') && trimmed.endsWith('|');
        return line.replaceAll(breakTag, isTableRow ? '; ' : '\n');
      })
      .join('\n');
}

class IntegratedChatReferences {
  const IntegratedChatReferences({
    required this.markdown,
    required this.linkedReferences,
  });

  final String markdown;
  final List<ChatReference> linkedReferences;
}

List<(int, int)> _markdownProtectedRanges(String source) {
  final patterns = [
    RegExp(r'```[\s\S]*?```'),
    RegExp(r'`[^`\n]*`'),
    RegExp(r'!?\[[^\]]*\]\([^\n)]*\)'),
  ];
  return [
    for (final pattern in patterns)
      for (final match in pattern.allMatches(source)) (match.start, match.end),
  ];
}

String chatReferenceHref(ChatReference reference) =>
    Uri(
      scheme: 'chessever',
      host: 'reference',
      queryParameters: {'type': reference.type, 'id': reference.id},
    ).toString();

ChatReference? chatReferenceForHref(
  String? href,
  List<ChatReference> references,
) {
  if (href == null) return null;
  final uri = Uri.tryParse(href);
  if (uri == null || uri.scheme != 'chessever' || uri.host != 'reference') {
    return null;
  }
  final type = uri.queryParameters['type'];
  final id = uri.queryParameters['id'];
  for (final reference in references) {
    if (reference.type == type && reference.id == id) return reference;
  }
  return null;
}

List<String> _chatReferenceAliases(ChatReference reference) {
  final label = reference.label.trim();
  final aliases = <String>{if (label.isNotEmpty) label};
  if (reference.type == 'player' && label.contains(',')) {
    final parts = label.split(',').map((part) => part.trim()).toList();
    final familyName = parts.removeAt(0);
    if (familyName.isNotEmpty &&
        parts.isNotEmpty &&
        parts.every((part) => part.isNotEmpty)) {
      aliases.add('${parts.join(' ')} $familyName');
      aliases.add('$familyName ${parts.join(' ')}');
    }
  }
  if (reference.type == 'game') {
    final players = label.split(
      RegExp(r'\s+(?:vs\.?|[-–—])\s+', caseSensitive: false),
    );
    if (players.length == 2 && players.every((player) => player.isNotEmpty)) {
      for (final separator in [' vs ', ' - ', ' – ', ' — ']) {
        aliases.add('${players[0]}$separator${players[1]}');
      }
    }
  }
  return aliases.toList()
    ..sort((left, right) => right.length.compareTo(left.length));
}

const _chatReferenceApostrophes = "'’ʼ";
const _chatReferenceHyphens = '-‐‑‒–—';
const _chatReferenceLatinVariants = <String, String>{
  'a': 'aàáâãäåāăąǎ',
  'c': 'cçćĉċč',
  'd': 'dďđ',
  'e': 'eèéêëēĕėęě',
  'g': 'gĝğġģ',
  'h': 'hĥħ',
  'i': 'iìíîïĩīĭįı',
  'j': 'jĵ',
  'k': 'kķ',
  'l': 'lĺļľŀł',
  'n': 'nñńņňŋ',
  'o': 'oòóôõöøōŏőǒ',
  'r': 'rŕŗř',
  's': 'sśŝşšș',
  't': 'tţťŧț',
  'u': 'uùúûüũūŭůűųǔ',
  'w': 'wŵ',
  'y': 'yýÿŷ',
  'z': 'zźżž',
};
final _chatReferenceWordCharacter = RegExp(r'[A-Za-z0-9À-ÖØ-öø-ÿĀ-ž]');

bool _isChatReferenceWordCharacter(String character) =>
    _chatReferenceWordCharacter.hasMatch(character);

bool _isChatReferenceUppercaseInitial(String character) =>
    _isChatReferenceWordCharacter(character) &&
    character.toUpperCase() == character &&
    character.toLowerCase() != character;

String _chatReferenceLetterPattern(String character) {
  final lower = character.toLowerCase();
  for (final entry in _chatReferenceLatinVariants.entries) {
    if (entry.value.contains(lower)) return '[${entry.value}]';
  }
  return RegExp.escape(character);
}

String _chatReferenceAliasPattern(String alias) {
  final characters = alias.split('');
  final pattern = StringBuffer();
  for (var index = 0; index < characters.length; index++) {
    final character = characters[index];
    if (_chatReferenceApostrophes.contains(character)) continue;
    if (RegExp(r'\s').hasMatch(character) ||
        _chatReferenceHyphens.contains(character)) {
      while (index + 1 < characters.length &&
          (RegExp(r'\s').hasMatch(characters[index + 1]) ||
              _chatReferenceHyphens.contains(characters[index + 1]))) {
        index++;
      }
      pattern.write(r'(?:[\s ]+|[\s ]*[-‐‑‒–—][\s ]*)');
      continue;
    }
    if (character == '.') {
      pattern.write(r'\.?');
      continue;
    }
    pattern.write(_chatReferenceLetterPattern(character));
    if (_isChatReferenceWordCharacter(character)) {
      pattern.write(r'[̀-ͯ]*');
    }
    var nextIndex = index + 1;
    while (nextIndex < characters.length &&
        _chatReferenceApostrophes.contains(characters[nextIndex])) {
      nextIndex++;
    }
    if (nextIndex < characters.length &&
        _isChatReferenceWordCharacter(character) &&
        _isChatReferenceWordCharacter(characters[nextIndex])) {
      if (_isChatReferenceUppercaseInitial(character) &&
          _isChatReferenceUppercaseInitial(characters[nextIndex])) {
        pattern.write(r"[.'’ʼ\s ]*");
      } else {
        pattern.write(r"['’ʼ]?");
      }
    }
  }
  return pattern.toString();
}

bool _hasChatReferenceWordBoundaries(String source, RegExpMatch match) {
  final startsWithWord = _isChatReferenceWordCharacter(match.group(0)![0]);
  final endsWithWord = _isChatReferenceWordCharacter(
    match.group(0)![match.group(0)!.length - 1],
  );
  if (startsWithWord &&
      match.start > 0 &&
      _isChatReferenceWordCharacter(source[match.start - 1])) {
    return false;
  }
  if (endsWithWord &&
      match.end < source.length &&
      _isChatReferenceWordCharacter(source[match.end])) {
    return false;
  }
  return true;
}

/// Turns every mention of a reference label in [source] into a
/// `chessever://reference` Markdown link. Callers pass only the references
/// they can actually open, so an unroutable mention stays plain text.
IntegratedChatReferences integrateChatReferences(
  String source,
  List<ChatReference> references,
) {
  var markdown = source;
  final linked = <ChatReference>[];
  final unique = <String, ChatReference>{};
  for (final reference in references) {
    unique.putIfAbsent('${reference.type}:${reference.id}', () => reference);
  }
  final candidates =
      unique.values.toList()..sort(
        (left, right) => right.label.length.compareTo(left.label.length),
      );

  for (final reference in candidates) {
    var linkedReference = false;
    while (true) {
      final protected = _markdownProtectedRanges(markdown);
      RegExpMatch? selected;
      for (final alias in _chatReferenceAliases(reference)) {
        final matcher = RegExp(
          _chatReferenceAliasPattern(alias),
          caseSensitive: false,
        );
        for (final match in matcher.allMatches(markdown)) {
          final overlaps = protected.any(
            (range) => match.start < range.$2 && match.end > range.$1,
          );
          if (!overlaps &&
              _hasChatReferenceWordBoundaries(markdown, match) &&
              (selected == null || match.start < selected.start)) {
            selected = match;
          }
        }
      }
      if (selected == null) break;
      final matchedLabel = selected.group(0)!;
      final escapedLabel = matchedLabel.replaceAllMapped(
        RegExp(r'[\\\[\]]'),
        (match) => '\\${match.group(0)}',
      );
      markdown = markdown.replaceRange(
        selected.start,
        selected.end,
        '[$escapedLabel](${chatReferenceHref(reference)})',
      );
      linkedReference = true;
    }
    if (linkedReference) linked.add(reference);
  }

  return IntegratedChatReferences(markdown: markdown, linkedReferences: linked);
}

List<List<ChatReference>> structureChatReferences(
  List<ChatReference> references,
) {
  final visible = references.toList();
  if (visible.isEmpty) return const [];

  final consumed = <int>{};
  final groups = <List<ChatReference>>[];
  for (var index = 0; index < visible.length; index++) {
    final tournament = visible[index];
    if (tournament.type != 'tournament') continue;
    consumed.add(index);
    final group = <ChatReference>[tournament];
    for (var gameIndex = 0; gameIndex < visible.length; gameIndex++) {
      final game = visible[gameIndex];
      if (game.type == 'game' && game.tourId == tournament.id) {
        group.add(game);
        consumed.add(gameIndex);
      }
    }
    groups.add(group);
  }

  final pending = <ChatReference>[];
  for (var index = 0; index < visible.length; index++) {
    if (!consumed.contains(index)) pending.add(visible[index]);
  }
  if (pending.isNotEmpty) groups.add(pending);
  return groups;
}

class ChatSuggestion {
  const ChatSuggestion({required this.label, required this.prompt});

  final String label;
  final String prompt;
}

List<ChatSuggestion> chatSuggestionsForScreen(String? screen) {
  if (screen == 'tournament' || screen == 'event') {
    return const [
      ChatSuggestion(
        label: 'Tournament overview',
        prompt:
            'Give me an overview of this tournament and explain its format.',
      ),
      ChatSuggestion(
        label: 'Schedule and rounds',
        prompt: 'Show the schedule and rounds for this tournament.',
      ),
      ChatSuggestion(
        label: 'Current standings',
        prompt: 'Show the current standings for this tournament.',
      ),
    ];
  }
  if (screen == 'player') {
    return const [
      ChatSuggestion(
        label: 'Recent form',
        prompt: 'How has this player been doing in recent events?',
      ),
      ChatSuggestion(
        label: 'Upcoming events',
        prompt: 'Which events is this player playing next?',
      ),
      ChatSuggestion(
        label: 'Notable games',
        prompt: "Show this player's most recent notable games.",
      ),
    ];
  }
  return const [
    ChatSuggestion(
      label: 'Live games',
      prompt: 'Which games are live right now?',
    ),
    ChatSuggestion(
      label: 'Recent events',
      prompt: 'Which events were played last month?',
    ),
    ChatSuggestion(
      label: 'Tournament format',
      prompt: 'Explain the format of the latest tournament.',
    ),
  ];
}
