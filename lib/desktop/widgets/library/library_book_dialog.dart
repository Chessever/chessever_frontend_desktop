import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/library_book_publication.dart';
import 'package:chessever/desktop/services/local_chess_drop_zone.dart'
    show chessFileDropHolds;
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/library/image_drop_zone.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/library/cover_crop_dialog.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/theme/app_theme.dart';

Future<void> showLibraryBookDialog(
  BuildContext context, {
  required LibraryFolder folder,
}) async {
  // The picture slots take file drops of their own: the chess-file zones
  // under the dialog stay quiet while it is open.
  chessFileDropHolds.value++;
  try {
    await _showLibraryBookDialog(context, folder: folder);
  } finally {
    chessFileDropHolds.value--;
  }
}

Future<void> _showLibraryBookDialog(
  BuildContext context, {
  required LibraryFolder folder,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierLabel: 'Collection publishing',
  barrierColor: Colors.black.withValues(alpha: 0.55),
  transitionDuration: const Duration(milliseconds: 180),
  // Opened from a menu, a few times a session: it arrives from just under
  // full size instead of appearing from nothing, and leaves faster than it
  // came. With reduced motion it only fades.
  transitionBuilder: (context, animation, _, child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: _easeOut,
      reverseCurve: Curves.easeIn,
    );
    final fade = FadeTransition(opacity: curved, child: child);
    if (MediaQuery.disableAnimationsOf(context)) return fade;
    return ScaleTransition(
      scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
      child: fade,
    );
  },
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

  /// The text each field last held, as far as this dialog knows. forui
  /// reports every controller notification as a change, a caret move and the
  /// dialog's own writes included; only a text that differs from this is
  /// something the user typed.
  final _seen = {for (final f in _Field.values) f: ''};

  /// Fills a field from the dialog itself (loaded details, the remembered
  /// author, a chosen suggestion). Never an edit.
  void _write(_Field field, String text) {
    _seen[field] = text;
    _fields[field]!.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

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

  // --- Author credit --------------------------------------------------------

  /// Me or Someone else. Seeded from the loaded book (new books start on Me).
  AuthorCredit _credit = AuthorCredit.self;

  /// Whether the loaded book already carried the authorCredit key, so a save
  /// keeps sending it even when the user leaves the credit on Me.
  bool _hadCreditKey = false;

  /// The credited author's own photo on the server. Uploaded as soon as it is
  /// chosen, like the cover; empty when none is set.
  String _authorPhotoUrl = '';
  Uint8List? _authorPhotoPreview;
  bool _authorPhotoBusy = false;

  /// Everyone credited after the first author, in the order they are shown.
  final List<_CoAuthor> _coAuthors = [];

  /// Whether the saved collection lists more than one author, so a save that
  /// removes them still tells the server.
  bool _hadAuthorList = false;

  bool get _anyPhotoBusy =>
      _authorPhotoBusy || _coAuthors.any((row) => row.busy);

  /// The signed-in account's profile photo, for the "Me" preview. Null when
  /// there is none (then a neutral silhouette is shown).
  String? _profilePhotoUrl;

  // --- Author suggestions ---------------------------------------------------

  Timer? _suggestTimer;
  int _suggestSeq = 0;
  List<AuthorSuggestion> _suggestions = const [];

  /// The name [_suggestions] answers. A list for an older spelling is never
  /// shown, and never counts as a match for what is typed now.
  String _suggestionsFor = '';

  /// The remembered own name was filled in, not typed: crediting someone else
  /// clears it instead of crediting them under the publisher's name.
  bool _authorPrefilled = false;

  bool get _creditsOther => _credit == AuthorCredit.other;

  @override
  void initState() {
    super.initState();
    _profilePhotoUrl = _readProfilePhoto();
    for (final entry in _focus.entries) {
      entry.value.addListener(() => _onFocus(entry.key, entry.value));
    }
    _load();
  }

  @override
  void dispose() {
    _stashTimer?.cancel();
    _suggestTimer?.cancel();
    // Leaving mid-edit still keeps the work.
    if (_dirty) _stashDraft();
    for (final field in _fields.values) {
      field.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    for (final row in _coAuthors) {
      row.dispose();
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
      _write(entry.key, entry.value);
    }
    // New books start on Me; a loaded book keeps whatever it was credited to.
    _credit = m.authorCredit ?? AuthorCredit.self;
    _hadCreditKey = value.hadAuthorCreditKey;
    _authorPhotoUrl = m.authorPhotoUrl;
    _authorPhotoPreview = null;
    _syncCoAuthors(m.coAuthors);
    _hadAuthorList = m.sendAuthorList;
    _suggestions = const [];
    _suggestionsFor = '';
    _authorPrefilled = false;
    // The remembered author only pre-fills a fresh "Me" collection.
    if (m.author.trim().isEmpty && _credit == AuthorCredit.self) {
      _prefillRemembered();
    }
    setState(() {
      _publication = value;
      _coverUrl = m.coverUrl;
      _confirmUnpublish = false;
      _dirty = false;
    });
  }

  /// The signed-in account's profile photo for the "Me" preview: an https
  /// `profile_avatar_url`, else https `avatar_url`, else null (silhouette).
  String? _readProfilePhoto() {
    try {
      final metadata =
          Supabase.instance.client.auth.currentUser?.userMetadata ??
          const <String, dynamic>{};
      for (final key in const ['profile_avatar_url', 'avatar_url']) {
        final raw = metadata[key];
        if (raw is! String) continue;
        final uri = Uri.tryParse(raw.trim());
        if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
          return uri.toString();
        }
      }
    } catch (_) {
      // No Supabase / no session: just no profile photo.
    }
    return null;
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
    final values = <String, Object>{
      for (final f in _Field.values) f.name: _text(f),
    };
    // The draft remembers which side of the Me / Someone-else choice the work
    // was on; the photo uploads immediately, so it is not in the draft.
    values['authorCredit'] = _credit.wire;
    values['coAuthors'] = _coAuthorNames;
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
    final draftCredit =
        AuthorCredit.maybeParse(draft['authorCredit']) ?? _credit;
    // A draft from before co-authors existed says nothing about them.
    final rawCoAuthors = draft['coAuthors'];
    final draftCoAuthors =
        rawCoAuthors is List
            ? [
              for (final name in rawCoAuthors)
                if (name is String && name.trim().isNotEmpty) name.trim(),
            ]
            : null;
    final differs =
        draftCredit != _credit ||
        (draftCoAuthors != null &&
            draftCoAuthors.join('\n') != _coAuthorNames.join('\n')) ||
        values.entries.any((e) => e.value.trim() != _text(e.key).trim());
    if (!differs) {
      await _clearDraft();
      return;
    }
    final resume = await _showResumeDialog();
    if (!mounted) return;
    if (resume == true) {
      setState(() {
        for (final e in values.entries) {
          _write(e.key, e.value);
        }
        _credit = draftCredit;
        if (draftCoAuthors != null) {
          _syncCoAuthors([
            for (final name in draftCoAuthors)
              BookAuthor(name: name, photoUrl: _rowNamed(name)?.photoUrl ?? ''),
          ]);
        }
        _authorPrefilled = false;
        _dirty = true;
      });
      _scheduleSuggestions();
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
      if (!mounted ||
          author.isEmpty ||
          field.text.trim().isNotEmpty ||
          _creditsOther) {
        return;
      }
      setState(() {
        _write(_Field.author, author);
        _authorPrefilled = true;
      });
    } catch (_) {
      // A missing preference only means no pre-fill.
    }
  }

  Future<void> _remember(LibraryBookMetadata metadata) async {
    // Only "Me" collections remember the author: a one-off credit to someone
    // else must not pre-fill the next, unrelated collection.
    if (_credit != AuthorCredit.self) return;
    final author = metadata.author.trim();
    if (author.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastAuthorKey, author);
    } catch (_) {}
  }

  // --- Save -----------------------------------------------------------------

  /// The authorCredit value to send, applying the spec's omit-vs-send rule:
  /// send "other" when the user credited someone else; send "self" (which also
  /// drops any credited photo) when a book that already carried the key is left
  /// on Me; otherwise null, so the key is absent — the only safe body for an
  /// old server that rejects unknown keys.
  AuthorCredit? get _authorCreditToSend {
    if (_credit == AuthorCredit.other) return AuthorCredit.other;
    return _hadCreditKey ? AuthorCredit.self : null;
  }

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
      authorCredit: _authorCreditToSend,
      // The server owns the photo URL; the save body never writes it.
      authorPhotoUrl: _authorPhotoUrl,
      coAuthors: [
        for (final row in _coAuthors)
          if (row.text.isNotEmpty)
            BookAuthor(name: row.text, photoUrl: row.photoUrl),
      ],
      sendAuthorList: _hadAuthorList || _coAuthorNames.isNotEmpty,
    );
  }

  Future<void> _save({bool publish = false, bool refreshGames = false}) async {
    if (_busy || _coverBusy || _anyPhotoBusy) return;
    _validateForPublish = publish;
    if (!_validateForm()) {
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
                  : saved.stage == LibraryBookStage.inReview
                  ? 'Changes saved. The collection is still in review.'
                  : 'Draft saved. This collection is private.',
      afterSuccess: (saved) {
        unawaited(_clearDraft());
        _remember(saved.metadata);
      },
    );
  }

  /// Out of Collections, or out of the review queue: the same withdrawal on
  /// the server, which keeps the private folder and the saved details. What is
  /// typed here and not yet saved stays in the form.
  Future<void> _leaveCollections({required String done}) => _mutate(
    () => ref.read(libraryBookPublisherProvider).unpublish(widget.folder),
    success: (_) => done,
    keepEdits: true,
  );

  Future<void> _mutate(
    Future<LibraryBookPublication> Function() action, {
    required String Function(LibraryBookPublication saved) success,
    void Function(LibraryBookPublication saved)? afterSuccess,
    bool keepEdits = false,
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
      if (keepEdits) {
        // Only where the collection stands changed; the typed fields are
        // untouched. What the server holds (cover, author photo, whether it
        // knows the credit) is taken from its answer.
        setState(() {
          _publication = value;
          _coverUrl = value.metadata.coverUrl;
          _takeAuthorPhotos(value.metadata);
          _hadCreditKey = value.hadAuthorCreditKey;
          _hadAuthorList = value.metadata.sendAuthorList;
          _confirmUnpublish = false;
        });
      } else {
        _setPublication(value);
      }
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
  ///
  /// [dropped] is an image dropped on the cover slot; without it the file
  /// dialog opens. Either way the author frames it before it is uploaded.
  Future<void> _pickCover({Uint8List? dropped}) async {
    if (_busy || _coverBusy) return;
    final Uint8List? image;
    try {
      image =
          dropped == null
              ? await ref.read(collectionCoverPickerProvider)(context)
              : await ref.read(collectionCoverFramerProvider)(context, dropped);
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
        if (!_validateForm()) {
          throw const LibraryBookPublicationException(
            'Add a title first. The cover is saved with the collection.',
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
                ? 'Cover saved. The collection is back in review until ChessEver approves it.'
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

  // --- Author credit: Me vs Someone else ------------------------------------

  /// "Me" or "Someone else". Crediting someone else clears a name that was
  /// only pre-filled with the publisher's own; going back to "Me" fills it in.
  /// A saved author photo is only dropped by the next save (self clears it
  /// server-side), which the form says while it is still there.
  void _setCredit(AuthorCredit credit) {
    if (_credit == credit || _busy || _authorPhotoBusy || _coverBusy) return;
    final author = _fields[_Field.author]!;
    setState(() {
      _credit = credit;
      _dirty = true;
      if (credit == AuthorCredit.other && _authorPrefilled) {
        _write(_Field.author, '');
        _authorPrefilled = false;
      }
      _suggestions = const [];
      _suggestionsFor = '';
      _error = null;
      _notice = null;
    });
    if (credit == AuthorCredit.self && author.text.trim().isEmpty) {
      _prefillRemembered();
    }
    _scheduleSuggestions();
    _scheduleStash();
  }

  /// Whether a saved author photo would be dropped by switching back to Me.
  bool get _switchToMeDropsPhoto =>
      _credit == AuthorCredit.self && _authorPhotoUrl.trim().isNotEmpty;

  /// The author name as the directory compares it: trimmed, single-spaced.
  String get _authorTerm =>
      _text(_Field.author).trim().replaceAll(RegExp(r'\s+'), ' ');

  void _onAuthorChanged(String value) {
    _authorPrefilled = false;
    if (!_dirty) setState(() => _dirty = true);
    _scheduleStash();
    _scheduleSuggestions();
  }

  /// Debounced author lookup. Below two characters, or on "Me", there is
  /// nothing to look up and whatever was listed goes away.
  void _scheduleSuggestions() {
    _suggestTimer?.cancel();
    final term = _authorTerm;
    if (!_creditsOther || term.length < 2) {
      _suggestSeq++;
      if (_suggestions.isNotEmpty || _suggestionsFor.isNotEmpty) {
        setState(() {
          _suggestions = const [];
          _suggestionsFor = '';
        });
      }
      return;
    }
    _suggestTimer = Timer(
      const Duration(milliseconds: 300),
      () => _fetchSuggestions(term),
    );
  }

  Future<void> _fetchSuggestions(String term) async {
    final seq = ++_suggestSeq;
    final List<AuthorSuggestion> items;
    try {
      items = await ref.read(libraryBookPublisherProvider).suggestAuthors(term);
    } catch (_) {
      // suggestAuthors never throws, but stay safe: just no suggestions.
      return;
    }
    // A later request, a changed name or a changed credit wins.
    if (!mounted || seq != _suggestSeq || !_creditsOther) return;
    if (_authorTerm != term) return;
    setState(() {
      _suggestions = items;
      _suggestionsFor = term;
    });
  }

  /// The existing author whose name is exactly the one typed, if any.
  AuthorSuggestion? get _matchedAuthor {
    final typed = _authorTerm.toLowerCase();
    if (typed.isEmpty || _suggestionsFor.toLowerCase() != typed) return null;
    for (final s in _suggestions) {
      if (s.name.trim().toLowerCase() == typed) return s;
    }
    return null;
  }

  /// Choosing a suggestion fills the exact spelling, so the credit groups
  /// with that existing author.
  void _useSuggestion(AuthorSuggestion suggestion) {
    setState(() {
      _write(_Field.author, suggestion.name);
      _authorPrefilled = false;
      _suggestions = [suggestion];
      _suggestionsFor = suggestion.name;
      _dirty = true;
    });
    _suggestTimer?.cancel();
    _suggestSeq++;
    _scheduleStash();
  }

  /// A square author photo, uploaded as soon as it is chosen (like the cover).
  /// Uploading sets the credit to Someone else, so stay there.
  Future<void> _pickAuthorPhoto({Uint8List? dropped}) async {
    if (_busy || _anyPhotoBusy || _coverBusy) return;
    final Uint8List? image;
    try {
      image =
          dropped == null
              ? await ref.read(authorPhotoPickerProvider)(context)
              : await ref.read(authorPhotoFramerProvider)(context, dropped);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
      return;
    }
    if (image == null || !mounted) return;
    final wasPublished = _publication?.isPublished ?? false;
    setState(() {
      _authorPhotoBusy = true;
      _authorPhotoPreview = image;
      _credit = AuthorCredit.other;
      _error = null;
      _notice = null;
    });
    try {
      final publisher = ref.read(libraryBookPublisherProvider);
      // The photo belongs to a saved book; save a private draft first when the
      // book was never saved, exactly like the cover flow.
      if (_publication?.bookId == null) {
        _validateForPublish = false;
        if (!_validateForm()) {
          throw const LibraryBookPublicationException(
            'Add a title first. The author photo is saved with the collection.',
          );
        }
        final saved = await publisher.save(widget.folder, _metadata);
        if (!mounted) return;
        _setPublication(saved);
        setState(() => _credit = AuthorCredit.other);
        unawaited(_clearDraft());
      }
      final result = await publisher.uploadAuthorPhoto(widget.folder, image);
      if (!mounted) return;
      setState(() {
        _publication = result;
        _takeAuthorPhotos(result.metadata);
        _credit = result.metadata.authorCredit ?? AuthorCredit.other;
        _hadCreditKey = _hadCreditKey || result.hadAuthorCreditKey;
        _notice =
            wasPublished
                ? 'Author photo saved. The collection is back in review until ChessEver approves it.'
                : 'Author photo saved.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _authorPhotoPreview = null;
          _error =
              error is LibraryBookPublicationException
                  ? error.message
                  : 'Could not save the author photo. Retry when connected.';
        });
      }
    } finally {
      if (mounted) setState(() => _authorPhotoBusy = false);
    }
  }

  Future<void> _removeAuthorPhoto() async {
    if (_busy || _authorPhotoBusy || _coverBusy) return;
    setState(() {
      _authorPhotoBusy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await ref
          .read(libraryBookPublisherProvider)
          .removeAuthorPhoto(widget.folder);
      if (!mounted) return;
      setState(() {
        _publication = result;
        _authorPhotoUrl = result.metadata.authorPhotoUrl;
        _authorPhotoPreview = null;
        _notice = 'Author photo removed.';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  error is LibraryBookPublicationException
                      ? error.message
                      : 'Could not remove the author photo. Retry when connected.',
        );
      }
    } finally {
      if (mounted) setState(() => _authorPhotoBusy = false);
    }
  }

  // --- More authors: everyone credited after the first ----------------------

  List<String> get _coAuthorNames => [
    for (final row in _coAuthors)
      if (row.text.isNotEmpty) row.text,
  ];

  _CoAuthor? _rowNamed(String name) {
    final wanted = name.trim().toLowerCase();
    for (final row in _coAuthors) {
      if (row.text.toLowerCase() == wanted) return row;
    }
    return null;
  }

  /// Takes [saved] as the list, keeping the row (its field, its photo preview)
  /// of every author who is still credited.
  void _syncCoAuthors(List<BookAuthor> saved) {
    final kept = <_CoAuthor>[];
    for (final author in saved) {
      final at = _coAuthors.indexWhere(
        (row) => row.text.toLowerCase() == author.name.toLowerCase(),
      );
      final row =
          at < 0 ? _CoAuthor(name: author.name) : _coAuthors.removeAt(at);
      row.photoUrl = author.photoUrl;
      kept.add(row);
    }
    final gone = List.of(_coAuthors);
    _coAuthors
      ..clear()
      ..addAll(kept);
    // Their fields are still on screen until the next frame.
    if (gone.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final row in gone) {
          row.dispose();
        }
      });
    }
  }

  /// What the server holds for every author's photo, after any upload.
  void _takeAuthorPhotos(LibraryBookMetadata saved) {
    _authorPhotoUrl = saved.authorPhotoUrl;
    for (final author in saved.coAuthors) {
      _rowNamed(author.name)?.photoUrl = author.photoUrl;
    }
  }

  /// Where [name] sits in the saved author list, the place its photo is
  /// stored against. -1 when the saved collection does not credit them yet.
  int _savedAuthorIndex(String name) {
    final wanted = name.trim().toLowerCase();
    final saved = _publication?.metadata.authors ?? const <BookAuthor>[];
    return saved.indexWhere((author) => author.name.toLowerCase() == wanted);
  }

  void _addCoAuthor() {
    if (_busy || _coAuthors.length + 1 >= libraryBookMaxAuthors) return;
    final row = _CoAuthor();
    setState(() {
      _coAuthors.add(row);
      _error = null;
      _notice = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _coAuthors.contains(row)) row.focus.requestFocus();
    });
  }

  void _removeCoAuthor(_CoAuthor row) {
    if (_busy || row.busy) return;
    final credited = row.text.isNotEmpty;
    setState(() {
      _coAuthors.remove(row);
      if (credited) _dirty = true;
      _error = null;
      _notice = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
    if (credited) _scheduleStash();
  }

  void _onCoAuthorChanged(_CoAuthor row, String value) {
    // Not an edit: a caret move, a focus change, or a write of ours.
    if (value == row.seen) return;
    row.seen = value;
    setState(() {
      _dirty = true;
      row.error = null;
    });
    _scheduleStash();
  }

  /// The form's own fields and the co-author rows, all checked (never only
  /// the first that fails), so every problem is marked at once.
  bool _validateForm() {
    final fields = _form.currentState?.validate() ?? false;
    var rows = true;
    setState(() {
      for (final row in _coAuthors) {
        row.error = _validateCoAuthor(row);
        if (row.error != null) rows = false;
      }
    });
    return fields && rows;
  }

  String? _validateCoAuthor(_CoAuthor row) {
    final value = row.text;
    // A row left empty credits nobody and is dropped on save.
    if (value.isEmpty) return null;
    if (!_authorNamed(value)) return 'Enter the author’s name.';
    final lower = value.toLowerCase();
    final above = [
      _authorTerm.toLowerCase(),
      for (final other in _coAuthors.takeWhile((other) => other != row))
        other.text.toLowerCase(),
    ];
    return above.contains(lower) ? 'Already credited above.' : null;
  }

  /// A co-author's square photo. It is stored against their place in the
  /// saved author list, so details that changed since the last save are
  /// saved first (as a private draft when the book was never saved).
  Future<void> _pickCoAuthorPhoto(_CoAuthor row, {Uint8List? dropped}) async {
    if (_busy || _anyPhotoBusy || _coverBusy) return;
    final name = row.text;
    if (name.isEmpty) {
      setState(() {
        _notice = null;
        _error = 'Add this author’s name first, then their photo.';
      });
      row.focus.requestFocus();
      return;
    }
    final Uint8List? image;
    try {
      image =
          dropped == null
              ? await ref.read(authorPhotoPickerProvider)(context)
              : await ref.read(authorPhotoFramerProvider)(context, dropped);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
      return;
    }
    if (image == null || !mounted) return;
    final wasPublished = _publication?.isPublished ?? false;
    setState(() {
      row.busy = true;
      row.preview = image;
      _error = null;
      _notice = null;
    });
    try {
      final publisher = ref.read(libraryBookPublisherProvider);
      if (_publication?.bookId == null || _savedAuthorIndex(name) < 0) {
        _validateForPublish = false;
        if (!_validateForm()) {
          throw const LibraryBookPublicationException(
            'Check the highlighted details first. The photo is saved with the collection.',
          );
        }
        final saved = await publisher.save(widget.folder, _metadata);
        if (!mounted) return;
        _setPublication(saved);
        unawaited(_clearDraft());
      }
      final index = _savedAuthorIndex(name);
      if (index < 0) {
        throw const LibraryBookPublicationException(
          'Save the collection details, then add this author’s photo.',
        );
      }
      final result = await publisher.uploadAuthorPhoto(
        widget.folder,
        image,
        index: index,
      );
      if (!mounted) return;
      setState(() {
        _publication = result;
        _takeAuthorPhotos(result.metadata);
        _notice =
            wasPublished
                ? 'Author photo saved. The collection is back in review until ChessEver approves it.'
                : 'Author photo saved.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          row.preview = null;
          _error =
              error is LibraryBookPublicationException
                  ? error.message
                  : 'Could not save the author photo. Retry when connected.';
        });
      }
    } finally {
      // The row itself, never a lookup by the name it had when the upload
      // began: a name edited meanwhile would leave it busy for good.
      if (mounted) setState(() => row.busy = false);
    }
  }

  Future<void> _removeCoAuthorPhoto(_CoAuthor row) async {
    if (_busy || _anyPhotoBusy || _coverBusy) return;
    final name = row.text;
    final index = _savedAuthorIndex(name);
    if (index < 0) {
      // Renamed since the last save: the server drops the photo with the name.
      setState(() {
        row.photoUrl = '';
        row.preview = null;
        _dirty = true;
      });
      return;
    }
    setState(() {
      row.busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await ref
          .read(libraryBookPublisherProvider)
          .removeAuthorPhoto(widget.folder, index: index);
      if (!mounted) return;
      setState(() {
        _publication = result;
        row.preview = null;
        row.photoUrl = '';
        _takeAuthorPhotos(result.metadata);
        _notice = 'Author photo removed.';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  error is LibraryBookPublicationException
                      ? error.message
                      : 'Could not remove the author photo. Retry when connected.',
        );
      }
    } finally {
      if (mounted) setState(() => row.busy = false);
    }
  }

  /// The authors after the first: a name and an optional photo each, and one
  /// more row for as long as there is room.
  Widget _coAuthorsSection(LibraryBookStage stage) {
    final enabled = !_busy && !_frozen(stage);
    final room = _coAuthors.length + 1 < libraryBookMaxAuthors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _OptionalLabel('More authors'),
          const SizedBox(height: 4),
          const Text(
            'Credited after the first author, in this order. Each can have a photo.',
            style: _noteStyle,
          ),
          const SizedBox(height: 6),
          for (final row in _coAuthors)
            _coAuthorRow(row, stage: stage, enabled: enabled),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child:
                room
                    ? DesktopDialogButton(
                      key: const ValueKey('book_author_add'),
                      label: 'Add an author',
                      icon: Icons.add_rounded,
                      onPress: enabled ? _addCoAuthor : null,
                    )
                    : const Text(
                      'A collection credits up to $libraryBookMaxAuthors authors.',
                      style: _noteStyle,
                    ),
          ),
        ],
      ),
    );
  }

  Widget _coAuthorRow(
    _CoAuthor row, {
    required LibraryBookStage stage,
    required bool enabled,
  }) {
    final at = _coAuthors.indexOf(row);
    final uri = _httpsUri(row.photoUrl);
    final hasPhoto = row.preview != null || uri != null;
    final canPhoto = enabled && !_anyPhotoBusy && !_coverBusy;
    final Widget face =
        row.preview != null
            ? Image.memory(row.preview!, fit: BoxFit.cover)
            : uri != null
            ? CachedNetworkImage(
              imageUrl: uri.toString(),
              fit: BoxFit.cover,
              placeholder: (_, _) => const _Silhouette(),
              errorWidget: (_, _, _) => const _Silhouette(),
            )
            : const _Silhouette();
    return ImageDropZone(
      key: ObjectKey(row),
      enabled: canPhoto,
      // Only the photo itself opens the file dialog; the rest of the row is
      // a name field. A dropped image lands anywhere on the row.
      tapToChoose: false,
      restingEdge: false,
      // The row keeps the form's left and right edges; the accent edge that
      // shows while a file is held over it is drawn just outside them.
      padding: const EdgeInsets.symmetric(vertical: 8),
      edgeOutset: 10,
      semanticsLabel: 'Author ${at + 2}',
      onChoose: () => _pickCoAuthorPhoto(row),
      onDropped: (bytes) => _pickCoAuthorPhoto(row, dropped: bytes),
      onRefused: (reason) => setState(() => _error = reason),
      builder:
          (context, phase) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Centred on each other by the row itself, whatever height the
              // field has; what follows the name sits under the field.
              Row(
                children: [
                  _PhotoButton(
                    key: ValueKey('book_coauthor_photo_$at'),
                    tooltip:
                        phase == ImageDropPhase.dragging
                            ? 'Drop to use this photo'
                            : hasPhoto
                            ? 'Replace photo'
                            : 'Choose photo',
                    onPress: canPhoto ? () => _pickCoAuthorPhoto(row) : null,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [face, if (row.busy) const _Uploading()],
                    ),
                  ),
                  const SizedBox(width: _coAuthorGap),
                  Expanded(
                    child: FTextField(
                      key: ValueKey('book_coauthor_name_$at'),
                      controller: row.name,
                      focusNode: row.focus,
                      enabled: enabled,
                      hint: 'e.g. Judit Polgar',
                      maxLength: 60,
                      maxLengthEnforcement: MaxLengthEnforcement.enforced,
                      counterBuilder:
                          (context, current, max, focused) =>
                              const SizedBox.shrink(),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r"[\p{L}\p{M} .'’\-,&]", unicode: true),
                        ),
                        const _TidySpacesFormatter(),
                      ],
                      textCapitalization: TextCapitalization.words,
                      onChange: (value) => _onCoAuthorChanged(row, value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogIconButton(
                    key: ValueKey('book_coauthor_remove_$at'),
                    icon: Icons.close_rounded,
                    tooltip: 'Remove this author',
                    onPress:
                        enabled && !row.busy
                            ? () => _removeCoAuthor(row)
                            : null,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(
                  left: _coAuthorPhoto + _coAuthorGap,
                  top: 6,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (row.error != null)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          row.error!,
                          style: const TextStyle(
                            color: kRedColor,
                            fontSize: 12,
                            height: 16 / 12,
                          ),
                        ),
                      ),
                    Wrap(
                      spacing: 14,
                      children: [
                        _QuietAction(
                          key: ValueKey('book_coauthor_choose_$at'),
                          label:
                              row.busy
                                  ? 'Saving photo…'
                                  : phase == ImageDropPhase.dragging
                                  ? 'Drop to use this photo'
                                  : hasPhoto
                                  ? 'Replace photo'
                                  : 'Drop a photo here, or choose one…',
                          lit: phase == ImageDropPhase.dragging,
                          onPress:
                              canPhoto ? () => _pickCoAuthorPhoto(row) : null,
                        ),
                        if (hasPhoto && !row.busy)
                          _QuietAction(
                            key: ValueKey('book_coauthor_photo_remove_$at'),
                            label: 'Remove photo',
                            onPress:
                                canPhoto
                                    ? () => _removeCoAuthorPhoto(row)
                                    : null,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
    );
  }

  // --- Author section: credit switch, name, suggestions, photo --------------

  Widget _authorSection(LibraryBookStage stage) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Author', style: _labelStyle),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: _Segmented(
              key: const ValueKey('book_author_credit'),
              semanticsLabel: 'Who is this collection credited to?',
              labels: const ['Me', 'Someone else'],
              index: _creditsOther ? 1 : 0,
              enabled:
                  !_busy && !_anyPhotoBusy && !_coverBusy && !_frozen(stage),
              onChanged:
                  (i) => _setCredit(
                    i == 1 ? AuthorCredit.other : AuthorCredit.self,
                  ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // The section's own "Author" names this field; a second label under
        // the switch would only repeat it.
        _field(
          _Field.author,
          stage: stage,
          where:
              _creditsOther
                  ? 'The person who wrote or compiled it, credited as “by …” in the list and on the page. Pick a name below if they’re already on ChessEver, so their collections stay together.'
                  : 'Credited as “by …” in the list and on the page.',
          hint: 'e.g. Magnus Carlsen',
          limit: 60,
        ),
        // The match, the suggestions and the "Me" row all follow the name.
        ListenableBuilder(
          listenable: _fields[_Field.author]!,
          builder: (context, _) => _authorExtras(stage),
        ),
        _coAuthorsSection(stage),
      ],
    );
  }

  /// Under the name: for "Me", the profile photo it is pictured with; for
  /// someone else, existing ChessEver names to match and their own photo.
  Widget _authorExtras(LibraryBookStage stage) {
    final name = _text(_Field.author).trim();
    if (!_creditsOther) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _AuthorAvatar(
                  url: _profilePhotoUrl,
                  size: 40,
                  semanticsLabel: 'Your profile photo',
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? 'Author name' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              name.isEmpty
                                  ? kWhiteColor.withValues(alpha: 0.4)
                                  : kWhiteColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Your ChessEver profile photo is shown with your name.',
                        style: _noteStyle,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_switchToMeDropsPhoto) ...[
              const SizedBox(height: 10),
              Semantics(
                liveRegion: true,
                child: const Text(
                  'The saved author photo will be removed when you save.',
                  style: TextStyle(color: kRedColor, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      );
    }
    final matched = _matchedAuthor;
    // The last answer stays while the next lookup is on its way, so the form
    // below does not jump on every keystroke. Only a match hides it.
    final showList = matched == null && _suggestions.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showList) _suggestionList(),
        if (matched != null)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Text(
              'Matches an existing ChessEver author.',
              style: TextStyle(
                color: kGreenColor2,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        _authorPhotoTile(stage, matched),
      ],
    );
  }

  Widget _suggestionList() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kWhiteColor.withValues(alpha: 0.035),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(14, 0, 14, 2),
                child: Text('Already on ChessEver', style: _noteStyle),
              ),
              for (final suggestion in _suggestions)
                _SuggestionRow(
                  suggestion: suggestion,
                  onTap: _busy ? null : () => _useSuggestion(suggestion),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The credited author's own photo: a circle with Choose / Replace and
  /// Remove. Not the profile photo and not the cover.
  Widget _authorPhotoTile(LibraryBookStage stage, AuthorSuggestion? matched) {
    final uri = _httpsUri(_authorPhotoUrl);
    final hasPhoto = _authorPhotoPreview != null || uri != null;
    // With no photo of their own yet, an author already on ChessEver is
    // pictured by the photo they have there.
    final borrowed = !hasPhoto ? _httpsUri(matched?.avatarUrl ?? '') : null;
    final enabled = !_busy && !_anyPhotoBusy && !_coverBusy && !_frozen(stage);
    final Widget thumb =
        _authorPhotoPreview != null
            ? Image.memory(_authorPhotoPreview!, fit: BoxFit.cover)
            : (uri ?? borrowed) != null
            ? CachedNetworkImage(
              imageUrl: (uri ?? borrowed).toString(),
              fit: BoxFit.cover,
              placeholder: (_, _) => const _Silhouette(),
              errorWidget: (_, _, _) => const _Silhouette(),
            )
            : const _Silhouette();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _OptionalLabel('Author photo'),
          const SizedBox(height: 10),
          ImageDropZone(
            key: const ValueKey('author_photo_drop'),
            enabled: enabled,
            semanticsLabel:
                'Author photo. Drop an image here, or choose a file.',
            onChoose: _pickAuthorPhoto,
            onDropped: (bytes) => _pickAuthorPhoto(dropped: bytes),
            onRefused: (reason) => setState(() => _error = reason),
            builder:
                (context, phase) => Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Semantics(
                      image: true,
                      label: hasPhoto ? 'Author photo' : 'No author photo yet',
                      child: ClipOval(
                        child: SizedBox.square(
                          dimension: 64,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              thumb,
                              if (_authorPhotoBusy) const _Uploading(),
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
                          _DropPrompt(
                            phase: phase,
                            rest:
                                hasPhoto
                                    ? 'Drop a new photo here to replace it'
                                    : 'Drop a photo here',
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              DesktopDialogButton(
                                key: const ValueKey('author_photo_choose'),
                                label:
                                    _authorPhotoBusy
                                        ? 'Saving photo…'
                                        : hasPhoto
                                        ? 'Replace photo'
                                        : 'Choose photo…',
                                onPress: enabled ? _pickAuthorPhoto : null,
                              ),
                              if (hasPhoto && !_authorPhotoBusy)
                                DesktopDialogButton(
                                  key: const ValueKey('author_photo_remove'),
                                  label: 'Remove photo',
                                  tone: DesktopDialogButtonTone.ghost,
                                  onPress: enabled ? _removeAuthorPhoto : null,
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            borrowed != null
                                ? 'Using the photo already on ChessEver for this author.'
                                : stage == LibraryBookStage.live
                                ? 'A square photo of the author, not your profile photo. On a live collection, a new photo goes back to review first.'
                                : 'A square photo of the author, not your profile photo. JPEG, PNG or WebP, at least 256 × 256.',
                            style: _noteStyle,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
          ),
        ],
      ),
    );
  }

  /// The cover: a 2:3 thumbnail with Choose / Replace and Remove. It is the
  /// collection's own image, not the profile photo shown for the author.
  Widget _coverPicker(LibraryBookStage stage) {
    final url = _coverUri(_coverUrl);
    final hasCover = _coverPreview != null || url != null;
    final enabled = !_busy && !_coverBusy && !_frozen(stage);
    final Widget thumb =
        _coverPreview != null
            ? Image.memory(_coverPreview!, fit: BoxFit.cover)
            : url != null
            ? CachedNetworkImage(
              imageUrl: url.toString(),
              fit: BoxFit.cover,
              placeholder: (_, _) => const _StackedBoardsPlate(),
              errorWidget: (_, _, _) => const _StackedBoardsPlate(),
            )
            : const _StackedBoardsPlate();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _OptionalLabel('Cover'),
          const SizedBox(height: 10),
          ImageDropZone(
            key: const ValueKey('book_cover_drop'),
            enabled: enabled,
            semanticsLabel: 'Cover. Drop an image here, or choose a file.',
            onChoose: _pickCover,
            onDropped: (bytes) => _pickCover(dropped: bytes),
            onRefused: (reason) => setState(() => _error = reason),
            builder:
                (context, phase) => Row(
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
                              if (_coverBusy) const _Uploading(),
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
                          _DropPrompt(
                            phase: phase,
                            rest:
                                hasCover
                                    ? 'Drop a new image here to replace it'
                                    : 'Drop an image here',
                          ),
                          const SizedBox(height: 8),
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
                          const SizedBox(height: 8),
                          Text(
                            stage == LibraryBookStage.live
                                ? 'You frame it as a 2:3 portrait after choosing. On a live collection, a new cover goes back to review first.'
                                : 'You frame it as a 2:3 portrait after choosing. JPEG, PNG or WebP, at least 600 × 900. Without one, the stacked boards are shown.',
                            style: _noteStyle,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
          ),
        ],
      ),
    );
  }

  String _errorText(Object error) =>
      error is LibraryBookPublicationException
          ? error.message
          : 'Could not load or save this collection. Your entered details have been kept. Retry in a moment.';

  // --- Validation (desktop draft-vs-submit semantics) -----------------------

  String? _validate(_Field field, String? raw) {
    final value = raw?.trim() ?? '';
    switch (field) {
      case _Field.title:
        if (value.isEmpty) return 'Enter a collection title.';
        return value.length < 3 ? 'Use at least 3 characters.' : null;
      case _Field.subtitle:
        return value.isNotEmpty &&
                value.toLowerCase() == _text(_Field.title).trim().toLowerCase()
            ? 'Say something the title doesn’t.'
            : null;
      case _Field.author:
        if (value.isEmpty) {
          // With nobody first, the server would move a co-author up into
          // this place and file their photo as the first author's.
          if (_coAuthorNames.isNotEmpty) {
            return 'Name the first author before adding more.';
          }
          // Otherwise required only when submitting for publication.
          return _validateForPublish ? 'Credit the author by name.' : null;
        }
        return _authorNamed(value) ? null : 'Enter the author’s name.';
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

  /// A name has at least two letters in a row, in any script.
  static bool _authorNamed(String value) =>
      RegExp(r'\p{L}{2}', unicode: true).hasMatch(value);

  /// What a submission still needs, in the order the form asks for it. The
  /// server refuses the same things; this says so before the round trip.
  List<({_Field field, String label, bool done})> get _requirements => [
    (
      field: _Field.title,
      label: 'Title',
      done: _text(_Field.title).trim().length >= 3,
    ),
    (
      field: _Field.author,
      label: 'Author credit',
      done: _authorNamed(_text(_Field.author).trim()),
    ),
    (
      field: _Field.about,
      label: 'Description',
      done: _text(_Field.about).trim().isNotEmpty,
    ),
  ];

  /// A collection ChessEver took down takes no change from its owner.
  bool _frozen(LibraryBookStage stage) => stage == LibraryBookStage.takenDown;

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final publication = _publication;
    final stage = publication?.stage ?? LibraryBookStage.draft;
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
            semanticsLabel: 'Collection publishing',
            constraints: BoxConstraints(
              maxWidth: maxWidth.toDouble(),
              maxHeight: size.height - 48,
            ),
            builder:
                (context, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(28, 22, 20, 16),
                      child: _header(stage),
                    ),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(28, 8, 28, 40),
                        child: Text(
                          'Loading collection details…',
                          style: TextStyle(color: kWhiteColor70, fontSize: 13),
                        ),
                      )
                    else if (publication == null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _error ?? 'Could not load this collection.',
                              style: const TextStyle(
                                color: kWhiteColor70,
                                fontSize: 13,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 16),
                            DesktopDialogButton(label: 'Retry', onPress: _load),
                          ],
                        ),
                      )
                    else ...[
                      if (stage != LibraryBookStage.draft)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
                          child: _StageBand(publication: publication),
                        ),
                      Flexible(
                        child: _body(
                          publication: publication,
                          stage: stage,
                          twoColumn: twoColumn,
                        ),
                      ),
                      _footer(stage),
                    ],
                  ],
                ),
          ),
        ),
      ),
    );
  }

  Widget _header(LibraryBookStage stage) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              switch (stage) {
                LibraryBookStage.draft => 'Publish collection',
                LibraryBookStage.inReview => 'Collection in review',
                LibraryBookStage.changesRequested => 'Changes requested',
                LibraryBookStage.live => 'Edit collection',
                LibraryBookStage.takenDown => 'Collection taken down',
              },
              style: const TextStyle(
                fontSize: 20,
                height: 26 / 20,
                fontWeight: FontWeight.w600,
                color: kWhiteColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'From your folder ${widget.folder.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: kWhiteColor.withValues(alpha: 0.6),
                fontSize: 13,
                height: 18 / 13,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 16),
      DesktopDialogIconButton(
        icon: Icons.close_rounded,
        tooltip: 'Close',
        onPress: _busy ? null : () => Navigator.of(context).maybePop(),
      ),
    ],
  );

  Widget _body({
    required LibraryBookPublication publication,
    required LibraryBookStage stage,
    required bool twoColumn,
  }) {
    final form = _formColumn(stage);
    final preview = _previewColumn(publication, stage);
    if (!twoColumn) {
      return _FadingScroll(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [preview, const SizedBox(height: 24), form],
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 11,
          child: _FadingScroll(
            padding: const EdgeInsets.fromLTRB(28, 0, 22, 20),
            child: form,
          ),
        ),
        // The preview keeps its place while the form scrolls beside it.
        Expanded(
          flex: 9,
          child: _FadingScroll(
            padding: const EdgeInsets.fromLTRB(6, 0, 28, 20),
            child: preview,
          ),
        ),
      ],
    );
  }

  Widget _formColumn(LibraryBookStage stage) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // What submitting does, for as long as there is something to submit.
          if (!_frozen(stage)) ...[
            Text(
              'Submitting sends this folder and its nested games to ChessEver for review. Include only content you have permission to share. Up to 1,000 games and 10 MB of PGN.',
              style: TextStyle(
                color: kWhiteColor.withValues(alpha: 0.6),
                fontSize: 12,
                height: 18 / 12,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Everything is needed to submit unless marked Optional.',
              style: _noteStyle,
            ),
            const SizedBox(height: 20),
          ],
          _field(
            _Field.title,
            stage: stage,
            label: 'Title',
            where: 'The name readers see in the list and on top of the page.',
            hint: 'e.g. Carlsen’s Best Endgames',
            limit: 80,
          ),
          _field(
            _Field.subtitle,
            stage: stage,
            label: 'Subtitle',
            optional: true,
            where:
                'One short line under the title on the collection page. It adds detail the title leaves out.',
            hint: 'e.g. 40 annotated wins, 2013–2023',
            limit: 120,
            counter: true,
          ),
          _authorSection(stage),
          // A year is four digits: the field is as wide as what it holds.
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: _field(
                _Field.year,
                stage: stage,
                label: 'Year',
                optional: true,
                where: 'Shown on the page under the author.',
                hint: 'e.g. ${DateTime.now().year}',
                limit: 4,
              ),
            ),
          ),
          _field(
            _Field.about,
            stage: stage,
            label: 'Description',
            where: 'Opens the page under “About this collection”.',
            hint:
                'What’s inside, who it’s for, and what readers will take away.',
            lines: 4,
            limit: 1500,
            counter: true,
          ),
          _coverPicker(stage),
        ],
      ),
    );
  }

  /// The dialog's foot never scrolls away: where the collection stands, what
  /// just happened, and what can be done next.
  Widget _footer(LibraryBookStage stage) {
    final message = _error ?? _notice;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: kWhiteColor.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Two pixels are always held, so the row below never shifts when a
          // save starts or ends.
          SizedBox(
            height: 2,
            child:
                _busy
                    ? LinearProgressIndicator(
                      minHeight: 2,
                      color: kPrimaryColor,
                      backgroundColor: kPrimaryColor.withValues(alpha: 0.12),
                    )
                    : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_busy || message != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _busy
                          ? 'Saving… Large folders may take a few minutes. Keep this window open.'
                          : message!,
                      style: TextStyle(
                        color:
                            !_busy && _error != null
                                ? kRedColor
                                : kWhiteColor70,
                        fontSize: 13,
                        height: 18 / 13,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _confirmUnpublish
                    ? _unpublishConfirm()
                    : Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 20,
                      runSpacing: 12,
                      children: [_StageTrack(stage: stage), _actions(stage)],
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _unpublishConfirm() => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 20,
    runSpacing: 12,
    children: [
      const Text(
        'Remove this collection from Collections? Your private folder and its details are kept.',
        style: TextStyle(color: kWhiteColor70, fontSize: 13, height: 18 / 13),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          DesktopDialogButton(
            label: 'Keep published',
            tone: DesktopDialogButtonTone.ghost,
            onPress:
                _busy ? null : () => setState(() => _confirmUnpublish = false),
          ),
          DesktopDialogButton(
            label: 'Unpublish collection',
            tone: DesktopDialogButtonTone.danger,
            onPress:
                _busy
                    ? null
                    : () => _leaveCollections(
                      done:
                          'Collection unpublished. Your private folder is unchanged.',
                    ),
          ),
        ],
      ),
    ],
  );

  Widget _actions(LibraryBookStage stage) {
    final idle = !_busy && !_coverBusy && !_authorPhotoBusy;
    // Submitting always sends the folder's current games along; "Submit
    // changes" sends the details only.
    final submitLatest =
        idle ? () => _save(publish: true, refreshGames: true) : null;
    final submitDetails = idle ? () => _save(publish: true) : null;
    final saveDraft = idle ? () => _save() : null;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: switch (stage) {
        LibraryBookStage.draft => [
          DesktopDialogButton(
            label: 'Save draft',
            tone: DesktopDialogButtonTone.ghost,
            onPress: saveDraft,
          ),
          DesktopDialogButton(
            label: 'Submit for approval',
            icon: Icons.north_east_rounded,
            tone: DesktopDialogButtonTone.primary,
            onPress: submitLatest,
          ),
        ],
        LibraryBookStage.changesRequested => [
          DesktopDialogButton(
            label: 'Save draft',
            tone: DesktopDialogButtonTone.ghost,
            onPress: saveDraft,
          ),
          DesktopDialogButton(
            label: 'Resubmit for approval',
            icon: Icons.north_east_rounded,
            tone: DesktopDialogButtonTone.primary,
            onPress: submitLatest,
          ),
        ],
        // Not public yet: taking it back only leaves the review queue.
        LibraryBookStage.inReview => [
          DesktopDialogButton(
            label: 'Withdraw from review',
            tone: DesktopDialogButtonTone.ghost,
            onPress:
                idle
                    ? () => _leaveCollections(
                      done:
                          'Withdrawn from review. This collection is a private draft.',
                    )
                    : null,
          ),
          DesktopDialogButton(label: 'Submit changes', onPress: submitDetails),
          DesktopDialogButton(
            label: 'Submit with latest games',
            tone: DesktopDialogButtonTone.primary,
            onPress: submitLatest,
          ),
        ],
        // A live collection cannot keep a private edit: the server returns
        // any change to review, so every save here is a submission.
        LibraryBookStage.live => [
          DesktopDialogButton(
            label: 'Unpublish',
            tone: DesktopDialogButtonTone.ghost,
            onPress:
                idle ? () => setState(() => _confirmUnpublish = true) : null,
          ),
          DesktopDialogButton(label: 'Submit changes', onPress: submitDetails),
          DesktopDialogButton(
            label: 'Submit with latest games',
            tone: DesktopDialogButtonTone.primary,
            onPress: submitLatest,
          ),
        ],
        LibraryBookStage.takenDown => [
          DesktopDialogButton(
            label: 'Close',
            onPress: () => Navigator.of(context).maybePop(),
          ),
        ],
      },
    );
  }

  Widget _previewColumn(
    LibraryBookPublication publication,
    LibraryBookStage stage,
  ) {
    return DecoratedBox(
      // The app's own ground: the collection is previewed on what it sits on.
      decoration: BoxDecoration(
        color: kBackgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Expanded(
                  child: Text(
                    'Preview',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Flexible(
                  child: Text(
                    'As readers see it in Collections',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _noteStyle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _Segmented(
              semanticsLabel: 'Preview',
              labels: const ['In the list', 'Collection page'],
              index: _previewTab,
              enabled: !_busy,
              onChanged: (i) => setState(() => _previewTab = i),
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: Listenable.merge([
                ..._fields.values,
                for (final row in _coAuthors) row.name,
              ]),
              builder:
                  (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _BookPreview(
                        page: _previewTab == 1,
                        title: _text(_Field.title).trim(),
                        subtitle: _text(_Field.subtitle).trim(),
                        author: bookAuthorCredit([
                          _text(_Field.author),
                          ..._coAuthorNames,
                        ]),
                        year: _text(_Field.year).trim(),
                        about: _text(_Field.about).trim(),
                        cover: _coverUri(_coverUrl),
                        coverBytes: _coverPreview,
                        coverLit: _coverBusy,
                        publisher: publication.metadata.publisher.trim(),
                        gameCount: publication.gameCount,
                        focused: _focused,
                      ),
                      if (stage == LibraryBookStage.draft ||
                          stage == LibraryBookStage.changesRequested) ...[
                        const SizedBox(height: 20),
                        _checklist(),
                      ],
                    ],
                  ),
            ),
          ],
        ),
      ),
    );
  }

  /// What is still missing before the collection can be submitted. Choosing
  /// a missing item takes the cursor to its field.
  Widget _checklist() {
    final items = _requirements;
    final left = items.where((item) => !item.done).length;
    return Column(
      key: const ValueKey('book_requirements'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            const Expanded(
              child: Text(
                'Before you submit',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              left == 0
                  ? 'Ready to submit'
                  : left == 1
                  ? '1 detail left'
                  : '$left details left',
              style: TextStyle(
                color: left == 0 ? kGreenColor2 : kWhiteColor70,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final item in items)
          _RequirementRow(
            label: item.label,
            done: item.done,
            onTap: item.done ? null : () => _focus[item.field]!.requestFocus(),
          ),
      ],
    );
  }

  Widget _field(
    _Field field, {
    required LibraryBookStage stage,
    String? label,
    required String where,
    required String hint,
    bool optional = false,
    bool counter = false,
    int lines = 1,
    required int limit,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: FTextFormField(
        controller: _fields[field],
        focusNode: _focus[field],
        autofocus: field == _Field.title,
        enabled: !_busy && !_frozen(stage),
        label:
            label == null
                ? null
                : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label),
                    if (optional) ...[
                      const SizedBox(width: 6),
                      const Text('Optional', style: _optionalStyle),
                    ],
                  ],
                ),
        // One quiet size for every helper line in the dialog.
        description: Text(where, style: _noteStyle),
        hint: hint,
        maxLines: lines,
        minLines: lines == 1 ? 1 : lines,
        maxLength: limit,
        // Hard-cap every field; the `counter` flag only decides whether the
        // running count is shown (Subtitle, Description).
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
        onChange: (value) {
          // Not an edit: a caret move, a focus change, or a write of ours.
          if (value == _seen[field]) return;
          _seen[field] = value;
          if (field == _Field.author) {
            _onAuthorChanged(value);
            return;
          }
          if (!_dirty) setState(() => _dirty = true);
          _scheduleStash();
        },
        validator: (raw) => _validate(field, raw),
      ),
    );
  }
}

/// A co-author's round photo, and the space between it and the name field.
const _coAuthorPhoto = 40.0;
const _coAuthorGap = 12.0;

/// One more credited author in the form: their name field and their photo.
class _CoAuthor {
  _CoAuthor({String name = ''})
    : name = TextEditingController(text: name),
      seen = name;

  final TextEditingController name;
  final FocusNode focus = FocusNode();

  /// The text the field last held as far as the dialog knows (forui reports
  /// caret moves as changes too).
  String seen;
  String photoUrl = '';
  Uint8List? preview;
  bool busy = false;

  /// What is wrong with the name, shown under the field after a save tries.
  String? error;

  /// The name as it is saved: trimmed, single-spaced.
  String get text => name.text.trim().replaceAll(RegExp(r'\s+'), ' ');

  void dispose() {
    name.dispose();
    focus.dispose();
  }
}

/// The line inside a picture slot that says what a drop does there.
class _DropPrompt extends StatelessWidget {
  const _DropPrompt({required this.phase, required this.rest});

  final ImageDropPhase phase;
  final String rest;

  @override
  Widget build(BuildContext context) {
    final dragging = phase == ImageDropPhase.dragging;
    return Text(
      dragging ? 'Drop to use this image' : rest,
      style: TextStyle(
        color: dragging ? kPrimaryColor : kWhiteColor,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// A co-author's round photo, pressed to choose or replace it.
class _PhotoButton extends StatefulWidget {
  const _PhotoButton({
    super.key,
    required this.tooltip,
    required this.onPress,
    required this.child,
  });

  final String tooltip;
  final VoidCallback? onPress;
  final Widget child;

  @override
  State<_PhotoButton> createState() => _PhotoButtonState();
}

class _PhotoButtonState extends State<_PhotoButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPress != null;
    final still = MediaQuery.disableAnimationsOf(context);
    return DesktopTooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.tooltip,
        child: FocusableActionDetector(
          enabled: enabled,
          mouseCursor:
              enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onShowHoverHighlight: (value) => setState(() => _hovered = value),
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => widget.onPress?.call(),
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
            onTapCancel: () => setState(() => _pressed = false),
            onTapUp: (_) => setState(() => _pressed = false),
            onTap: widget.onPress,
            child: AnimatedScale(
              scale: _pressed && !still ? 0.96 : 1,
              duration: const Duration(milliseconds: 120),
              curve: _easeOut,
              child: DecoratedBox(
                // The ring is the photo's own edge, lit while it can be pressed.
                decoration: ShapeDecoration(
                  shape: CircleBorder(
                    side: BorderSide(
                      width: 1.5,
                      strokeAlign: BorderSide.strokeAlignOutside,
                      color:
                          _focused
                              ? kPrimaryColor
                              : kWhiteColor.withValues(
                                alpha: _hovered && enabled ? 0.45 : 0.14,
                              ),
                    ),
                  ),
                ),
                child: ClipOval(
                  child: SizedBox.square(
                    dimension: _coAuthorPhoto,
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small text action under a field: quiet at rest, white under the pointer.
class _QuietAction extends StatefulWidget {
  const _QuietAction({
    super.key,
    required this.label,
    required this.onPress,
    this.lit = false,
  });

  final String label;
  final VoidCallback? onPress;

  /// Drawn in the accent, while a file is held over the row.
  final bool lit;

  @override
  State<_QuietAction> createState() => _QuietActionState();
}

class _QuietActionState extends State<_QuietAction> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPress != null;
    final color =
        widget.lit
            ? kPrimaryColor
            : !enabled
            ? kWhiteColor.withValues(alpha: 0.35)
            : _hovered || _focused
            ? kWhiteColor
            : kWhiteColor70;
    return Semantics(
      button: true,
      enabled: enabled,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => widget.onPress?.call(),
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPress,
          child: Padding(
            // A taller target than the 12 px line it holds.
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 120),
              curve: _easeOut,
              // Merged, so the line keeps the dialog's typeface.
              style: DefaultTextStyle.of(context).style.copyWith(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 16 / 12,
              ),
              child: Text(widget.label),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Shared type ---------------------------------------------------------

/// Matches the weight forui gives a field label, so the hand-laid labels
/// (Author, Cover, Author photo) sit level with Title and Description.
const _labelStyle = TextStyle(
  color: kWhiteColor,
  fontSize: 14,
  fontWeight: FontWeight.w600,
);

const _optionalStyle = TextStyle(
  // 55% white is the quietest small text that still clears 4.5:1 here.
  color: Color(0x8CFFFFFF),
  fontSize: 12,
  fontWeight: FontWeight.w400,
);

/// The quiet line under a control: where it shows, what it accepts.
const _noteStyle = TextStyle(
  color: Color(0x8CFFFFFF),
  fontSize: 12,
  height: 16 / 12,
);

/// The dialog's own strong ease-out: quick to answer, soft to land.
const _easeOut = Cubic(0.23, 1, 0.32, 1);

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

/// "Oct 2", or "Oct 2, 2025" for another year.
String _day(DateTime when) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final day = '${months[when.month - 1]} ${when.day}';
  return when.year == DateTime.now().year ? day : '$day, ${when.year}';
}

/// Same https-only link check as the cover; reused for author photos and
/// suggestion avatars.
Uri? _httpsUri(String raw) => _coverUri(raw);

/// A scroll view whose content dissolves at an edge that hides more of it,
/// rather than a line of text being sliced flat by the header or the footer.
/// At rest at the top (or the bottom) that edge is left untouched.
class _FadingScroll extends StatefulWidget {
  const _FadingScroll({required this.padding, required this.child});

  final EdgeInsets padding;
  final Widget child;

  @override
  State<_FadingScroll> createState() => _FadingScrollState();
}

class _FadingScrollState extends State<_FadingScroll> {
  static const _fade = 20.0;
  final _controller = ScrollController();
  bool _above = false;
  bool _below = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_measure);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _measure() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final above = position.pixels > 0.5;
    final below = position.pixels < position.maxScrollExtent - 0.5;
    if (above != _above || below != _below) {
      setState(() {
        _above = above;
        _below = below;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      // The content grows and shrinks (suggestions, the author photo) without
      // a scroll; the edges are measured again when it does.
      // Dispatched after layout, outside a build, so the edges can be
      // measured (and repainted) at once.
      onNotification: (_) {
        _measure();
        return false;
      },
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) {
          final edge =
              bounds.height <= 0
                  ? 0.0
                  : (_fade / bounds.height).clamp(0.0, 0.5);
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _above ? Colors.transparent : Colors.black,
              Colors.black,
              Colors.black,
              _below ? Colors.transparent : Colors.black,
            ],
            stops: [0, edge, 1 - edge, 1],
          ).createShader(bounds);
        },
        child: SingleChildScrollView(
          controller: _controller,
          padding: widget.padding,
          child: widget.child,
        ),
      ),
    );
  }
}

/// A label with the quiet "Optional" beside it, for the two image pickers.
class _OptionalLabel extends StatelessWidget {
  const _OptionalLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Text(label, style: _labelStyle),
      const SizedBox(width: 6),
      const Text('Optional', style: _optionalStyle),
    ],
  );
}

/// The veil over a thumbnail while its upload is in flight.
class _Uploading extends StatelessWidget {
  const _Uploading();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black.withValues(alpha: 0.45),
    child: const Center(
      child: SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: kWhiteColor),
      ),
    ),
  );
}

/// One choice out of a few, all visible: Me / Someone else, and the two
/// preview views. The raised fill slides to the chosen option; each option is
/// a real focus stop that Enter and Space choose.
class _Segmented extends StatelessWidget {
  const _Segmented({
    super.key,
    required this.semanticsLabel,
    required this.labels,
    required this.index,
    required this.onChanged,
    this.enabled = true,
  });

  final String semanticsLabel;
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final last = labels.length - 1;
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: Opacity(
        // A switch that takes no change right now reads as one.
        opacity: enabled ? 1 : 0.5,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: kWhiteColor.withValues(alpha: 0.045),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedAlign(
                    alignment: Alignment(
                      last == 0 ? 0 : -1 + 2 * index / last,
                      0,
                    ),
                    duration:
                        still
                            ? Duration.zero
                            : const Duration(milliseconds: 200),
                    curve: _easeOut,
                    child: FractionallySizedBox(
                      widthFactor: 1 / labels.length,
                      heightFactor: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A2D),
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      Expanded(
                        child: _Segment(
                          label: labels[i],
                          selected: i == index,
                          onTap: enabled ? () => onChanged(i) : null,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Segment extends StatefulWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: onTap != null,
      onTap: onTap,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: onTap != null,
        mouseCursor:
            onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: _focused ? kPrimaryColor : Colors.transparent,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Center(
                child: AnimatedDefaultTextStyle(
                  duration:
                      still ? Duration.zero : const Duration(milliseconds: 160),
                  curve: Curves.ease,
                  // Over the ambient style, so the label keeps the dialog's
                  // own typeface while only its colour animates.
                  style: DefaultTextStyle.of(context).style.merge(
                    TextStyle(
                      color:
                          widget.selected
                              ? kWhiteColor
                              : kWhiteColor.withValues(
                                alpha: _hovered && onTap != null ? 0.8 : 0.6,
                              ),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One existing-author match: avatar (or silhouette), exact name, collection
/// count. Choosing it fills the exact spelling.
class _SuggestionRow extends StatefulWidget {
  const _SuggestionRow({required this.suggestion, required this.onTap});

  final AuthorSuggestion suggestion;
  final VoidCallback? onTap;

  @override
  State<_SuggestionRow> createState() => _SuggestionRowState();
}

/// Its own hover and focus, not an InkWell: the dialog is drawn straight over
/// the app with no Material beneath it, which an InkWell cannot live without.
class _SuggestionRowState extends State<_SuggestionRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final suggestion = widget.suggestion;
    final onTap = widget.onTap;
    final count = _plural(suggestion.bookCount, 'collection');
    return Semantics(
      button: true,
      enabled: onTap != null,
      onTap: onTap,
      label: 'Use ${suggestion.name}, $count on ChessEver',
      excludeSemantics: true,
      child: FocusableActionDetector(
        key: ValueKey('book_author_suggestion_${suggestion.name}'),
        enabled: onTap != null,
        mouseCursor:
            onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ColoredBox(
            color: kWhiteColor.withValues(
              alpha: _focused ? 0.08 : (_hovered ? 0.05 : 0),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Row(
                children: [
                  _AuthorAvatar(url: suggestion.avatarUrl, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      suggestion.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(count, style: _noteStyle),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round author picture: an https image, else a neutral person silhouette.
/// Never initials, never a gradient.
class _AuthorAvatar extends StatelessWidget {
  const _AuthorAvatar({required this.url, this.size = 48, this.semanticsLabel});

  final String? url;
  final double size;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final uri = _httpsUri(url ?? '');
    final Widget avatar = ClipOval(
      child: SizedBox.square(
        dimension: size,
        child:
            uri == null
                ? const _Silhouette()
                : CachedNetworkImage(
                  imageUrl: uri.toString(),
                  fit: BoxFit.cover,
                  placeholder: (_, _) => const _Silhouette(),
                  errorWidget: (_, _, _) => const _Silhouette(),
                ),
      ),
    );
    if (semanticsLabel == null) return avatar;
    return Semantics(image: true, label: semanticsLabel, child: avatar);
  }
}

/// The neutral placeholder for a missing author picture: a quiet dark disc
/// with a person glyph, sized to whatever circle holds it.
class _Silhouette extends StatelessWidget {
  const _Silhouette();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kBlack3Color,
      child: LayoutBuilder(
        builder:
            (context, constraints) => Center(
              child: Icon(
                Icons.person_rounded,
                size: constraints.biggest.shortestSide * 0.56,
                color: kWhiteColor.withValues(alpha: 0.34),
              ),
            ),
      ),
    );
  }
}

/// The plate a collection shows in place of a missing cover: stacked boards,
/// drawn on the pixel grid the apps' own plate uses.
class _StackedBoardsPlate extends StatelessWidget {
  const _StackedBoardsPlate();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF151517),
    child: CustomPaint(painter: _StackedBoardsPainter()),
  );
}

class _StackedBoardsPainter extends CustomPainter {
  const _StackedBoardsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Three boards on a 16-unit grid, each a 4×4 of 3-unit squares, stepped
    // two units down and right. Units snap to whole pixels so the squares
    // stay crisp at any plate size.
    final unit = (size.shortestSide * 0.6 / 16).floorToDouble().clamp(
      1.0,
      12.0,
    );
    final origin = Offset(
      ((size.width - 16 * unit) / 2).roundToDouble(),
      ((size.height - 16 * unit) / 2).roundToDouble(),
    );
    final paint = Paint()..isAntiAlias = false;
    Rect cell(double x, double y, double w, double h) => Rect.fromLTWH(
      origin.dx + x * unit,
      origin.dy + y * unit,
      w * unit,
      h * unit,
    );
    paint.color = const Color(0xFF2B2B2F);
    canvas.drawRect(cell(0, 0, 12, 12), paint);
    paint.color = const Color(0xFF3A3A40);
    canvas.drawRect(cell(2, 2, 12, 12), paint);
    paint.color = const Color(0xFF55555C);
    canvas.drawRect(cell(4, 4, 12, 12), paint);
    paint.color = const Color(0xFFB9B9C0);
    for (var row = 0; row < 4; row++) {
      for (var column = 0; column < 4; column++) {
        if ((row + column).isEven) {
          canvas.drawRect(cell(4 + column * 3, 4 + row * 3, 3, 3), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_StackedBoardsPainter oldDelegate) => false;
}

/// Where the collection stands, when that is anything but a plain draft: in
/// review, sent back with staff's note, live, or taken down.
class _StageBand extends StatelessWidget {
  const _StageBand({required this.publication});

  final LibraryBookPublication publication;

  @override
  Widget build(BuildContext context) {
    final stage = publication.stage;
    final review = publication.review;
    final sentBack = stage == LibraryBookStage.changesRequested;
    final warning = sentBack || stage == LibraryBookStage.takenDown;
    final (String lead, String rest) = switch (stage) {
      LibraryBookStage.inReview => (
        review.submittedAt == null
            ? 'In review.'
            : 'In review since ${_day(review.submittedAt!)}.',
        'ChessEver checks every collection before it appears in Collections. It stays private until then. Anything you submit now replaces the version being reviewed.',
      ),
      LibraryBookStage.changesRequested => (
        review.decidedAt == null
            ? 'ChessEver asked for changes'
            : 'ChessEver asked for changes on ${_day(review.decidedAt!)}',
        review.note,
      ),
      LibraryBookStage.live => (
        'Live in Collections, ${_plural(publication.gameCount, 'game')}.',
        'Submitting a change takes it out of Collections until ChessEver approves the new version.',
      ),
      LibraryBookStage.takenDown => (
        'ChessEver took this collection down.',
        'It is no longer in Collections and cannot be changed here. Ask ChessEver to restore it.',
      ),
      LibraryBookStage.draft => ('', ''),
    };
    const strong = TextStyle(color: kWhiteColor, fontWeight: FontWeight.w600);
    final body = TextStyle(
      color: kWhiteColor.withValues(alpha: warning ? 0.82 : 0.78),
      fontSize: 13,
      height: 19 / 13,
    );
    return Semantics(
      container: true,
      child: DecoratedBox(
        key: ValueKey('book_stage_${stage.name}'),
        decoration: BoxDecoration(
          color:
              warning
                  ? kRedColor.withValues(alpha: 0.08)
                  : kWhiteColor.withValues(alpha: 0.035),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Sits on the first line's centre: 19px line, 8px dot.
              Padding(
                padding: const EdgeInsets.only(top: 5.5),
                child: _Dot(color: _stageColor(stage)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child:
                    sentBack
                        ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(lead, style: body.merge(strong)),
                            const SizedBox(height: 3),
                            // Staff's own words, kept whole and selectable.
                            // A long note scrolls in place rather than
                            // pushing the form out of the dialog.
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 114),
                              child: SingleChildScrollView(
                                child: SelectableText(rest, style: body),
                              ),
                            ),
                          ],
                        )
                        : Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: lead, style: strong),
                              TextSpan(text: ' $rest'),
                            ],
                          ),
                          style: body,
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The stage's own colour. The three differ in lightness as well as hue, so
/// they stay apart without relying on red against green.
Color _stageColor(LibraryBookStage stage) => switch (stage) {
  LibraryBookStage.live => kGreenColor2,
  LibraryBookStage.changesRequested ||
  LibraryBookStage.takenDown => const Color(0xFFFF6B61),
  _ => kPrimaryColor,
};

class _Dot extends StatelessWidget {
  const _Dot({required this.color, this.size = 8});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: SizedBox.square(dimension: size),
  );
}

/// Private draft, In review, Live in Collections: the road every collection
/// takes, with where this one is on it.
class _StageTrack extends StatelessWidget {
  const _StageTrack({required this.stage});

  final LibraryBookStage stage;

  @override
  Widget build(BuildContext context) {
    final at = switch (stage) {
      LibraryBookStage.live => 2,
      LibraryBookStage.inReview => 1,
      _ => 0,
    };
    final first = switch (stage) {
      LibraryBookStage.changesRequested => 'Changes requested',
      LibraryBookStage.takenDown => 'Taken down',
      _ => 'Private draft',
    };
    final labels = [first, 'In review', 'Live in Collections'];
    return Semantics(
      container: true,
      label: 'Stage: ${labels[at]}',
      excludeSemantics: true,
      child: Row(
        key: const ValueKey('book_stage_track'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: kWhiteColor.withValues(alpha: i <= at ? 0.5 : 0.14),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const SizedBox(width: 24, height: 2),
                ),
              ),
            _Dot(
              size: 7,
              color:
                  i == at
                      ? _stageColor(stage)
                      : kWhiteColor.withValues(alpha: i < at ? 0.7 : 0.22),
            ),
            const SizedBox(width: 7),
            // A narrow dialog shortens the labels instead of overflowing.
            Flexible(
              child: Text(
                labels[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color:
                      i == at
                          ? kWhiteColor
                          : kWhiteColor.withValues(alpha: i < at ? 0.7 : 0.55),
                  fontSize: 12,
                  height: 16 / 12,
                  fontWeight: i == at ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One thing a submission needs: done, or still to do (then it is a button
/// that takes the cursor to its field).
class _RequirementRow extends StatelessWidget {
  const _RequirementRow({
    required this.label,
    required this.done,
    required this.onTap,
  });

  final String label;
  final bool done;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 16,
            child: Center(
              child:
                  done
                      ? const Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: kGreenColor2,
                      )
                      : DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: kWhiteColor.withValues(alpha: 0.4),
                            width: 1.5,
                          ),
                        ),
                        child: const SizedBox.square(dimension: 10),
                      ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: done ? kWhiteColor.withValues(alpha: 0.7) : kWhiteColor,
                fontSize: 13,
                height: 18 / 13,
              ),
            ),
          ),
          if (!done) const Text('Add it', style: _noteStyle),
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      onTap: onTap,
      label: done ? '$label, done' : '$label, still needed',
      excludeSemantics: true,
      child:
          onTap == null
              ? row
              : MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: row,
                ),
              ),
    );
  }
}

/// The collection as it will be drawn, built from what is typed now: the list
/// row is the Collections list's own row; the page is the top of the
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
    required this.publisher,
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
  final String publisher;
  final int gameCount;
  final _Field? focused;

  static final _ghost = kWhiteColor.withValues(alpha: 0.4);

  Widget _plate(BoxFit fit) {
    final url = cover;
    const plate = _StackedBoardsPlate();
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
    return AnimatedSize(
      key: const ValueKey('book_preview'),
      duration:
          MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 220),
      curve: _easeOut,
      alignment: Alignment.topCenter,
      child: page ? _pageView() : _listView(),
    );
  }

  /// The Collections list row. A collection's row credits its author; the
  /// subtitle takes that place only when no author is set, so say so when
  /// both are.
  Widget _listView() {
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
        DecoratedBox(
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The list shows a cover in the event picture's 5:4 frame.
                _Spot(
                  lit: coverLit,
                  radius: 6,
                  inset: false,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 108,
                      height: 86,
                      child: _plate(BoxFit.cover),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4, right: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Spot(
                          lit: focused == _Field.title,
                          child: Text(
                            shownTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: title.isEmpty ? _ghost : kWhiteColor,
                              fontSize: 16,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (meta != null || focused == _Field.author) ...[
                          const SizedBox(height: 2),
                          _Spot(
                            lit: focused == _Field.author,
                            child: Text(
                              meta ?? 'by Author',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: meta == null ? _ghost : kWhiteColor70,
                                fontSize: 12,
                                height: 16 / 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                        if (gameCount > 0) ...[
                          const SizedBox(height: 6),
                          Text(
                            _plural(gameCount, 'game'),
                            style: TextStyle(
                              color: kWhiteColor.withValues(alpha: 0.55),
                              fontSize: 12,
                              height: 16 / 12,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                // Readers star a collection from its row.
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 6, 0),
                  child: ExcludeSemantics(
                    child: Icon(
                      Icons.star_border_rounded,
                      size: 20,
                      color: kWhiteColor.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (note != null) ...[
          const SizedBox(height: 10),
          Text(note, style: _noteStyle),
        ],
      ],
    );
  }

  /// The top of the collection's About page.
  Widget _pageView() {
    const secondary = TextStyle(
      color: kWhiteColor70,
      fontSize: 14,
      height: 20 / 14,
    );
    // The publisher is not edited here, but a collection that has one shows
    // it beside the year, as its page does.
    final edition = [
      if (publisher.isNotEmpty) publisher,
      if (year.isNotEmpty) year,
    ].join(' · ');
    return Padding(
      key: const ValueKey('book_preview_page'),
      padding: const EdgeInsets.fromLTRB(4, 2, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cover != null || coverBytes != null || coverLit) ...[
                _Spot(
                  lit: coverLit,
                  radius: 4,
                  inset: false,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      width: 64,
                      height: 96,
                      child: _plate(BoxFit.contain),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
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
                          color: title.isEmpty ? _ghost : kWhiteColor,
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
                        height: 20 / 14,
                        fontWeight: FontWeight.w600,
                      ),
                      gap: 6,
                      alwaysHold: true,
                    ),
                    _line(
                      field: _Field.year,
                      value: edition,
                      ghost: edition.isEmpty ? 'Year' : edition,
                      style: secondary.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
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
              color: about.isEmpty ? _ghost : kWhiteColor,
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
                color: about.isEmpty ? _ghost : kWhiteColor,
                fontSize: 15,
                height: 22 / 15,
              ),
            ),
          ),
        ],
      ),
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
          style: value.isEmpty ? style.copyWith(color: _ghost) : style,
        ),
      ),
    );
  }
}

/// A spot in the preview, tinted while its field is being edited. Text sits
/// inside a fixed inset that is pulled back by the same amount, so lighting a
/// spot never moves the layout; an image ([inset] false) is ringed in place.
class _Spot extends StatelessWidget {
  const _Spot({
    required this.lit,
    required this.child,
    this.radius = 4,
    this.inset = true,
  });

  final bool lit;
  final Widget child;
  final double radius;
  final bool inset;

  @override
  Widget build(BuildContext context) {
    const accent = kPrimaryColor;
    return AnimatedContainer(
      duration:
          MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
      curve: _easeOut,
      padding:
          inset
              ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1)
              : EdgeInsets.zero,
      transform:
          inset ? Matrix4.translationValues(-5, 0, 0) : Matrix4.identity(),
      foregroundDecoration:
          inset
              ? null
              : BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: accent.withValues(alpha: lit ? 0.7 : 0),
                  width: 1.5,
                ),
              ),
      decoration:
          inset
              ? BoxDecoration(
                color: accent.withValues(alpha: lit ? 0.14 : 0),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: accent.withValues(alpha: lit ? 0.5 : 0),
                ),
              )
              : null,
      child: child,
    );
  }
}
