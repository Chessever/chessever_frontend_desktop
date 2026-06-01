import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Query handed off from the global top-bar search/command palette to the
/// Tournaments discovery pane. A non-null value means the pane should show the
/// broad search-results view for that query instead of the For You/Current/Past
/// discovery grids.
final desktopGlobalSearchQueryProvider = StateProvider<String?>((ref) => null);
