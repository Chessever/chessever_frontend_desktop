/// A `%…%` ilike pattern for [query], quoted for a PostgREST `or=(…)`
/// filter. Names such as "Carlsen, Magnus" carry commas, which would
/// otherwise split the filter list and make the request fail with 400.
String postgrestIlikeContains(String query) {
  final escaped = query.trim().replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"%$escaped%"';
}
