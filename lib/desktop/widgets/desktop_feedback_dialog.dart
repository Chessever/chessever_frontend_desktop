import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/services/telegram_notification_service.dart';
import 'package:chessever/theme/app_theme.dart';

class DesktopFeedbackDialog extends StatefulWidget {
  const DesktopFeedbackDialog({super.key, required this.screenshotKey});

  final GlobalKey screenshotKey;

  static Future<void> show(
    BuildContext context, {
    required GlobalKey screenshotKey,
  }) {
    return showDesktopModal<void>(
      context,
      title: 'Feedback / Report issue',
      maxWidth: 620,
      maxHeight: 760,
      builder: (_) => DesktopFeedbackDialog(screenshotKey: screenshotKey),
    );
  }

  @override
  State<DesktopFeedbackDialog> createState() => _DesktopFeedbackDialogState();
}

class _DesktopFeedbackDialogState extends State<DesktopFeedbackDialog> {
  final TextEditingController _messageController = TextEditingController();
  bool _includeScreenshot = true;
  bool _submitting = false;
  Uint8List? _previewBytes;
  String? _errorMessage;

  bool get _canSubmit => _messageController.text.trim().isNotEmpty;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<Uint8List?> _captureScreenshot() async {
    final context = widget.screenshotKey.currentContext;
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return null;

    final image = await renderObject.toImage(pixelRatio: 1.5);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<void> _previewScreenshot() async {
    setState(() {
      _errorMessage = null;
    });
    try {
      final bytes = await _captureScreenshot();
      if (!mounted) return;
      if (bytes == null) {
        setState(() => _errorMessage = 'Screenshot preview is unavailable.');
        return;
      }
      setState(() => _previewBytes = bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Screenshot preview failed.');
    }
  }

  Future<void> _submit() async {
    if (!_canSubmit || _submitting) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final screenshotBytes =
          _includeScreenshot
              ? (_previewBytes ?? await _captureScreenshot())
              : null;
      final packageInfo = await PackageInfo.fromPlatform();
      final supabase = Supabase.instance.client;
      final userId = supabase.auth.currentUser?.id;
      final feedback = desktopFeedbackMessageWithMetadata(
        message: _messageController.text.trim(),
        screenshotIncluded: screenshotBytes != null,
      );

      if (userId != null) {
        await supabase.from('app_feedback').insert({
          'user_id': userId,
          // app_feedback currently requires a 1-5 rating; desktop reports are
          // issue-first, so store a neutral rating and distinguish by source.
          'rating': 3,
          'feedback': feedback,
          'source': 'desktop_report_issue',
          'app_version': packageInfo.version,
          'build_number': packageInfo.buildNumber,
          'platform': Platform.operatingSystem,
        });
      }

      final telegramSent = await TelegramNotificationService.instance
          .sendFeedbackNotification(
        rating: 0,
        feedback: feedback,
        source: 'desktop_report_issue',
        userId: userId,
        appVersion: '${packageInfo.version} (${packageInfo.buildNumber})',
        platform: Platform.operatingSystem,
        screenshotBytes: screenshotBytes,
      );

      if (!mounted) return;
      if (!telegramSent) {
        setState(() {
          _submitting = false;
          _errorMessage =
              'Could not send the report. Please check your connection and try again.';
        });
        return;
      }
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Thanks — your report was sent.'),
          backgroundColor: kBlack2Color.withValues(alpha: 0.95),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = 'Could not send the report. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Tell us what happened',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Reports include app version and platform. Screenshots are optional and capture only the ChessEver desktop window content, not your OS toolbar or other apps.',
            style: TextStyle(color: kWhiteColor70, fontSize: 13, height: 1.35),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _messageController,
            autofocus: true,
            minLines: 5,
            maxLines: 8,
            maxLength: 1200,
            style: const TextStyle(color: kWhiteColor, fontSize: 14),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText:
                  'Describe the issue, what you expected, and what you were doing…',
              hintStyle: const TextStyle(color: kLightGreyColor),
              filled: true,
              fillColor: kBlack3Color,
              counterStyle: const TextStyle(color: kLightGreyColor),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: kDividerColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: kDividerColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: kPrimaryColor),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _ScreenshotOption(
            selected: _includeScreenshot,
            hasPreview: _previewBytes != null,
            onChanged: (value) {
              setState(() {
                _includeScreenshot = value;
                if (!value) _previewBytes = null;
              });
            },
            onPreview: _includeScreenshot ? _previewScreenshot : null,
          ),
          if (_previewBytes != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  border: Border.all(color: kDividerColor),
                  color: kBlack3Color,
                ),
                child: Image.memory(
                  _previewBytes!,
                  fit: BoxFit.contain,
                  width: double.infinity,
                ),
              ),
            ),
          ],
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: const TextStyle(color: kRedColor, fontSize: 13),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              DesktopDialogButton(
                label: 'Cancel',
                onPress: _submitting ? null : () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 10),
              DesktopDialogButton(
                label: _submitting ? 'Sending…' : 'Send report',
                tone: DesktopDialogButtonTone.primary,
                onPress: _canSubmit && !_submitting ? _submit : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
String desktopFeedbackMessageWithMetadata({
  required String message,
  required bool screenshotIncluded,
}) {
  return [
    'Feedback: ${message.trim()}',
    'Screenshot: ${screenshotIncluded ? 'included' : 'not included'}',
  ].join('\n\n');
}

class _ScreenshotOption extends StatelessWidget {
  const _ScreenshotOption({
    required this.selected,
    required this.hasPreview,
    required this.onChanged,
    required this.onPreview,
  });

  final bool selected;
  final bool hasPreview;
  final ValueChanged<bool> onChanged;
  final Future<void> Function()? onPreview;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        children: [
          Checkbox(
            value: selected,
            onChanged: (value) => onChanged(value ?? false),
            activeColor: kPrimaryColor,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Include screenshot',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Captures only the ChessEver desktop content behind this dialog.',
                  style: TextStyle(color: kLightGreyColor, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          DesktopDialogButton(
            label: hasPreview ? 'Refresh preview' : 'Preview',
            onPress: onPreview == null ? null : () => unawaited(onPreview!()),
          ),
        ],
      ),
    );
  }
}
