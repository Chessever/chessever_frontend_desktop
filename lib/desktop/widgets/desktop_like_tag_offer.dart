import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/repository/liked_games/liked_games_provider.dart';
import 'package:chessever/screens/chessboard/models/like_tag.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';

/// Optional post-like affordance. The toast never opens its picker by itself;
/// the draft is written only by Save through the existing liked-game notifier.
void showDesktopLikeTagOffer(BuildContext context, GamesTourModel game) {
  final container = ProviderScope.containerOf(context, listen: false);
  final ownerId = container.read(currentUserProvider)?.id;
  if (ownerId == null) return;
  showDesktopToast(
    context,
    'Added to My Likes',
    duration: const Duration(milliseconds: 5200),
    actionLabel: 'Tag this game',
    onAction: () {
      if (!context.mounted ||
          container.read(currentUserProvider)?.id != ownerId ||
          !container.read(isGameLikedProvider(game.likeId))) {
        return;
      }
      // The toaster is above the Navigator, so host the portal in the root
      // overlay rather than inside a toast without an Overlay ancestor.
      final overlay = Overlay.of(context, rootOverlay: true);
      var removed = false;
      late final OverlayEntry entry;
      entry = OverlayEntry(
        builder:
            (_) => UncontrolledProviderScope(
              container: container,
              child: _LikeTagOffer(
                likeId: game.likeId,
                ownerId: ownerId,
                gameTitle:
                    '${game.whitePlayer.name} – ${game.blackPlayer.name}',
                onDismiss: () {
                  if (removed) return;
                  removed = true;
                  entry.remove();
                  entry.dispose();
                },
              ),
            ),
      );
      overlay.insert(entry);
    },
  );
}

class _LikeTagOffer extends ConsumerStatefulWidget {
  const _LikeTagOffer({
    required this.likeId,
    required this.ownerId,
    required this.gameTitle,
    required this.onDismiss,
  });

  final String likeId;
  final String ownerId;
  final String gameTitle;
  final VoidCallback onDismiss;

  @override
  ConsumerState<_LikeTagOffer> createState() => _LikeTagOfferState();
}

class _LikeTagOfferState extends ConsumerState<_LikeTagOffer>
    with SingleTickerProviderStateMixin {
  late final FPopoverController _popover = FPopoverController(vsync: this)
    ..addListener(_onPopoverChanged);
  late List<String> _draft;
  bool _saving = false;
  bool _closeScheduled = false;
  String? _error;

  bool get _ownsLike =>
      ref.read(currentUserProvider)?.id == widget.ownerId &&
      ref.read(isGameLikedProvider(widget.likeId));

  void _closeAfterFrame() {
    if (_closeScheduled) return;
    _closeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDismiss();
    });
  }

  @override
  void initState() {
    super.initState();
    _draft = List.of(ref.read(likedGameTagsProvider(widget.likeId)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_popover.show());
    });
  }

  void _onPopoverChanged() {
    if (_popover.status == AnimationStatus.dismissed) widget.onDismiss();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_ownsLike) {
      _closeAfterFrame();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    var ok = false;
    try {
      ok = await ref
          .read(likedGamesProvider.notifier)
          .setTagsForLikeId(widget.likeId, List.of(_draft));
    } catch (_) {
      // The notifier normally returns false on a failed write; a provider
      // lifecycle failure must leave the same retryable draft, not hang Save.
    }
    if (!mounted) return;
    if (!_ownsLike) {
      _closeAfterFrame();
      return;
    }
    setState(() {
      _saving = false;
      if (!ok) _error = "Couldn't save tags. Try again.";
    });
    if (ok) {
      showDesktopToast(context, 'Tags saved');
      await _popover.hide();
    }
  }

  @override
  void dispose() {
    _popover.dispose();
    super.dispose();
  }

  Widget _picker(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    return SizedBox(
      key: const ValueKey('like-tag-picker'),
      width: (viewport.width - 48).clamp(0, 560),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: (viewport.height - 120).clamp(140, 460),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Tag this game',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.gameTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kLightGreyColor, fontSize: 11),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 460 ? 2 : 1;
                      final tagWidth =
                          (constraints.maxWidth - (columns - 1) * 20) / columns;
                      return Wrap(
                        spacing: 20,
                        runSpacing: 4,
                        children: [
                          for (final tag in kLikeTags)
                            SizedBox(
                              width: tagWidth,
                              child: FCheckbox(
                                style:
                                    (style) => style.copyWith(
                                      size: 20,
                                      childPadding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                      ),
                                      labelPadding: const EdgeInsets.only(
                                        left: 10,
                                        top: 8,
                                        bottom: 8,
                                      ),
                                    ),
                                value: _draft.contains(tag.label),
                                autofocus: tag == kLikeTags.first,
                                enabled: !_saving,
                                label: Text(
                                  tag.label,
                                  style: const TextStyle(
                                    color: kWhiteColor,
                                    fontSize: 14,
                                  ),
                                ),
                                onChange:
                                    (selected) => setState(() {
                                      if (selected) {
                                        _draft = [..._draft, tag.label];
                                      } else {
                                        _draft =
                                            _draft
                                                .where(
                                                  (label) => label != tag.label,
                                                )
                                                .toList();
                                      }
                                    }),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: kRedColor, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DesktopDialogButton(
                    label: 'Cancel',
                    tone: DesktopDialogButtonTone.ghost,
                    onPress: _saving ? null : () => _popover.hide(),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogButton(
                    label: _saving ? 'Saving…' : 'Save',
                    tone: DesktopDialogButtonTone.primary,
                    onPress: _saving ? null : _save,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentUserProvider.select((user) => user?.id), (_, next) {
      if (next != widget.ownerId) _closeAfterFrame();
    });
    ref.listen(isGameLikedProvider(widget.likeId), (_, liked) {
      if (!liked) _closeAfterFrame();
    });
    return FTheme(
      data: FThemes.zinc.dark,
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: FPopover(
            controller: _popover,
            popoverAnchor: Alignment.bottomRight,
            childAnchor: Alignment.topRight,
            autofocus: true,
            popoverBuilder:
                (context, _) => CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape):
                        () => _popover.hide(),
                  },
                  child: _picker(context),
                ),
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
