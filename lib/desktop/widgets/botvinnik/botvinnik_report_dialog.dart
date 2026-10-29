import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/theme/app_theme.dart';

typedef BotvinnikReportCallback =
    Future<void> Function({
      required String accountId,
      required String conversationId,
      required String messageId,
    });

final botvinnikReportCallbackProvider = Provider<BotvinnikReportCallback>((
  ref,
) {
  final api = ChatApi();
  ref.onDispose(api.close);
  return api.reportMessage;
});

Future<bool> showBotvinnikReportDialog(
  BuildContext context, {
  required String accountId,
  required String conversationId,
  required String messageId,
  BotvinnikReportCallback? onReport,
}) async =>
    await showDesktopDialog<bool>(
      context,
      builder:
          (_) => BotvinnikReportDialog(
            accountId: accountId,
            conversationId: conversationId,
            messageId: messageId,
            onReport: onReport,
          ),
    ) ==
    true;

/// Quiet answer action. Opening confirmation never sends a report.
class BotvinnikReportAction extends StatefulWidget {
  const BotvinnikReportAction({
    super.key,
    required this.accountId,
    required this.conversationId,
    required this.messageId,
  });

  final String accountId;
  final String conversationId;
  final String messageId;

  @override
  State<BotvinnikReportAction> createState() => _BotvinnikReportActionState();
}

class _BotvinnikReportActionState extends State<BotvinnikReportAction> {
  bool _open = false;

  Future<void> _show() async {
    if (_open) return;
    setState(() => _open = true);
    try {
      await showBotvinnikReportDialog(
        context,
        accountId: widget.accountId,
        conversationId: widget.conversationId,
        messageId: widget.messageId,
      );
    } finally {
      if (mounted) setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialogButton(
    label: 'Report',
    tooltip: 'Report unsafe answer',
    tone: DesktopDialogButtonTone.ghost,
    onPress: _open ? null : _show,
  );
}

class BotvinnikReportDialog extends ConsumerStatefulWidget {
  const BotvinnikReportDialog({
    super.key,
    required this.accountId,
    required this.conversationId,
    required this.messageId,
    this.onReport,
  });

  final String accountId;
  final String conversationId;
  final String messageId;
  final BotvinnikReportCallback? onReport;

  @override
  ConsumerState<BotvinnikReportDialog> createState() =>
      _BotvinnikReportDialogState();
}

class _BotvinnikReportDialogState extends ConsumerState<BotvinnikReportDialog> {
  // A dialog cannot silently retarget its report if the selected chat changes.
  late final String _accountId;
  late final String _conversationId;
  late final String _messageId;
  bool _busy = false;
  bool _sent = false;
  bool _identityChanged = false;
  bool _dailyLimit = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _accountId = widget.accountId;
    _conversationId = widget.conversationId;
    _messageId = widget.messageId;
  }

  bool get _accountMatches {
    final user = ref.read(currentUserProvider);
    return !_identityChanged &&
        user != null &&
        !user.isAnonymous &&
        user.id == _accountId;
  }

  Future<void> _report() async {
    if (_busy || _sent || _dailyLimit || !_accountMatches) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report =
          widget.onReport ??
          ref.read<BotvinnikReportCallback>(botvinnikReportCallbackProvider);
      await report(
        accountId: _accountId,
        conversationId: _conversationId,
        messageId: _messageId,
      );
      if (!mounted) return;
      setState(() {
        if (_accountMatches) {
          _sent = true;
        } else {
          _identityChanged = true;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (!_accountMatches) {
          _identityChanged = true;
          return;
        }
        final status = error is ChatApiException ? error.statusCode : null;
        _dailyLimit = status == 429;
        _error = switch (status) {
          429 =>
            'The daily report limit has been reached. Try again after 00:00 UTC.',
          401 || 403 => 'Sign in again before reporting this answer.',
          404 => 'This answer is no longer available to report.',
          _ =>
            'Your report could not be confirmed. Check your connection and try again.',
        };
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentUserProvider, (_, user) {
      if (user?.id != _accountId || user?.isAnonymous == true) {
        setState(() {
          _identityChanged = true;
          _sent = false;
          _error = null;
        });
      }
    });
    final accountChanged = !_accountMatches;
    final canClose = !_busy || accountChanged;
    final submitLabel = _busy ? 'Reporting…' : 'Report unsafe answer';
    return PopScope(
      canPop: canClose,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (canClose) Navigator.of(context).maybePop(_sent);
          },
        },
        child: FDialog.raw(
          semanticsLabel: 'Report unsafe answer',
          constraints: BoxConstraints(
            maxWidth: 460,
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          style:
              (style) => style.copyWith(
                decoration: BoxDecoration(
                  color: kBlack2Color,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
          builder:
              (context, _) => SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: const Text(
                        'Report unsafe answer',
                        style: TextStyle(
                          color: kWhiteColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        accountChanged
                            ? 'Your account changed. Close this dialog and open the answer again.'
                            : _sent
                            ? 'Report sent to ChessEver for safety review.'
                            : 'Share this answer with ChessEver for safety review',
                        style: const TextStyle(
                          color: kWhiteColor70,
                          height: 1.5,
                        ),
                      ),
                    ),
                    if (_error != null && !accountChanged) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            color: kWhiteColor,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          DesktopDialogButton(
                            label: _sent || accountChanged ? 'Close' : 'Cancel',
                            tone: DesktopDialogButtonTone.ghost,
                            onPress:
                                canClose
                                    ? () => Navigator.of(context).pop(_sent)
                                    : null,
                          ),
                          if (!_sent && !accountChanged)
                            DesktopDialogButton(
                              key: const ValueKey('botvinnik-report-confirm'),
                              label: submitLabel,
                              fillWidth:
                                  MediaQuery.textScalerOf(context).scale(13) >
                                  18,
                              onPress: _busy || _dailyLimit ? null : _report,
                              child: Text(
                                submitLabel,
                                textAlign: TextAlign.center,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        ),
      ),
    );
  }
}
