import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/panes/library_pane.dart'
    show DatabaseWorkspaceArgs, openDatabaseWorkspaceTab;
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/services/shared_books.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/repository/library/models/shared_book_preview.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/auth/auth_upgrade_sheet.dart';

const _bodyStyle = TextStyle(color: kWhiteColor70, fontSize: 13, height: 1.5);

/// Publish, copy or revoke the public link of a root database.
Future<void> showShareDatabaseDialog(
  BuildContext context, {
  required LibraryFolder folder,
}) {
  return showDesktopModal<void>(
    context,
    title: 'Share database',
    maxWidth: 500,
    builder: (_) => _ShareDatabaseBody(folder: folder),
  );
}

class _ShareDatabaseBody extends ConsumerStatefulWidget {
  const _ShareDatabaseBody({required this.folder});

  final LibraryFolder folder;

  @override
  ConsumerState<_ShareDatabaseBody> createState() => _ShareDatabaseBodyState();
}

class _ShareDatabaseBodyState extends ConsumerState<_ShareDatabaseBody> {
  late String? _token = widget.folder.shareToken;
  bool _busy = false;
  String? _error;

  Future<void> _run(
    Future<void> Function(LibraryRepository repo) action,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(ref.read(libraryRepositoryProvider));
      ref.invalidate(libraryFoldersStreamProvider);
    } catch (error, stackTrace) {
      ErrorReporter.report(error, stackTrace: stackTrace, tag: 'library.share');
      if (mounted) {
        setState(() => _error = 'Could not update sharing. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final token = _token;
    final url = token == null ? null : sharedBookUrl(token);
    return FTheme(
      data: FThemes.zinc.dark,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.folder.name,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              url == null
                  ? 'Create a link so others can add this database to their '
                      'library, read its games and export them. They '
                      'cannot change it.'
                  : 'Anyone with this link can add the database to their '
                      'library, read it and export it.',
              style: _bodyStyle,
            ),
            const SizedBox(height: 16),
            if (url != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: kBlack3Color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kDividerColor),
                ),
                child: SelectableText(
                  url,
                  maxLines: 1,
                  style: const TextStyle(color: kWhiteColor, fontSize: 13),
                ),
              ),
              const SizedBox(height: 14),
            ],
            if (_error != null) ...[
              Text(
                _error!,
                style: const TextStyle(color: kRedColor, fontSize: 12),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                if (url != null)
                  DesktopDialogButton(
                    label: 'Stop sharing',
                    tone: DesktopDialogButtonTone.danger,
                    onPress:
                        _busy
                            ? null
                            : () => _run((repo) async {
                              await repo.revokeShareToken(widget.folder.id);
                              if (mounted) setState(() => _token = null);
                            }),
                  ),
                const Spacer(),
                if (url == null)
                  DesktopDialogButton(
                    label: _busy ? 'Creating link' : 'Create link',
                    tone: DesktopDialogButtonTone.primary,
                    icon: Icons.link_rounded,
                    onPress:
                        _busy
                            ? null
                            : () => _run((repo) async {
                              final updated = await repo.generateShareToken(
                                widget.folder.id,
                              );
                              if (mounted) {
                                setState(() => _token = updated.shareToken);
                              }
                            }),
                  )
                else
                  DesktopDialogButton(
                    label: 'Copy link',
                    tone: DesktopDialogButtonTone.primary,
                    icon: Icons.copy_rounded,
                    onPress: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (context.mounted) {
                        showDesktopToast(context, 'Link copied');
                      }
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Landing for a shared book link: preview, then add to the library and
/// open it read-only.
Future<void> showSharedBookPreviewDialog(
  BuildContext context, {
  required String shareToken,
}) {
  return showDesktopModal<void>(
    context,
    title: 'Shared database',
    maxWidth: 460,
    builder: (_) => _SharedBookPreviewBody(shareToken: shareToken),
  );
}

class _SharedBookPreviewBody extends ConsumerStatefulWidget {
  const _SharedBookPreviewBody({required this.shareToken});

  final String shareToken;

  @override
  ConsumerState<_SharedBookPreviewBody> createState() =>
      _SharedBookPreviewBodyState();
}

class _SharedBookPreviewBodyState
    extends ConsumerState<_SharedBookPreviewBody> {
  bool _busy = false;
  String? _error;

  bool get _hasPermanentAccount {
    final user = Supabase.instance.client.auth.currentUser;
    return user != null && user.isAnonymous != true;
  }

  Future<void> _add(SharedBookPreview preview) async {
    if (_busy) return;
    if (!_hasPermanentAccount) {
      final signedIn = await showAuthUpgradeSheet(context: context);
      if (!signedIn || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await addSharedBookToLibraryWith(
        ref.read(libraryRepositoryProvider),
        preview.id,
      );
      if (!mounted) return;
      ref.invalidate(subscribedBooksProvider);
      final message = switch (outcome) {
        SharedBookAddOutcome.added => 'Added to your library',
        SharedBookAddOutcome.alreadyInLibrary => 'Already in your library',
        SharedBookAddOutcome.ownBook => 'This is your own database',
      };
      openDatabaseWorkspaceTab(
        ref,
        DatabaseWorkspaceArgs.folder(
          folderId: preview.id,
          title: preview.name,
          isSubscribed: outcome != SharedBookAddOutcome.ownBook,
        ),
      );
      showDesktopToast(context, message);
      Navigator.of(context).maybePop();
    } catch (error, stackTrace) {
      ErrorReporter.report(
        error,
        stackTrace: stackTrace,
        tag: 'library.add_shared_book',
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not add this database. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final previewAsync = ref.watch(
      sharedBookPreviewProvider(widget.shareToken),
    );
    return FTheme(
      data: FThemes.zinc.dark,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: previewAsync.when(
          loading:
              () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: kPrimaryColor,
                      ),
                    ),
                    SizedBox(width: 10),
                    Text('Loading shared database', style: _bodyStyle),
                  ],
                ),
              ),
          error:
              (_, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Could not load this shared database.',
                    style: _bodyStyle,
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: DesktopDialogButton(
                      label: 'Retry',
                      onPress:
                          () => ref.invalidate(
                            sharedBookPreviewProvider(widget.shareToken),
                          ),
                    ),
                  ),
                ],
              ),
          data: (preview) {
            if (preview == null) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'This link is no longer shared. Ask the owner for a new '
                  'one.',
                  style: _bodyStyle,
                ),
              );
            }
            final owner = preview.ownerDisplayName?.trim();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  preview.name,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    if (owner != null && owner.isNotEmpty) 'Shared by $owner',
                    '${preview.gameCount} '
                        '${preview.gameCount == 1 ? 'game' : 'games'}',
                  ].join('  ·  '),
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Adding it keeps it read-only in your library. You can '
                  'export its games at any time.',
                  style: _bodyStyle,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: kRedColor, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerRight,
                  child: DesktopDialogButton(
                    label:
                        _busy
                            ? 'Adding'
                            : (_hasPermanentAccount
                                ? 'Add to library'
                                : 'Sign in to add'),
                    tone: DesktopDialogButtonTone.primary,
                    onPress: _busy ? null : () => _add(preview),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Confirms removing a subscribed shared book. Removal only drops the
/// subscription; the owner's database is untouched.
Future<bool> confirmRemoveSharedBook(
  BuildContext context, {
  required LibraryFolder folder,
}) async {
  final confirmed = await showDesktopModal<bool>(
    context,
    title: 'Remove shared database',
    maxWidth: 440,
    builder:
        (modalContext) => FTheme(
          data: FThemes.zinc.dark,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '"${folder.name}" leaves your library. The owner keeps it, and '
                  'you can add it again from its link.',
                  style: _bodyStyle,
                ),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerRight,
                  child: DesktopDialogButton(
                    label: 'Remove',
                    tone: DesktopDialogButtonTone.danger,
                    onPress: () => Navigator.of(modalContext).pop(true),
                  ),
                ),
              ],
            ),
          ),
        ),
  );
  return confirmed == true;
}
