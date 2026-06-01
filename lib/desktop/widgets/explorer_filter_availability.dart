import 'package:flutter/material.dart';

const wholeDatabaseFiltersComingSoonMessage =
    'Whole Database filters are coming soon.';

bool explorerFiltersAvailableForScope(Object? scopedPlayer) =>
    scopedPlayer != null;

void showWholeDatabaseFiltersComingSoon(BuildContext context) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text(wholeDatabaseFiltersComingSoonMessage),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
}
