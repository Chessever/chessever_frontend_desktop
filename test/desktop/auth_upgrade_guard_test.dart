import 'package:chessever/widgets/auth/auth_upgrade_sheet.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Guests are ordinary free accounts (mobile parity). The guard used to show
  // a sheet whose sign-in button pushed an unregistered `/auth_screen` route,
  // leaving every guarded desktop action dead for guests.
  testWidgets('requireFullAuthGuard never blocks a guest or free user', (
    tester,
  ) async {
    late BuildContext captured;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    );

    expect(await requireFullAuthGuard(captured), isTrue);
  });
}
