import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/services/collection_cover.dart';
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

/// Keeps typed text tidy as it is entered: no leading space and no runs of
/// spaces. Single-line fields also refuse line breaks; multi-line ones allow
/// at most one blank line between paragraphs.
class _TidySpacesFormatter extends TextInputFormatter {
  const _TidySpacesFormatter({this.multiline = false});
  final bool multiline;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = newValue.text;
    text =
        multiline
            ? text.replaceAll(RegExp(r'\n{3,}'), '\n\n')
            : text.replaceAll(RegExp(r'[\r\n\t]'), ' ');
    text = text
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .replaceFirst(RegExp(r'^\s+'), '');
    if (text == newValue.text) return newValue;
    final removed = newValue.text.length - text.length;
    final offset = (newValue.selection.baseOffset - removed).clamp(
      0,
      text.length,
    );
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

/// The fields this dialog edits, in the order they read on the collection
/// page. Foreword and publisher are not edited here: the publisher is always
/// ChessEver's own editor, and a foreword belongs to a printed book, not to a
/// folder of games. Whatever the server already holds for them is kept.
enum _Field { title, subtitle, author, year, about }

/// Which preview a field is drawn in: the list row (0) or the page (1).
const _listFields = {_Field.title, _Field.author};

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
  final _fields = {for (final f in _Field.values) f: TextEditingController()};
  final _focus = {for (final f in _Field.values) f: FocusNode()};
  LibraryBookPublication? _publication;
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;
  bool _confirmUnpublish = false;
  bool _validateForPublish = false;
  String? _error;
  String? _notice;

  /// 0: as it reads in the Collections list, 1: as its page opens.
  int _previewTab = 0;
  _Field? _focused;

  /// The cover lives on the server: it is uploaded as soon as it is chosen,
  /// and the saved link is carried through every details save.
  String _coverUrl = '';
  Uint8List? _coverPreview;
  bool _coverBusy = false;

  @override
  void initState() {
    super.initState();
    for (final entry in _focus.entries) {
      entry.value.addListener(() => _onFocus(entry.key, entry.value));
    }
    _load();
  }

  @override
  void dispose() {
    _stashTimer?.cancel();
    // Leaving mid-edit still keeps the work.
    if (_dirty) _stashDraft();
    for (final field in _fields.values) {
      field.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Follow the field being edited: the preview turns to where that field
  /// shows, and its spot there lights up.
  void _onFocus(_Field field, FocusNode node) {
    if (!mounted) return;
    if (node.hasFocus) {
      setState(() {
        _focused = field;
        _previewTab = _listFields.contains(field) ? 0 : 1;
      });
    } else if (_focused == field) {
      setState(() => _focused = null);
    }
  }

  String _text(_Field field) => _fields[field]!.text;

  void _setPublication(LibraryBookPublication value) {
    final m = value.metadata;
    final values = {
      _Field.title: m.title,
      _Field.subtitle: m.subtitle,
      _Field.author: m.author,
      _Field.year: m.publishedYear?.toString() ?? '',
      _Field.about: m.about,
    };
    for (final entry in values.entries) {
      _fields[entry.key]!.text = entry.value;
    }
    if (m.author.trim().isEmpty) _prefillRemembered();
    setState(() {
      _publication = value;
      _coverUrl = m.coverUrl;
      _confirmUnpublish = false;
      _dirty = false;
    });
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
    // Asked once the form is on screen, so the user sees what they resume.
    if (mounted && _publication != null && _error == null) await _offerDraft();
  }

  // --- Saved progress: per-folder draft stash on this device. ---------------

  String get _draftKey => 'library_book.draft.${widget.folder.id}';
  Timer? _stashTimer;

  void _scheduleStash() {
    _stashTimer?.cancel();
    _stashTimer = Timer(const Duration(milliseconds: 500), _stashDraft);
  }

  Future<void> _stashDraft() async {
    final values = {for (final f in _Field.values) f.name: _text(f)};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_draftKey, jsonEncode(values));
    } catch (_) {}
  }

  Future<void> _clearDraft() async {
    _stashTimer?.cancel();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_draftKey);
    } catch (_) {}
  }

  Future<void> _offerDraft() async {
    Map<String, dynamic>? draft;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_draftKey);
      if (raw != null) draft = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      draft = null;
    }
    if (draft == null || !mounted) return;
    final values = {
      for (final f in _Field.values)
        if (draft[f.name] is String) f: draft[f.name] as String,
    };
    final differs = values.entries.any(
      (e) => e.value.trim() != _text(e.key).trim(),
    );
    if (!differs) {
      await _clearDraft();
      return;
    }
    final resume = await _showResumeDialog();
    if (!mounted) return;
    if (resume == true) {
      setState(() {
        for (final e in values.entries) {
          _fields[e.key]!.text = e.value;
        }
        _dirty = true;
      });
    } else if (resume == false) {
      await _clearDraft();
    }
    // Dismissed without choosing: keep the draft for next time.
  }

  /// Continue / Start over. Dismiss keeps the stash (returns null).
  Future<bool?> _showResumeDialog() => showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Continue where you left off?',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder:
        (ctx, _, _) => FTheme(
          data: FThemes.zinc.dark,
          child: Center(
            child: Container(
              width: 420,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDividerColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Continue where you left off?',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'You have unsubmitted changes to this collection from '
                    'your last visit.',
                    style: TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DesktopDialogButton(
                        label: 'Start over',
                        tone: DesktopDialogButtonTone.ghost,
                        onPress: () => Navigator.of(ctx).pop(false),
                      ),
                      const SizedBox(width: 8),
                      DesktopDialogButton(
                        label: 'Continue',
                        tone: DesktopDialogButtonTone.primary,
                        onPress: () => Navigator.of(ctx).pop(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
  );

  // --- Remembered author ----------------------------------------------------

  static const _lastAuthorKey = 'library_book.last_author';

  Future<void> _prefillRemembered() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final author = prefs.getString(_lastAuthorKey)?.trim() ?? '';
      final field = _fields[_Field.author]!;
      if (!mounted || author.isEmpty || field.text.trim().isNotEmpty) return;
      setState(() => field.text = author);
    } catch (_) {
      // A missing preference only means no pre-fill.
    }
  }

  Future<void> _remember(LibraryBookMetadata metadata) async {
    final author = metadata.author.trim();
    if (author.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastAuthorKey, author);
    } catch (_) {}
  }

  // --- Save -----------------------------------------------------------------

  LibraryBookMetadata get _metadata {
    final saved = _publication?.metadata;
    return LibraryBookMetadata(
      title: _text(_Field.title).trim(),
      subtitle: _text(_Field.subtitle).trim(),
      author: _text(_Field.author).trim(),
      about: _text(_Field.about).trim(),
      // Not editable here; carried through so a save never erases them.
      foreword: saved?.foreword ?? '',
      publisher: saved?.publisher ?? '',
      publishedYear: int.tryParse(_text(_Field.year).trim()),
      // Set by the cover upload, never typed; carried through on save.
      coverUrl: _coverUrl,
    );
  }

  Future<void> _save({bool publish = false, bool refreshGames = false}) async {
    if (_busy || _coverBusy) return;
    _validateForPublish = publish;
    if (!(_form.currentState?.validate() ?? false)) {
      setState(
        () =>
            _error = 'Check the highlighted collection details before saving.',
      );
      return;
    }
    FocusScope.of(context).unfocus();
    await _mutate(
      () => ref
          .read(libraryBookPublisherProvider)
          .save(
            widget.folder,
            _metadata,
            publish: publish,
            refreshGames: refreshGames,
          ),
      // Gamebase sends every submission, and every change to a live book,
      // to ChessEver for review; nothing goes public from here directly.
      success:
          (saved) =>
              saved.isPublished
                  ? 'Collection updated.'
                  : publish
                  ? 'Submitted for ChessEver approval. It appears in Collections once approved.'
                  : 'Draft saved. This collection is private.',
      afterSuccess: (saved) {
        unawaited(_clearDraft());
        _remember(saved.metadata);
      },
    );
  }

  Future<void> _mutate(
    Future<LibraryBookPublication> Function() action, {
    required String Function(LibraryBookPublication saved) success,
    void Function(LibraryBookPublication saved)? afterSuccess,
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
      afterSuccess?.call(value);
      setState(() => _notice = success(value));
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- Cover: the collection's own image, not the profile photo. -----------

  /// Choose an image, prepare the 2:3 cover and upload it straight away. A
  /// cover belongs to a saved book, so a never-saved one is first saved as a
  /// private draft with what is typed.
  Future<void> _pickCover() async {
    if (_busy || _coverBusy) return;
    final Uint8List? image;
    try {
      image = await ref.read(collectionCoverPickerProvider)();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
      return;
    }
    if (image == null || !mounted) return;
    final wasPublished = _publication?.isPublished ?? false;
    setState(() {
      _coverBusy = true;
      _coverPreview = image;
      _error = null;
      _notice = null;
    });
    try {
      final publisher = ref.read(libraryBookPublisherProvider);
      if (_publication?.bookId == null) {
        _validateForPublish = false;
        if (!(_form.currentState?.validate() ?? false)) {
          throw const LibraryBookPublicationException(
            'Add a title first. The cover is saved with the book.',
          );
        }
        final saved = await publisher.save(widget.folder, _metadata);
        if (!mounted) return;
        _setPublication(saved);
        unawaited(_clearDraft());
        _remember(saved.metadata);
      }
      final result = await publisher.uploadCover(widget.folder, image);
      if (!mounted) return;
      setState(() {
        _publication = result;
        _coverUrl = result.metadata.coverUrl;
        _notice =
            wasPublished
                ? 'Cover saved. ChessEver will review the change.'
                : 'Cover saved.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _coverPreview = null;
          _error =
              error is LibraryBookPublicationException
                  ? error.message
                  : 'Could not save the cover. Retry when connected.';
        });
      }
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
  }

  Future<void> _removeCover() async {
    if (_busy || _coverBusy) return;
    setState(() {
      _coverBusy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await ref
          .read(libraryBookPublisherProvider)
          .removeCover(widget.folder);
      if (!mounted) return;
      setState(() {
        _publication = result;
        _coverUrl = result.metadata.coverUrl;
        _coverPreview = null;
        _notice = 'Cover removed.';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  error is LibraryBookPublicationException
                      ? error.message
                      : 'Could not remove the cover. Retry when connected.',
        );
      }
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
  }

  Widget _coverPicker(bool published) {
    final url = _coverUri(_coverUrl);
    final hasCover = _coverPreview != null || url != null;
    final enabled = !_busy && !_coverBusy;
    final Widget thumb =
        _coverPreview != null
            ? Image.memory(_coverPreview!, fit: BoxFit.cover)
            : url != null
            ? CachedNetworkImage(
              imageUrl: url.toString(),
              fit: BoxFit.cover,
              placeholder: (_, _) => const _DefaultPlate(),
              errorWidget: (_, _, _) => const _DefaultPlate(),
            )
            : const _DefaultPlate();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Cover',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              SizedBox(width: 6),
              Text(
                'Optional',
                style: TextStyle(color: kWhiteColor70, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Shown on the collection card and page. The centre of your image is cropped to a 2:3 portrait. Without one, the default plate is shown.',
            style: TextStyle(color: kWhiteColor70, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Semantics(
                image: true,
                label: hasCover ? 'Collection cover' : 'No cover yet',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 64,
                    height: 96,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        thumb,
                        if (_coverBusy)
                          ColoredBox(
                            color: Colors.black.withValues(alpha: 0.45),
                            child: const Center(
                              child: SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: kWhiteColor,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        DesktopDialogButton(
                          key: const ValueKey('book_cover_choose'),
                          label:
                              _coverBusy
                                  ? 'Saving cover…'
                                  : hasCover
                                  ? 'Replace image'
                                  : 'Choose image…',
                          icon: Icons.image_outlined,
                          onPress: enabled ? _pickCover : null,
                        ),
                        if (hasCover && !_coverBusy)
                          DesktopDialogButton(
                            key: const ValueKey('book_cover_remove'),
                            label: 'Remove cover',
                            tone: DesktopDialogButtonTone.ghost,
                            onPress: enabled ? _removeCover : null,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      published
                          ? 'JPEG, PNG or WebP, at least 600 × 900. A new cover goes to ChessEver for review.'
                          : 'JPEG, PNG or WebP, at least 600 × 900.',
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _errorText(Object error) =>
      error is LibraryBookPublicationException
          ? error.message
          : 'Could not load or save this book. Your entered details have been kept. Retry in a moment.';

  // --- Validation (desktop draft-vs-submit semantics) -----------------------

  String? _validate(_Field field, String? raw) {
    final value = raw?.trim() ?? '';
    switch (field) {
      case _Field.title:
        if (value.isEmpty) return 'Enter a title for your book.';
        return value.length < 3 ? 'Use at least 3 characters.' : null;
      case _Field.subtitle:
        return value.isNotEmpty &&
                value.toLowerCase() == _text(_Field.title).trim().toLowerCase()
            ? 'Say something the title doesn’t.'
            : null;
      case _Field.author:
        if (value.isEmpty) {
          // Required only when submitting for publication.
          return _validateForPublish ? 'Credit the author by name.' : null;
        }
        return RegExp(r'\p{L}{2}', unicode: true).hasMatch(value)
            ? null
            : 'Enter the author’s name.';
      case _Field.year:
        if (value.isEmpty) return null;
        final year = int.tryParse(value);
        return year == null || year < 1000 || year > DateTime.now().year + 1
            ? 'Enter a four-digit year.'
            : null;
      case _Field.about:
        return _validateForPublish && value.isEmpty
            ? 'Describe this collection.'
            : null;
    }
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final publication = _publication;
    final published = publication?.isPublished == true;
    final size = MediaQuery.sizeOf(context);
    // Wide enough for form + preview side by side; one column below this.
    final twoColumn = size.width >= 820;
    final maxWidth =
        twoColumn
            ? (size.width < 1008 ? size.width - 48 : 960)
            : (size.width < 640 ? size.width - 32 : 600);
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
              maxWidth: maxWidth.toDouble(),
              maxHeight: size.height - 48,
            ),
            builder:
                (context, _) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(published),
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
                      ] else
                        Flexible(
                          child: _body(
                            context,
                            publication: publication,
                            published: published,
                            twoColumn: twoColumn,
                          ),
                        ),
                    ],
                  ),
                ),
          ),
        ),
      ),
    );
  }

  Widget _header(bool published) => Row(
    children: [
      Expanded(
        child: Text(
          published ? 'Edit published book' : 'Publish a book',
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
        onPress: _busy ? null : () => Navigator.of(context).maybePop(),
      ),
    ],
  );

  Widget _body(
    BuildContext context, {
    required LibraryBookPublication publication,
    required bool published,
    required bool twoColumn,
  }) {
    final form = _formColumn(publication, published);
    final preview = _previewColumn(publication);
    if (!twoColumn) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [preview, const SizedBox(height: 24), form],
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 5, child: SingleChildScrollView(child: form)),
        const SizedBox(width: 24),
        // Sticky preview: does not scroll with the form.
        Expanded(flex: 4, child: preview),
      ],
    );
  }

  Widget _formColumn(LibraryBookPublication publication, bool published) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            published
                ? 'Public in Collections · ${publication.gameCount} games. Changes go to ChessEver for review. Submit with latest games to replace its games with the folder’s current contents.'
                : 'Private draft · only you can see it. Submitting sends this folder and its nested games to ChessEver, who reviews every collection before it appears in Collections. Include only content you have permission to share. Up to 1,000 games and 10 MB of PGN.',
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Everything is needed to submit unless marked Optional.',
            style: TextStyle(color: kWhiteColor70, fontSize: 12),
          ),
          const SizedBox(height: 16),
          _field(
            _Field.title,
            label: 'Title',
            where: 'The name readers see in the list and on top of the page.',
            hint: 'e.g. Carlsen’s Best Endgames',
            limit: 80,
            counter: false,
          ),
          _field(
            _Field.subtitle,
            label: 'Subtitle',
            optional: true,
            where:
                'One short line under the title on the collection page. It adds detail the title leaves out.',
            hint: 'e.g. 40 annotated wins, 2013–2023',
            limit: 120,
            counter: true,
          ),
          _field(
            _Field.author,
            label: 'Author',
            where: 'Credited as “by …” in the list and on the page.',
            hint: 'e.g. Magnus Carlsen',
            limit: 60,
            counter: false,
          ),
          _field(
            _Field.year,
            label: 'Year',
            optional: true,
            where: 'Shown on the page under the author.',
            hint: 'e.g. ${DateTime.now().year}',
            limit: 4,
            counter: false,
          ),
          _field(
            _Field.about,
            label: 'Description',
            where: 'Opens the page under “About this collection”.',
            hint:
                'What’s inside, who it’s for, and what readers will take away.',
            lines: 4,
            limit: 1500,
            counter: true,
          ),
          _coverPicker(published),
          if (_error != null || _notice != null) ...[
            const SizedBox(height: 4),
            Semantics(
              liveRegion: true,
              child: Text(
                _error ?? _notice!,
                style: TextStyle(
                  color: _error != null ? kRedColor : kWhiteColor70,
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
                style: TextStyle(color: kWhiteColor70, fontSize: 13),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _actions(published),
        ],
      ),
    );
  }

  Widget _actions(bool published) {
    if (_confirmUnpublish) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Remove this book from public Collections? Your private folder and book details are kept.',
            style: TextStyle(color: kWhiteColor70, fontSize: 13),
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
                        : () => setState(() => _confirmUnpublish = false),
              ),
              DesktopDialogButton(
                label: 'Unpublish book',
                tone: DesktopDialogButtonTone.danger,
                onPress:
                    _busy
                        ? null
                        : () => _mutate(
                          () => ref
                              .read(libraryBookPublisherProvider)
                              .unpublish(widget.folder),
                          success:
                              (_) =>
                                  'Book unpublished. Your private folder is unchanged.',
                        ),
              ),
            ],
          ),
        ],
      );
    }
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        if (published)
          DesktopDialogButton(
            label: 'Unpublish',
            tone: DesktopDialogButtonTone.ghost,
            onPress:
                _busy ? null : () => setState(() => _confirmUnpublish = true),
          ),
        // A live book cannot keep a private edit: Gamebase returns any
        // change to review, so published books always resubmit. Saving one
        // without submitting would quietly take it out of Collections.
        DesktopDialogButton(
          label: published ? 'Submit changes' : 'Save draft',
          tone: DesktopDialogButtonTone.ghost,
          onPress: _busy ? null : () => _save(publish: published),
        ),
        DesktopDialogButton(
          label: published ? 'Submit with latest games' : 'Submit for approval',
          icon: Icons.publish_rounded,
          tone: DesktopDialogButtonTone.primary,
          onPress:
              _busy ? null : () => _save(publish: true, refreshGames: true),
        ),
      ],
    );
  }

  Widget _previewColumn(LibraryBookPublication publication) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Preview',
          style: TextStyle(
            color: kWhiteColor,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        _PreviewSwitcher(
          index: _previewTab,
          onChanged: (i) => setState(() => _previewTab = i),
          busy: _busy,
        ),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: Listenable.merge(_fields.values),
          builder:
              (context, _) => _BookPreview(
                page: _previewTab == 1,
                title: _text(_Field.title).trim(),
                subtitle: _text(_Field.subtitle).trim(),
                author: _text(_Field.author).trim(),
                year: _text(_Field.year).trim(),
                about: _text(_Field.about).trim(),
                cover: _coverUri(_coverUrl),
                coverBytes: _coverPreview,
                coverLit: _coverBusy,
                gameCount: publication.gameCount,
                focused: _focused,
              ),
        ),
      ],
    );
  }

  Widget _field(
    _Field field, {
    required String label,
    required String where,
    required String hint,
    bool optional = false,
    bool counter = false,
    int lines = 1,
    required int limit,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: FTextFormField(
        controller: _fields[field],
        focusNode: _focus[field],
        autofocus: field == _Field.title,
        enabled: !_busy,
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (optional) ...[
              const SizedBox(width: 6),
              const Text(
                'Optional',
                style: TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ],
        ),
        description: Text(where),
        hint: hint,
        maxLines: lines,
        minLines: lines == 1 ? 1 : lines,
        maxLength: limit,
        // Hard-cap every field; the `counter` flag only decides whether the
        // running count is shown (Subtitle, Description, Cover).
        maxLengthEnforcement: MaxLengthEnforcement.enforced,
        counterBuilder:
            counter
                ? null
                : (context, current, max, focused) => const SizedBox.shrink(),
        keyboardType: switch (field) {
          _Field.year => TextInputType.number,
          _ when lines > 1 => TextInputType.multiline,
          _ => TextInputType.text,
        },
        inputFormatters: switch (field) {
          _Field.year => [FilteringTextInputFormatter.digitsOnly],
          _Field.author => [
            // Names only: letters (any script), spaces and . ' - , &.
            FilteringTextInputFormatter.allow(
              RegExp(r"[\p{L}\p{M} .'’\-,&]", unicode: true),
            ),
            const _TidySpacesFormatter(),
          ],
          _Field.about => [const _TidySpacesFormatter(multiline: true)],
          _ => [const _TidySpacesFormatter()],
        },
        // Author is a proper name: every word starts upper-case.
        textCapitalization: switch (field) {
          _Field.year => TextCapitalization.none,
          _Field.title ||
          _Field.subtitle ||
          _Field.author => TextCapitalization.words,
          _ => TextCapitalization.sentences,
        },
        onChange: (_) {
          if (!_dirty) setState(() => _dirty = true);
          _scheduleStash();
        },
        validator: (raw) => _validate(field, raw),
      ),
    );
  }
}

/// An HTTPS image link, or null when [raw] is not one.
Uri? _coverUri(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

String _plural(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';

/// Two-view switcher styled to the desktop dialog vocabulary.
class _PreviewSwitcher extends StatelessWidget {
  const _PreviewSwitcher({
    required this.index,
    required this.onChanged,
    required this.busy,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        children: [
          _segment('In the list', 0),
          const SizedBox(width: 3),
          _segment('Collection page', 1),
        ],
      ),
    );
  }

  Widget _segment(String label, int value) {
    final selected = index == value;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.16)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color:
                  selected
                      ? kPrimaryColor.withValues(alpha: 0.4)
                      : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? kLightYellowColor : kWhiteColor70,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// The default plate shown when no cover is set: stacked boards, matching the
/// desktop collection card's quiet dark surface.
class _DefaultPlate extends StatelessWidget {
  const _DefaultPlate();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [kBlack3Color, kBlack2Color],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.collections_bookmark_outlined,
          size: 28,
          color: kWhiteColor.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}

/// The collection as it will be drawn, built from what is typed now: the list
/// row mirrors the desktop collection card; the page is the top of the
/// collection's About page. An empty optional field leaves no trace, exactly
/// as published, until it is being edited: then its place shows as a ghost,
/// and the spot of whichever field has focus is lit.
class _BookPreview extends StatelessWidget {
  const _BookPreview({
    required this.page,
    required this.title,
    required this.subtitle,
    required this.author,
    required this.year,
    required this.about,
    required this.cover,
    required this.coverBytes,
    required this.coverLit,
    required this.gameCount,
    required this.focused,
  });

  final bool page;
  final String title;
  final String subtitle;
  final String author;
  final String year;
  final String about;
  final Uri? cover;
  final Uint8List? coverBytes;
  final bool coverLit;
  final int gameCount;
  final _Field? focused;

  Widget _plate(BoxFit fit) {
    final url = cover;
    const plate = _DefaultPlate();
    // A just-chosen cover shows at once, before its upload completes.
    if (coverBytes != null) return Image.memory(coverBytes!, fit: fit);
    if (url == null) return plate;
    return CachedNetworkImage(
      imageUrl: url.toString(),
      fit: fit,
      placeholder: (_, _) => plate,
      errorWidget: (_, _, _) => plate,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('book_preview'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBlack2Color.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kWhiteColor.withValues(alpha: 0.08)),
      ),
      child: AnimatedSize(
        duration:
            MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: page ? _pageView(context) : _listView(context),
      ),
    );
  }

  /// The desktop collection card look: full-bleed plate, a dark scrim, title +
  /// meta pinned to the bottom-left. A book credits its author; the subtitle
  /// takes that place only when no author is set, so say so when both are.
  Widget _listView(BuildContext context) {
    final shownTitle = title.isEmpty ? 'Collection title' : title;
    final meta =
        author.isNotEmpty
            ? 'by $author'
            : subtitle.isNotEmpty
            ? subtitle
            : null;
    final note = switch (focused) {
      _Field.subtitle when author.isNotEmpty =>
        'In the list, the author’s name takes the subtitle’s place.',
      _ => null,
    };
    return Column(
      key: const ValueKey('book_preview_list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 260,
          height: 140,
          child: _Spot(
            lit: coverLit,
            radius: 12,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: kWhiteColor.withValues(alpha: 0.18),
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(child: _plate(BoxFit.cover)),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: kBlack2Color.withValues(alpha: 0.65),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _Spot(
                            lit: focused == _Field.title,
                            child: Text(
                              shownTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color:
                                    title.isEmpty
                                        ? kWhiteColor.withValues(alpha: 0.5)
                                        : kWhiteColor,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                          if (meta != null || focused == _Field.author) ...[
                            const SizedBox(height: 2),
                            _Spot(
                              lit: focused == _Field.author,
                              child: Text(
                                meta ?? 'by Author',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: kWhiteColor.withValues(
                                    alpha: meta == null ? 0.5 : 0.7,
                                  ),
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                          if (gameCount > 0) ...[
                            const SizedBox(height: 2),
                            Text(
                              _plural(gameCount, 'game'),
                              style: TextStyle(
                                color: kWhiteColor.withValues(alpha: 0.55),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (note != null) ...[
          const SizedBox(height: 10),
          Text(
            note,
            style: const TextStyle(color: kWhiteColor70, fontSize: 12),
          ),
        ],
      ],
    );
  }

  /// The top of the collection's About page.
  Widget _pageView(BuildContext context) {
    final secondary = const TextStyle(
      color: kWhiteColor70,
      fontSize: 14,
      height: 20 / 14,
    );
    return Column(
      key: const ValueKey('book_preview_page'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cover != null || coverBytes != null || coverLit) ...[
              _Spot(
                lit: coverLit,
                radius: 6,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 72,
                    height: 108,
                    child: _plate(BoxFit.cover),
                  ),
                ),
              ),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Spot(
                    lit: focused == _Field.title,
                    child: Text(
                      title.isEmpty ? 'Collection title' : title,
                      style: TextStyle(
                        color:
                            title.isEmpty
                                ? kWhiteColor.withValues(alpha: 0.5)
                                : kWhiteColor,
                        fontSize: 20,
                        height: 26 / 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _line(
                    field: _Field.subtitle,
                    value: subtitle,
                    ghost: 'Subtitle',
                    style: secondary,
                    gap: 2,
                  ),
                  _line(
                    field: _Field.author,
                    value: author.isEmpty ? '' : 'by $author',
                    ghost: 'by Author',
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    gap: 6,
                    alwaysHold: true,
                  ),
                  _line(
                    field: _Field.year,
                    value: year,
                    ghost: 'Year',
                    style: secondary,
                    gap: 4,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'About this collection',
          style: TextStyle(
            color:
                about.isEmpty
                    ? kWhiteColor.withValues(alpha: 0.5)
                    : kWhiteColor,
            fontSize: 15,
            height: 20 / 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        _Spot(
          lit: focused == _Field.about,
          child: Text(
            about.isEmpty ? 'Your description goes here.' : about,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color:
                  about.isEmpty
                      ? kWhiteColor.withValues(alpha: 0.5)
                      : kWhiteColor,
              fontSize: 15,
              height: 22 / 15,
            ),
          ),
        ),
      ],
    );
  }

  /// One identity line. Empty, it is absent from the page; while its field is
  /// focused (or [alwaysHold], for a field submission needs) it holds its place
  /// with a ghost.
  Widget _line({
    required _Field field,
    required String value,
    required String ghost,
    required TextStyle style,
    required double gap,
    bool alwaysHold = false,
  }) {
    final lit = focused == field;
    if (value.isEmpty && !lit && !alwaysHold) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: gap),
      child: _Spot(
        lit: lit,
        child: Text(
          value.isEmpty ? ghost : value,
          style:
              value.isEmpty
                  ? style.copyWith(color: kWhiteColor.withValues(alpha: 0.5))
                  : style,
        ),
      ),
    );
  }
}

/// A spot in the preview, tinted while its field is being edited. The tint
/// sits inside a fixed inset, so lighting one never moves the layout.
class _Spot extends StatelessWidget {
  const _Spot({required this.lit, required this.child, this.radius = 4});

  final bool lit;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    const accent = kPrimaryColor;
    return AnimatedContainer(
      duration:
          MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      transform: Matrix4.translationValues(-4, 0, 0),
      decoration: BoxDecoration(
        color:
            lit ? accent.withValues(alpha: 0.14) : accent.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color:
              lit ? accent.withValues(alpha: 0.5) : accent.withValues(alpha: 0),
        ),
      ),
      child: child,
    );
  }
}
