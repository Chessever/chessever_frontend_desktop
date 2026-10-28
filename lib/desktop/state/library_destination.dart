import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A repeated explicit request selects the destination in an open Library.
final libraryDestinationRequestProvider = StateProvider<(int, String)?>(
  (_) => null,
);
