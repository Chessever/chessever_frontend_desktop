import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/theme/app_theme.dart';

/// The pieces a Library catalog list is made of: the column header strip,
/// the section label, the row frame and the muted cell. Library Home lists
/// databases with them; Collections lists published collections with the
/// same ones, so the two lists read as one family.

/// Text style of a catalog column header ("NAME", "GAMES").
const TextStyle kLibraryCatalogHeaderStyle = TextStyle(
  color: kLightGreyColor,
  fontSize: 10.5,
  fontWeight: FontWeight.w700,
  letterSpacing: 0.25,
);

/// Height of one catalog row.
const double kLibraryCatalogRowHeight = 42;

/// The strip that carries a catalog's column headers.
class LibraryCatalogHeaderStrip extends StatelessWidget {
  const LibraryCatalogHeaderStrip({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 29,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.52),
        border: const Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: child,
    );
  }
}

/// A quiet band naming the run of rows under it.
class LibraryCatalogSectionLabel extends StatelessWidget {
  const LibraryCatalogSectionLabel({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 25,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: kBlackColor.withValues(alpha: 0.34),
      child: Text(
        label,
        style: TextStyle(
          color: kWhiteColor.withValues(alpha: 0.52),
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// A secondary value in a catalog row (a count, a source, a date).
class LibraryCatalogMutedCell extends StatelessWidget {
  const LibraryCatalogMutedCell(this.value, {super.key, this.textAlign});

  final String value;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
      style: const TextStyle(
        color: kLightGreyColor,
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// The title of a catalog row.
TextStyle libraryCatalogTitleStyle({required bool selected}) => TextStyle(
  color: selected ? kPrimaryColor : kWhiteColor,
  fontSize: 12.5,
  fontWeight: FontWeight.w700,
);

/// One row of a catalog list: a click selects it, a double click or Enter
/// opens it, a right click selects it and asks for its menu. The selected row
/// carries the accent bar on its left edge and a tint; a hovered one lifts a
/// step. [builder] lays out the row's cells and is told whether the pointer
/// is over the row.
class LibraryCatalogRowFrame extends StatefulWidget {
  const LibraryCatalogRowFrame({
    super.key,
    required this.selected,
    required this.semanticsLabel,
    required this.onSelect,
    required this.onOpen,
    required this.builder,
    this.onContextMenu,
    this.height = kLibraryCatalogRowHeight,
    this.focusDebugLabel = 'library-catalog-row',
  });

  final bool selected;
  final String semanticsLabel;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final ValueChanged<Offset>? onContextMenu;
  final Widget Function(BuildContext context, bool hovered) builder;
  final double height;
  final String focusDebugLabel;

  @override
  State<LibraryCatalogRowFrame> createState() => _LibraryCatalogRowFrameState();
}

class _LibraryCatalogRowFrameState extends State<LibraryCatalogRowFrame>
    with DeferredPointerStateMixin<LibraryCatalogRowFrame> {
  late final FocusNode _focusNode = FocusNode(
    debugLabel: widget.focusDebugLabel,
  );
  bool _hovered = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _select() {
    _focusNode.requestFocus();
    widget.onSelect();
  }

  void _open() {
    _focusNode.requestFocus();
    widget.onOpen();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticsLabel,
      child: Focus(
        focusNode: _focusNode,
        canRequestFocus: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            _open();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: ClickCursor(
          child: MouseRegion(
            onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
            onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _select,
              onDoubleTap: _open,
              onSecondaryTapUp:
                  widget.onContextMenu == null
                      ? null
                      : (details) {
                        _select();
                        widget.onContextMenu!(details.globalPosition);
                      },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                height: widget.height,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color:
                      widget.selected
                          ? kPrimaryColor.withValues(alpha: 0.075)
                          : (_hovered
                              ? kBlack3Color.withValues(alpha: 0.72)
                              : Colors.transparent),
                  border: Border(
                    left: BorderSide(
                      color:
                          widget.selected ? kPrimaryColor : Colors.transparent,
                      width: 2,
                    ),
                    bottom: BorderSide(
                      color: kDividerColor.withValues(alpha: 0.72),
                    ),
                  ),
                ),
                child: widget.builder(context, _hovered),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
