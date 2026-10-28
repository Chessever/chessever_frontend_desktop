import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/providers/notifications_settings_provider.dart';

/// Desktop never owns the phone's push preference.
///
/// The shared [NotificationsSettingsNotifier] writes
/// `user_notification_preferences.push_enabled` through
/// `PushNotificationsService` from its constructor (it re-syncs the locally
/// stored flag) and from `setEnabled`. Desktop has no push channel, so its
/// local flag is always the default `false`: constructing that notifier on
/// desktop would silently mute every push on the user's phone.
///
/// Mobile screen code that is still in the desktop import graph (for
/// example the phone board screen) reads [notificationsSettingsProvider].
/// Every desktop root container therefore replaces it with this inert
/// notifier, so the writing implementation cannot be built on desktop no
/// matter which code path asks for it. It implements the shared type rather
/// than extending it, because the shared constructor is the write.
class DesktopInertNotificationsSettingsNotifier
    extends StateNotifier<NotificationsSettings>
    implements NotificationsSettingsNotifier {
  DesktopInertNotificationsSettingsNotifier(this.ref)
    : super(const NotificationsSettings(enabled: false));

  @override
  final Ref ref;

  /// Intentionally does nothing. Desktop must not change the phone's push
  /// preference, in either direction.
  @override
  Future<void> setEnabled(bool enabled) async {}
}

/// Overrides every desktop root `ProviderContainer` must install.
final List<Override> desktopPushIsolationOverrides = <Override>[
  notificationsSettingsProvider.overrideWith(
    (ref) => DesktopInertNotificationsSettingsNotifier(ref),
  ),
];
