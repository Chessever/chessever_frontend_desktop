import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chessever/chat/ai_sharing_consent.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/theme/app_theme.dart';

Future<bool> showBotvinnikAiConsent(BuildContext context) async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null || user.isAnonymous) return false;
  return await showDesktopModal<bool>(
        context,
        title: 'AI data sharing',
        builder: (_) => BotvinnikAiConsentDialog(accountId: user.id),
      ) ==
      true;
}

class BotvinnikAiConsentDialog extends StatefulWidget {
  const BotvinnikAiConsentDialog({
    super.key,
    required this.accountId,
    this.saveChoice,
  });
  final String accountId;
  final Future<void> Function(bool)? saveChoice;

  @override
  State<BotvinnikAiConsentDialog> createState() =>
      _BotvinnikAiConsentDialogState();
}

class _BotvinnikAiConsentDialogState extends State<BotvinnikAiConsentDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _save(bool allowed) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.saveChoice != null) {
        await widget.saveChoice!(allowed);
      } else {
        if (Supabase.instance.client.auth.currentUser?.id != widget.accountId) {
          throw StateError('Your account changed.');
        }
        await AiSharingConsent.instance.setGranted(widget.accountId, allowed);
        if (Supabase.instance.client.auth.currentUser?.id != widget.accountId) {
          await AiSharingConsent.instance.setGranted(widget.accountId, false);
          throw StateError('Your account changed.');
        }
      }
      if (mounted) Navigator.of(context).pop(allowed);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Your choice could not be saved. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Allow Botvinnik to share your questions with AI services?',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'ChessEver sends your messages, recent conversation history and attached chess screen context to Cloudflare Workers AI. Requests also include language, timezone, platform and app version. Questions may contain personal information you type.',
            style: TextStyle(color: kWhiteColor70, height: 1.5),
          ),
          const SizedBox(height: 12),
          const Text(
            'For research, search terms derived from your questions and source URLs may be sent to TinyFish. ChessEver saves conversations with your account and may save research evidence for later answers. Avoid sharing sensitive information.',
            style: TextStyle(color: kWhiteColor70, height: 1.5),
          ),
          const SizedBox(height: 12),
          const Text(
            'Using AI is optional. You can stop future sharing in Settings > Botvinnik > AI data sharing. Stopping sharing does not delete saved chats.',
            style: TextStyle(color: kWhiteColor70, height: 1.5),
          ),
          const SizedBox(height: 12),
          DesktopDialogButton(
            label: 'Privacy policy',
            tone: DesktopDialogButtonTone.ghost,
            onPress: () async {
              try {
                if (!await launchUrl(
                  Uri.parse('https://chessever.com/privacy-policy'),
                  mode: LaunchMode.externalApplication,
                )) {
                  throw StateError('Unavailable');
                }
              } catch (_) {
                if (mounted) {
                  setState(
                    () =>
                        _error =
                            'Could not open the privacy policy. Please try again.',
                  );
                }
              }
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: kRedColor)),
          ],
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              DesktopDialogButton(
                label: 'Do not allow',
                onPress: _busy ? null : () => _save(false),
              ),
              DesktopDialogButton(
                label: _busy ? 'Saving…' : 'Allow AI sharing',
                tone: DesktopDialogButtonTone.primary,
                onPress: _busy ? null : () => _save(true),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
