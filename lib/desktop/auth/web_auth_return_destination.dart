/// Keep only application navigation state, never OAuth codes/tokens, fragments
/// or a cross-origin destination. A stored value is a same-origin path only.
String? safeWebAuthReturnDestination(Uri uri) {
  final path = uri.path;
  if (!path.startsWith('/') || path.startsWith('//') || path.contains('\\')) {
    return null;
  }
  if (uri.userInfo.isNotEmpty || (!uri.hasScheme && uri.hasAuthority)) {
    return null;
  }
  if (uri.hasScheme && uri.scheme != 'https' && uri.scheme != 'http') {
    return null;
  }
  const allowed = {
    'collection',
    'color',
    'date',
    'editor',
    'explorer',
    'fen',
    'flip',
    'mode',
    'month',
    'period',
    'ply',
    'pov',
    'q',
    'search',
    'section',
    'tab',
  };
  final query = {
    for (final entry in uri.queryParametersAll.entries)
      if (allowed.contains(entry.key)) entry.key: entry.value,
  };
  return Uri(
    path: path,
    queryParameters: query.isEmpty ? null : query,
  ).toString();
}
