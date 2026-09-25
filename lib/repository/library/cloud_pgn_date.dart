import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

/// Cloud-safety rule for the PGN `Date` header.
///
/// A saved analysis reaches the cloud as one JSONB payload
/// (`user_saved_analyses.chess_game`), and the server derives its `game_date`
/// date column from that payload's `Date` tag. A value that *looks* like a PGN
/// date but is not a real calendar date is handed to a date parser there and
/// aborts the whole request:
///
///     Save failed: Database error: date/time field value out of range:
///     "2005.06.31"
///
/// June has 30 days, so `2005.06.31` (present in a user's imported PGN) killed
/// a 2 695-game database save: the batch insert that contained it was rejected
/// as a whole, and the destination database — created before the first row, on
/// purpose — was left behind empty, which then refused every retry by name.
///
/// The rule applies to the **cloud payload only**. The local PGN file, the
/// local index and every table/Board display keep the value they were imported
/// with: this is a write-boundary normalization, not a repair of user data.

/// PGN's "date unknown" sentinel — what a cloud row carries when its source
/// date cannot be a date at all.
const String kCloudUnknownPgnDate = '????.??.??';

/// True when [value] is a real `YYYY.MM.DD` calendar date.
///
/// Everything else must not reach a date parser: the `????.??.??`,
/// `YYYY.??.??` and `YYYY.MM.??` placeholders, `0000.00.00`, a day of `00` or
/// `32`, a month of `00` or `13`, and any day the month does not have — the
/// leap-year rule included (`2004.02.29` is a date, `2005.02.29` and
/// `2005.06.31` are not).
bool isCloudSafePgnDate(String? value) {
  final raw = value?.trim() ?? '';
  final match = RegExp(r'^(\d{4})\.(\d{2})\.(\d{2})$').firstMatch(raw);
  if (match == null) return false;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (year < 1 || month < 1 || month > 12) return false;
  return day >= 1 && day <= _pgnDaysInMonth(year, month);
}

/// The `Date` value a cloud write may carry.
///
/// A real calendar date is sent unchanged; anything else becomes the PGN
/// unknown-date sentinel, which the server already reads as "no date" (the
/// same NULL `game_date` an unknown-date game has always produced). The game
/// itself is never dropped and no other header is touched — only its unusable
/// date is.
String cloudSafePgnDate(String? value) =>
    isCloudSafePgnDate(value) ? value!.trim() : kCloudUnknownPgnDate;

/// [game] serialized for a cloud write, with a cloud-safe `Date` tag.
///
/// The [ChessGame] is never modified: only the returned JSON's metadata map is
/// copied and rewritten, so the caller's local record — and anything the user
/// sees in a table or on the Board — keeps its imported value. A game with no
/// `Date` tag keeps it absent; the server already reads that as "no date", and
/// none of its other headers are touched.
Map<String, dynamic> cloudSafeChessGameJson(ChessGame game) {
  final json = game.toJson();
  final metadata = json['md'];
  if (metadata is! Map || !metadata.containsKey('Date')) return json;
  if (isCloudSafePgnDate(metadata['Date']?.toString())) return json;
  final safeMetadata = Map<String, dynamic>.from(metadata);
  safeMetadata['Date'] = kCloudUnknownPgnDate;
  json['md'] = safeMetadata;
  return json;
}

int _pgnDaysInMonth(int year, int month) {
  const lengths = <int>[31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month == 2 && _isLeapYear(year)) return 29;
  return lengths[month - 1];
}

bool _isLeapYear(int year) =>
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
