import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chessever/desktop/widgets/desktop_access_gate.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';

Future<bool> canCreateDesktopCloudDatabase(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final client = Supabase.instance.client;
  final account = client.auth.currentUser?.id;
  if (account == null) return false;
  if (container.read(desktopPremiumAccessProvider) == DesktopAccess.allowed) {
    return true;
  }
  try {
    final count = await client
        .from('user_folders')
        .count(CountOption.exact)
        .eq('user_id', account)
        .or('node_type.eq.database,node_type.is.null');
    if (!context.mounted || client.auth.currentUser?.id != account) {
      return false;
    }
    if (count < desktopFreeCloudDatabases) return true;
    return requireDesktopPremium(
      context,
      feature: 'More than 3 cloud databases',
    );
  } catch (_) {
    if (context.mounted) {
      showDesktopToast(
        context,
        'Could not verify your database count. Retry.',
        error: true,
      );
    }
    return false;
  }
}
