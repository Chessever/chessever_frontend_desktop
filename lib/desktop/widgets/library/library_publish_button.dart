import 'package:flutter/material.dart';

import 'package:chessever/desktop/services/library_book_publication.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/repository/library/models/library_folder.dart';

/// What the publish button says about [folder] when hovered: what a press
/// does, or why there is nothing to press.
String libraryPublishButtonTooltip(LibraryFolder? folder) {
  if (folder == null) {
    return 'Select one of your cloud folders or databases to publish it '
        'as a collection.';
  }
  if (!libraryFolderCanPublish(folder)) {
    return folder.isSubscribed
        ? '"${folder.name}" belongs to someone else. Only your own cloud '
            'folders and databases can be published.'
        : '"${folder.name}" cannot be published. Select one of your own '
            'cloud folders or databases.';
  }
  return 'Publish "${folder.name}" as a collection, or edit what is '
      'published.';
}

/// The always-visible way into collection publishing, the desktop twin of the
/// publish icon in the phone app's folder bar.
///
/// It stays on screen when [folder] cannot be published (nothing selected, a
/// local database, a subscribed or system folder) and says why on hover, so
/// the feature is findable before the right thing is selected.
class LibraryPublishButton extends StatelessWidget {
  const LibraryPublishButton({
    super.key,
    required this.folder,
    required this.onPublish,
    this.height = 28,
    this.compact = false,
  });

  /// The cloud folder or database a press would publish. Null when the
  /// selection is not a cloud item.
  final LibraryFolder? folder;

  final ValueChanged<LibraryFolder> onPublish;

  final double height;

  /// Icon only, for a toolbar too narrow for its labels. The hover text
  /// still names the action.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final target = folder;
    final canPublish = target != null && libraryFolderCanPublish(target);
    final onPress = canPublish ? () => onPublish(target) : null;
    if (compact) {
      return DesktopDialogIconButton(
        icon: Icons.publish_rounded,
        tooltip: libraryPublishButtonTooltip(target),
        onPress: onPress,
      );
    }
    return DesktopToolbarPillButton(
      label: 'Publish',
      icon: Icons.publish_rounded,
      height: height,
      tone:
          canPublish
              ? DesktopToolbarPillTone.primary
              : DesktopToolbarPillTone.neutral,
      tooltip: libraryPublishButtonTooltip(target),
      onPress: onPress,
    );
  }
}
