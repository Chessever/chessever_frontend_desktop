import 'table_display_value.dart';

/// Local PGN player tags may be study labels, not personal names. Preserve
/// their spelling instead of guessing surnames/initials. Both database views
/// use this presentation-only policy; unknown sides stay explicit and opening
/// metadata never replaces a player column.
String databaseGamePlayerLabel(
  Object? raw,
  String side, {
  bool showUnknown = true,
}) {
  final value = desktopTablePlayerValue(raw);
  return value.isNotEmpty ? value : (showUnknown ? '$side ?' : '');
}
