import 'package:flutter/foundation.dart';

enum PlayerDownloadTimeControl {
  ultrabullet('UltraBullet'),
  bullet('Bullet'),
  blitz('Blitz'),
  rapid('Rapid'),
  classical('Classical'),
  correspondence('Correspondence');

  const PlayerDownloadTimeControl(this.label);
  final String label;
}

/// Empty time controls means all games, including games with an unknown clock.
/// Dates are calendar dates in UTC, matching the providers' PGN date tags.
@immutable
class PlayerDownloadPreferences {
  const PlayerDownloadPreferences({
    this.timeControls = const {},
    this.fromDate,
    this.toDate,
  });

  final Set<PlayerDownloadTimeControl> timeControls;
  final DateTime? fromDate;
  final DateTime? toDate;

  bool get isFiltered =>
      timeControls.isNotEmpty || fromDate != null || toDate != null;

  int? get fromMs => _calendarDate(fromDate)?.millisecondsSinceEpoch;
  int? get untilMs =>
      _calendarDate(
        toDate,
      )?.add(const Duration(days: 1)).millisecondsSinceEpoch;

  String? get validationError {
    if (fromMs != null && untilMs != null && fromMs! >= untilMs!) {
      return 'The end date must be on or after the starting date.';
    }
    return null;
  }

  String get summary => describe();

  String describe({bool dailyCorrespondence = false}) {
    final clocks =
        timeControls.isEmpty
            ? 'All time controls'
            : PlayerDownloadTimeControl.values
                .where(timeControls.contains)
                .map(
                  (value) =>
                      dailyCorrespondence &&
                              value == PlayerDownloadTimeControl.correspondence
                          ? 'Daily'
                          : value.label,
                )
                .join(', ');
    final dates = switch ((fromDate, toDate)) {
      (null, null) => 'All dates',
      (final from?, null) => 'From ${_dateText(from)}',
      (null, final to?) => 'Through ${_dateText(to)}',
      (final from?, final to?) => '${_dateText(from)} to ${_dateText(to)}',
    };
    return '$clocks · $dates';
  }

  Map<String, Object?> toJson() => {
    'timeControls': PlayerDownloadTimeControl.values
        .where(timeControls.contains)
        .map((value) => value.name)
        .toList(growable: false),
    'fromDate': fromDate == null ? null : _dateText(fromDate!),
    'toDate': toDate == null ? null : _dateText(toDate!),
  };

  static PlayerDownloadPreferences fromJson(Object? raw) {
    if (raw is! Map) return const PlayerDownloadPreferences();
    final clocks = raw['timeControls'];
    return PlayerDownloadPreferences(
      timeControls: Set.unmodifiable(
        PlayerDownloadTimeControl.values.where(
          (value) => clocks is List && clocks.contains(value.name),
        ),
      ),
      fromDate: _parseDate(raw['fromDate']),
      toDate: _parseDate(raw['toDate']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerDownloadPreferences &&
      setEquals(timeControls, other.timeControls) &&
      fromMs == other.fromMs &&
      untilMs == other.untilMs;

  @override
  int get hashCode =>
      Object.hash(Object.hashAllUnordered(timeControls), fromMs, untilMs);
}

DateTime? _calendarDate(DateTime? value) =>
    value == null ? null : DateTime.utc(value.year, value.month, value.day);

String _dateText(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DateTime? _parseDate(Object? raw) {
  final value = raw?.toString();
  if (value == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }
  final parsed = DateTime.tryParse('${value}T00:00:00Z');
  return parsed != null && _dateText(parsed) == value ? parsed : null;
}
