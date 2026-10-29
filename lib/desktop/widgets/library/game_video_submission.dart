import 'package:chessever/desktop/services/auth/desktop_guest_upgrade.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import '../desktop_modal.dart';
import '../desktop_dialog_button.dart';
import '../desktop_profile_sign_in.dart';
import 'package:forui/forui.dart';
import 'youtube_video_fields.dart';

/// Standalone author submissions use the same settings as collection videos.
class GameVideoSubmissionBody extends ConsumerStatefulWidget {
  const GameVideoSubmissionBody({
    super.key,
    required this.gameId,
    required this.pgn,
  });
  final String gameId, pgn;
  @override
  ConsumerState<GameVideoSubmissionBody> createState() =>
      _GameVideoSubmissionBodyState();
}

class _GameVideoSubmissionBodyState
    extends ConsumerState<GameVideoSubmissionBody> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _language = TextEditingController();
  String _url = '';
  bool _busy = false;
  String? _error, _editing;
  List<Map<String, dynamic>> _submissions = const [];
  @override
  void initState() {
    super.initState();
    final metadata = Supabase.instance.client.auth.currentUser?.userMetadata;
    _name.text = (metadata?['full_name'] ?? metadata?['name'] ?? '').toString();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await ref
          .read(gamebaseRepositoryProvider)
          .getOwnGameAnalysisVideos(widget.gameId);
      if (mounted) setState(() => _submissions = items);
    } catch (_) {
      /* A failed history read never prevents a submission. */
    }
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (_url.trim().isEmpty) {
      setState(() => _error = 'Attach a YouTube video before submitting.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(gamebaseRepositoryProvider)
          .submitGameAnalysisVideo(
            gameId: widget.gameId,
            pgn: widget.pgn,
            url: _url,
            authorName: _name.text.trim(),
            language: _language.text.trim(),
            submissionId: _editing,
          );
      if (!mounted) return;
      setState(() => _editing = null);
      setState(
        () =>
            _error =
                'Video submitted for review. It becomes public after approval.',
      );
      await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error =
                  'Could not submit the video. Your edits are kept. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn =
        ref.watch(currentUserProvider) != null &&
        Supabase.instance.client.auth.currentUser?.isAnonymous != true;
    if (!signedIn) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DesktopProfileSignIn(
            onSignIn: (provider) async {
              try {
                await signInDesktopPermanentAccount(
                  ref,
                  provider,
                  surface: 'video_submission',
                );
                if (mounted) {
                  setState(() {});
                  await _load();
                }
              } catch (_) {
                if (mounted) {
                  setState(
                    () => _error = 'Could not sign in. Please try again.',
                  );
                }
              }
            },
          ),
          if(_error!=null) Padding(padding:const EdgeInsets.all(12),child:Text(_error!)),
          DesktopDialogButton(
            label: 'Close',
            onPress: () => Navigator.of(context).pop(),
          ),
        ],
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Attach an analysis video to this game. It becomes public after a ChessEver superadmin approves it.',
              ),
              const SizedBox(height: 20),
              FTextFormField(
                controller: _name,
                enabled: !_busy,
                label: const Text('Author name'),
                maxLength: 80,
                validator:
                    (value) =>
                        (value?.trim().length ?? 0) < 2
                            ? 'Enter your author name.'
                            : null,
              ),
              const SizedBox(height: 16),
              YoutubeVideoFields(
                key: ValueKey(_editing),
                value: _url,
                enabled: !_busy,
                onChanged: (value) => _url = value,
              ),
              const SizedBox(height: 16),
              FTextFormField(
                controller: _language,
                enabled: !_busy,
                label: const Text('Spoken language (optional)'),
                hint: 'e.g. en or tr',
                validator:
                    (value) =>
                        value == null ||
                                value.trim().isEmpty ||
                                RegExp(
                                  r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$',
                                ).hasMatch(value.trim())
                            ? null
                            : 'Use a language code such as en or pt-BR.',
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              FButton(
                onPress: _busy ? null : _submit,
                child: Expanded(
                  child: Text(_busy ? 'Submitting…' : 'Submit for review'),
                ),
              ),
              const SizedBox(height: 12),
              DesktopDialogButton(
                label: 'Close',
                onPress: _busy ? null : () => Navigator.of(context).pop(),
              ),
              if (_submissions.isNotEmpty) ...[
                const SizedBox(height: 28),
                const Text(
                  'Your submissions',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                for (final item in _submissions)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('${item['authorName']} · ${item['status']}'),
                        if (item['note'] != null) Text(item['note'] as String),
                        DesktopDialogButton(
                          label: 'Edit',
                          onPress:
                              _busy
                                  ? null
                                  : () => setState(() {
                                    _editing = item['id'] as String;
                                    _url = item['url'] as String;
                                    _name.text = item['authorName'] as String;
                                    _language.text =
                                        item['language'] as String? ?? '';
                                  }),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _language.dispose();
    super.dispose();
  }
}

Future<void> showGameVideoSubmission(
  BuildContext context, {
  required String gameId,
  required String pgn,
}) => showDesktopModal<void>(
  context,
  maxWidth: 600,
  builder: (_) => GameVideoSubmissionBody(gameId: gameId, pgn: pgn),
);
