import 'package:flutter/foundation.dart';
import 'package:chessever/services/feedback_relay.dart';

/// Sends feedback through the server relay. No bot credential is shipped.
class TelegramNotificationService {
  TelegramNotificationService({FeedbackRelay? relay})
    : _relay = relay ?? FeedbackRelay();
  static final TelegramNotificationService instance =
      TelegramNotificationService();
  final FeedbackRelay _relay;

  Future<bool> sendFeedbackNotification({
    required int rating,
    required String feedback,
    required String source,
    String? userId,
    String? appVersion,
    String? platform,
    Uint8List? screenshotBytes,
  }) {
    final safeRating = rating.clamp(0, 5);
    final message =
        StringBuffer()
          ..writeln('New App Feedback')
          ..writeln(
            safeRating > 0 ? 'Rating: $safeRating/5' : 'Desktop issue report',
          )
          ..writeln('Source: $source')
          ..writeln('Platform: ${platform ?? 'Unknown'}')
          ..writeln('Version: ${appVersion ?? 'Unknown'}')
          ..writeln('User ID: ${userId ?? 'Anonymous'}')
          ..writeln()
          ..writeln(feedback);
    return _relay.send(message.toString(), picture: screenshotBytes);
  }
}
