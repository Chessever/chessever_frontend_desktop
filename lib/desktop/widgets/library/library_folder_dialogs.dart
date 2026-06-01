import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/theme/app_theme.dart';

/// Result returned by [showLibraryCreateFolderDialog].
class LibraryFolderDraft {
  const LibraryFolderDraft({required this.name, this.parentId});
  final String name;
  final String? parentId;
}

/// Forui-styled dialog to create a new database (root) or sub-database
/// (child of an existing root). Mirrors the mobile `showCreateFolderDialog`
/// but adapts the chrome to desktop: floating dialog, FButton actions, no
/// haptic feedback, Esc to cancel, Enter to confirm.
///
/// [availableParents] lists writable root-level folders the user could nest
/// into. When [lockedParent] is supplied the dialog renders without the
/// type/parent selector and creates a sub-database under it.
Future<LibraryFolderDraft?> showLibraryCreateFolderDialog(
  BuildContext context, {
  required List<LibraryFolder> availableParents,
  LibraryFolder? lockedParent,
}) {
  return showGeneralDialog<LibraryFolderDraft>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'New folder',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder:
        (ctx, _, _) => _LibraryFolderDialog(
          availableParents: availableParents,
          lockedParent: lockedParent,
          title:
              lockedParent != null
                  ? 'New sub-database in "${lockedParent.name}"'
                  : 'New database',
          confirmLabel: 'Create',
        ),
    transitionBuilder: (ctx, anim, _, child) {
      final eased = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(eased),
          child: child,
        ),
      );
    },
  );
}

/// Forui-styled rename dialog. Returns the new (trimmed) name or null when
/// the user cancels / submits an unchanged value.
Future<String?> showLibraryRenameFolderDialog(
  BuildContext context, {
  required LibraryFolder folder,
}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Rename folder',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder:
        (ctx, _, _) => _LibraryFolderDialog(
          availableParents: const [],
          lockedParent: null,
          title: 'Rename "${folder.name}"',
          confirmLabel: 'Save',
          initialName: folder.name,
          isRename: true,
        ),
    transitionBuilder: (ctx, anim, _, child) {
      final eased = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(eased),
          child: child,
        ),
      );
    },
  );
}

/// Confirmation dialog for deleting a folder. Returns `true` on confirm.
/// FK `ON DELETE CASCADE` — every game inside is hard-deleted with the
/// folder. The copy below must communicate that.
Future<bool> showLibraryDeleteFolderConfirmation(
  BuildContext context, {
  required LibraryFolder folder,
}) async {
  final confirmed = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Delete folder',
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
                  Row(
                    children: [
                      const Icon(
                        Icons.delete_forever_outlined,
                        color: Color(0xFFEB5757),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Delete "${folder.name}"?',
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'This permanently deletes the folder and every game inside '
                    'it. This cannot be undone.',
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
                        label: 'Cancel',
                        onPress: () => Navigator.of(ctx).pop(false),
                      ),
                      const SizedBox(width: 8),
                      DesktopDialogButton(
                        label: 'Delete',
                        tone: DesktopDialogButtonTone.danger,
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
  return confirmed == true;
}

class _LibraryFolderDialog extends StatefulWidget {
  const _LibraryFolderDialog({
    required this.availableParents,
    required this.lockedParent,
    required this.title,
    required this.confirmLabel,
    this.initialName,
    this.isRename = false,
  });

  final List<LibraryFolder> availableParents;
  final LibraryFolder? lockedParent;
  final String title;
  final String confirmLabel;
  final String? initialName;
  final bool isRename;

  @override
  State<_LibraryFolderDialog> createState() => _LibraryFolderDialogState();
}

class _LibraryFolderDialogState extends State<_LibraryFolderDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  String? _selectedParentId;
  bool _isSubdatabase = false;
  bool _attemptedSubmit = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName ?? '');
    _focusNode = FocusNode();
    if (widget.lockedParent != null) {
      _isSubdatabase = true;
      _selectedParentId = widget.lockedParent!.id;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _confirm() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _attemptedSubmit = true);
      return;
    }
    if (widget.isRename) {
      if (name == widget.initialName?.trim()) {
        Navigator.of(context).pop();
        return;
      }
      Navigator.of(context).pop(name);
      return;
    }
    final parentId = _isSubdatabase ? _selectedParentId : null;
    Navigator.of(
      context,
    ).pop(LibraryFolderDraft(name: name, parentId: parentId));
  }

  void _cancel() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final canShowTypeSelector = !widget.isRename && widget.lockedParent == null;
    final canShowParentSelector = canShowTypeSelector && _isSubdatabase;

    return FTheme(
      data: FThemes.zinc.dark,
      child: Center(
        child: Container(
          width: 460,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kDividerColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (event.logicalKey == LogicalKeyboardKey.escape) {
                _cancel();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      widget.isRename
                          ? Icons.edit_outlined
                          : (_isSubdatabase
                              ? Icons.create_new_folder_outlined
                              : Icons.folder_outlined),
                      size: 18,
                      color: kPrimaryColor,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (canShowTypeSelector) ...[
                  _TypeSelector(
                    isSubdatabase: _isSubdatabase,
                    onChanged:
                        (sub) => setState(() {
                          _isSubdatabase = sub;
                          if (sub &&
                              _selectedParentId == null &&
                              widget.availableParents.isNotEmpty) {
                            _selectedParentId =
                                widget.availableParents.first.id;
                          }
                        }),
                  ),
                  const SizedBox(height: 12),
                ],
                if (canShowParentSelector) ...[
                  if (widget.availableParents.isEmpty)
                    const Text(
                      'No root databases yet. Create one first to nest a '
                      'sub-database under it.',
                      style: TextStyle(color: Color(0xFFEB5757), fontSize: 12),
                    )
                  else
                    _ParentSelector(
                      parents: widget.availableParents,
                      selectedId: _selectedParentId,
                      onChanged: (id) => setState(() => _selectedParentId = id),
                    ),
                  const SizedBox(height: 12),
                ],
                _NameField(
                  controller: _controller,
                  focusNode: _focusNode,
                  hasError: _attemptedSubmit && _controller.text.trim().isEmpty,
                  onSubmitted: (_) => _confirm(),
                  onChanged: (_) {
                    if (_attemptedSubmit) setState(() {});
                  },
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DesktopDialogButton(label: 'Cancel', onPress: _cancel),
                    const SizedBox(width: 8),
                    DesktopDialogButton(
                      label: widget.confirmLabel,
                      tone: DesktopDialogButtonTone.primary,
                      onPress: _confirm,
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

class _TypeSelector extends StatelessWidget {
  const _TypeSelector({required this.isSubdatabase, required this.onChanged});

  final bool isSubdatabase;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: _segment('Database', !isSubdatabase, () => onChanged(false)),
          ),
          Expanded(
            child: _segment(
              'Sub-database',
              isSubdatabase,
              () => onChanged(true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _segment(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? kBlack2Color : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: selected ? Border.all(color: kDividerColor) : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? kWhiteColor : kWhiteColor70,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ParentSelector extends StatelessWidget {
  const _ParentSelector({
    required this.parents,
    required this.selectedId,
    required this.onChanged,
  });

  final List<LibraryFolder> parents;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Parent database',
          style: TextStyle(
            color: kLightGreyColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 6),
        FTheme(
          data: FThemes.zinc.dark,
          child: FSelect<String>.rich(
            key: ValueKey(selectedId),
            initialValue: selectedId,
            format: (value) => _parentName(value),
            onChange: onChanged,
            children: [
              for (final parent in parents)
                FSelectItem<String>(
                  title: Text(parent.name, overflow: TextOverflow.ellipsis),
                  value: parent.id,
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _parentName(String id) {
    for (final parent in parents) {
      if (parent.id == id) return parent.name;
    }
    return '';
  }
}

class _NameField extends StatelessWidget {
  const _NameField({
    required this.controller,
    required this.focusNode,
    required this.hasError,
    required this.onSubmitted,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool hasError;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Name',
          style: TextStyle(
            color: kLightGreyColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: kBlack3Color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: hasError ? const Color(0xFFEB5757) : kDividerColor,
            ),
          ),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            maxLength: 60,
            style: const TextStyle(color: kWhiteColor, fontSize: 13),
            cursorColor: kPrimaryColor,
            decoration: const InputDecoration(
              hintText: 'e.g. Caro-Kann prep',
              hintStyle: TextStyle(color: kLightGreyColor, fontSize: 13),
              border: InputBorder.none,
              isCollapsed: true,
              counterText: '',
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
          const Text(
            'Name cannot be empty.',
            style: TextStyle(color: Color(0xFFEB5757), fontSize: 11),
          ),
        ],
      ],
    );
  }
}
