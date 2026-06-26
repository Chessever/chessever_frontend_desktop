import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Top-level grouping shown in the tournaments rail (and the legacy mobile
/// group-event screen).
enum GroupEventCategory { past, current, forYou, search }

/// Active category selection shared by the desktop tournaments pane and any
/// remaining mobile entry points.
final selectedGroupCategoryProvider = StateProvider<GroupEventCategory>(
  (ref) => GroupEventCategory.forYou,
);
