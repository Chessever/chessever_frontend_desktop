import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Service to send notifications to Telegram bot for immediate feedback alerts
class TelegramNotificationService {
  TelegramNotificationService._();

  static final TelegramNotificationService instance =
      TelegramNotificationService._();

  static const String _botToken =
      '8291528959:AAFHFRv_bkksbJ_BKnFf0627ghBcAbyXPgI';

  // Private group chat ID (prefix -100 + group ID from URL)
  static const String _chatId = '-1003335110907';

  static const String _baseUrl = 'https://api.telegram.org/bot';

  /// Send feedback notification to Telegram
  Future<bool> sendFeedbackNotification({
    required int rating,
    required String feedback,
    required String source,
    String? userId,
    String? appVersion,
    String? platform,
    Uint8List? screenshotBytes,
  }) async {
    if (_botToken == 'YOUR_BOT_TOKEN_HERE' || _chatId == 'YOUR_CHAT_ID_HERE') {
      debugPrint('[Telegram] Bot token or chat ID not configured');
      return false;
    }

    try {
      final stars =
          rating > 0
              ? '${'⭐' * rating}${'☆' * (5 - rating)} ($rating/5)'
              : 'Desktop issue report';
      final message =
          StringBuffer()
            ..writeln('📣 *New App Feedback*')
            ..writeln()
            ..writeln(stars)
            ..writeln()
            ..writeln('*Source:* $source')
            ..writeln('*Platform:* ${platform ?? 'Unknown'}')
            ..writeln('*Version:* ${appVersion ?? 'Unknown'}')
            ..writeln()
            ..writeln('*Message:*')
            ..writeln(feedback)
            ..writeln()
            ..writeln('---')
            ..writeln('_User ID: ${userId ?? 'Anonymous'}_');

      final url = Uri.parse('$_baseUrl$_botToken/sendMessage');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chat_id': _chatId,
          'message_thread_id': 19,
          'text': message.toString(),
          'parse_mode': 'Markdown',
        }),
      );

      if (response.statusCode != 200) {
        debugPrint('[Telegram] Failed to send notification: ${response.body}');
        return false;
      }
      if (screenshotBytes != null && screenshotBytes.isNotEmpty) {
        final photoUrl = Uri.parse('$_baseUrl$_botToken/sendPhoto');
        final request =
            http.MultipartRequest('POST', photoUrl)
              ..fields['chat_id'] = _chatId
              ..fields['message_thread_id'] = '19'
              ..fields['caption'] = 'Desktop report screenshot'
              ..files.add(
                http.MultipartFile.fromBytes(
                  'photo',
                  screenshotBytes,
                  filename: 'chessever-desktop-report.png',
                ),
              );
        final photoResponse = await request.send();
        if (photoResponse.statusCode != 200) {
          debugPrint(
            '[Telegram] Failed to send screenshot: ${photoResponse.statusCode}',
          );
          return false;
        }
      }
      debugPrint('[Telegram] Feedback notification sent successfully');
      return true;
    } catch (e) {
      debugPrint('[Telegram] Error sending notification: $e');
      return false;
    }
  }
}
