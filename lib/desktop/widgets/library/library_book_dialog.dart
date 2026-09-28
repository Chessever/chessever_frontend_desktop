import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/library_book_publication.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/theme/app_theme.dart';

Future<void> showLibraryBookDialog(
  BuildContext context, {
  required LibraryFolder folder,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierLabel: 'Book publishing',
  barrierColor: Colors.black.withValues(alpha: 0.55),
  transitionDuration: Duration.zero,
  pageBuilder:
      (_, _, _) => FTheme(
        data: FThemes.zinc.dark,
        child: LibraryBookDialog(folder: folder),
      ),
);

/// Edits catalog metadata separately from the private source folder. Nothing
/// is public until the author chooses Publish book.
class LibraryBookDialog extends ConsumerStatefulWidget {
  const LibraryBookDialog({super.key, required this.folder});
  final LibraryFolder folder;

  @override
  ConsumerState<LibraryBookDialog> createState() => _LibraryBookDialogState();
}

class _LibraryBookDialogState extends ConsumerState<LibraryBookDialog> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _subtitle = TextEditingController();
  final _author = TextEditingController();
  final _about = TextEditingController();
  final _foreword = TextEditingController();
  final _publisher = TextEditingController();
  final _year = TextEditingController();
  final _cover = TextEditingController();
  LibraryBookPublication? _publication;
  bool _loading = true;
  bool _busy = false;
  bool _confirmUnpublish = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in [
      _title,
      _subtitle,
      _author,
      _about,
      _foreword,
      _publisher,
      _year,
      _cover,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await ref
          .read(libraryBookPublisherProvider)
          .load(widget.folder);
      if (!mounted) return;
      _setPublication(value);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setPublication(LibraryBookPublication value) {
    final metadata = value.metadata;
    _title.text = metadata.title;
    _subtitle.text = metadata.subtitle;
    _author.text = metadata.author;
    _about.text = metadata.about;
    _foreword.text = metadata.foreword;
    _publisher.text = metadata.publisher;
    _year.text = metadata.publishedYear?.toString() ?? '';
    _cover.text = metadata.coverUrl;
    setState(() {
      _publication = value;
      _confirmUnpublish = false;
    });
  }

  Future<void> _save({bool publish = false, bool refreshGames = false}) async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
    final metadata = LibraryBookMetadata(
      title: _title.text,
      subtitle: _subtitle.text,
      author: _author.text,
      about: _about.text,
      foreword: _foreword.text,
      publisher: _publisher.text,
      publishedYear: int.tryParse(_year.text.trim()),
      coverUrl: _cover.text,
    );
    await _mutate(
      () => ref
          .read(libraryBookPublisherProvider)
          .save(
            widget.folder,
            metadata,
            publish: publish,
            refreshGames: refreshGames,
          ),
      success:
          publish
              ? 'Your book is public in Collections.'
              : refreshGames
              ? 'Published games updated from this folder.'
              : _publication?.isPublished == true
              ? 'Public book details saved.'
              : 'Draft saved. This book is private.',
    );
  }

  Future<void> _mutate(
    Future<LibraryBookPublication> Function() action, {
    required String success,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final value = await action();
      if (!mounted) return;
      _setPublication(value);
      setState(() => _notice = success);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _errorText(Object error) =>
      error is LibraryBookPublicationException
          ? error.message
          : 'Could not load or save this book. Your entered details have been kept. Retry in a moment.';

  @override
  Widget build(BuildContext context) {
    final publication = _publication;
    final published = publication?.isPublished == true;
    final size = MediaQuery.sizeOf(context);
    return PopScope(
      canPop: !_busy,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (!_busy) Navigator.of(context).maybePop();
          },
        },
        child: Focus(
          autofocus: true,
          child: FDialog.raw(
            semanticsLabel: 'Book publishing',
            constraints: BoxConstraints(
              maxWidth: size.width < 680 ? size.width - 32 : 640,
              maxHeight: size.height - 48,
            ),
            builder:
                (context, _) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              published
                                  ? 'Edit published book'
                                  : 'Publish a book',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: kWhiteColor,
                              ),
                            ),
                          ),
                          DesktopDialogIconButton(
                            icon: Icons.close_rounded,
                            tooltip: 'Close',
                            onPress:
                                _busy
                                    ? null
                                    : () => Navigator.of(context).maybePop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.folder.name,
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Text(
                            'Loading book details…',
                            style: TextStyle(color: kWhiteColor70),
                          ),
                        )
                      else if (publication == null) ...[
                        Text(
                          _error ?? 'Could not load this book.',
                          style: const TextStyle(color: kWhiteColor70),
                        ),
                        const SizedBox(height: 16),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: DesktopDialogButton(
                            label: 'Retry',
                            onPress: _load,
                          ),
                        ),
                      ] else ...[
                        Flexible(
                          child: SingleChildScrollView(
                            child: Form(
                              key: _form,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    published
                                        ? 'Public in Collections · ${publication.gameCount} games. Saving details updates the public book. Update games to replace its snapshot with the latest folder contents.'
                                        : 'Private until you publish. Publishing makes this folder and its nested games available as a book in Collections. Include only content you have permission to share. A book can contain up to 1,000 games and 10 MB of PGN.',
                                    style: const TextStyle(
                                      color: kWhiteColor70,
                                      fontSize: 13,
                                      height: 1.5,
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  _field(
                                    'Title',
                                    _title,
                                    maxLength: 300,
                                    required: true,
                                  ),
                                  _field('Subtitle', _subtitle, maxLength: 300),
                                  _field('Author', _author, maxLength: 300),
                                  _field(
                                    'About this book',
                                    _about,
                                    maxLines: 4,
                                    maxLength: 20000,
                                  ),
                                  _field(
                                    'Foreword',
                                    _foreword,
                                    maxLines: 3,
                                    maxLength: 50000,
                                  ),
                                  _field(
                                    'Publisher',
                                    _publisher,
                                    maxLength: 200,
                                  ),
                                  _field(
                                    'Publication year',
                                    _year,
                                    maxLength: 4,
                                    validator: (value) {
                                      if (value == null ||
                                          value.trim().isEmpty) {
                                        return null;
                                      }
                                      final year = int.tryParse(value.trim());
                                      return year == null ||
                                              year < 0 ||
                                              year > 9999
                                          ? 'Enter a year from 0 to 9999.'
                                          : null;
                                    },
                                  ),
                                  _field(
                                    'Cover image URL',
                                    _cover,
                                    maxLength: 2000,
                                    validator: (value) {
                                      if (value == null ||
                                          value.trim().isEmpty) {
                                        return null;
                                      }
                                      final uri = Uri.tryParse(value.trim());
                                      return uri == null ||
                                              uri.scheme != 'https' ||
                                              uri.host.isEmpty ||
                                              uri.userInfo.isNotEmpty
                                          ? 'Enter a public HTTPS image URL.'
                                          : null;
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (_error != null || _notice != null) ...[
                          const SizedBox(height: 12),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _error ?? _notice!,
                              style: TextStyle(
                                color:
                                    _error != null ? kRedColor : kWhiteColor70,
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                        if (_busy) ...[
                          const SizedBox(height: 12),
                          Semantics(
                            liveRegion: true,
                            child: const Text(
                              'Saving… Large folders may take a few minutes. Keep this window open.',
                              style: TextStyle(
                                color: kWhiteColor70,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                        if (_confirmUnpublish) ...[
                          const SizedBox(height: 12),
                          const Text(
                            'Remove this book from public Collections? Your private folder and book details are kept.',
                            style: TextStyle(
                              color: kWhiteColor70,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              DesktopDialogButton(
                                label: 'Keep published',
                                tone: DesktopDialogButtonTone.ghost,
                                onPress:
                                    _busy
                                        ? null
                                        : () => setState(
                                          () => _confirmUnpublish = false,
                                        ),
                              ),
                              DesktopDialogButton(
                                label: 'Unpublish book',
                                tone: DesktopDialogButtonTone.danger,
                                onPress:
                                    _busy
                                        ? null
                                        : () => _mutate(
                                          () => ref
                                              .read(
                                                libraryBookPublisherProvider,
                                              )
                                              .unpublish(widget.folder),
                                          success:
                                              'Book unpublished. Your private folder is unchanged.',
                                        ),
                              ),
                            ],
                          ),
                        ] else ...[
                          const SizedBox(height: 20),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (published)
                                DesktopDialogButton(
                                  label: 'Unpublish',
                                  tone: DesktopDialogButtonTone.ghost,
                                  onPress:
                                      _busy
                                          ? null
                                          : () => setState(
                                            () => _confirmUnpublish = true,
                                          ),
                                ),
                              DesktopDialogButton(
                                label:
                                    published ? 'Save details' : 'Save draft',
                                tone: DesktopDialogButtonTone.ghost,
                                onPress: _busy ? null : () => _save(),
                              ),
                              DesktopDialogButton(
                                label:
                                    published ? 'Update games' : 'Publish book',
                                icon: Icons.publish_rounded,
                                tone: DesktopDialogButtonTone.primary,
                                onPress:
                                    _busy
                                        ? null
                                        : () => _save(
                                          publish: !published,
                                          refreshGames: true,
                                        ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    int maxLines = 1,
    required int maxLength,
    bool required = false,
    String? Function(String?)? validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: FTextFormField(
      controller: controller,
      autofocus: identical(controller, _title),
      label: Text(label),
      enabled: !_busy,
      maxLines: maxLines,
      maxLength: maxLength,
      keyboardType: maxLines > 1 ? TextInputType.multiline : TextInputType.text,
      validator: (value) {
        if (required && (value == null || value.trim().isEmpty)) {
          return 'Enter a title for your book.';
        }
        return validator?.call(value);
      },
    ),
  );
}
