import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/event_card/event_image_provider.dart'
    show extractCountryFromLocation;

/// Switch between the tours that share one group-broadcast — typically
/// the Open / Women / U-section splits of a single event.
///
/// Mobile lives in `category_dropdown.dart`; the desktop variant uses
/// forui chrome (`FPopover` + `FButton`) to match the rest of the
/// desktop chrome (tab bar dropdowns, event-info, engine settings). It
/// reads the existing `tourDetailScreenProvider` (mobile-shared) and
/// drives selection through `updateSelection(tourId)`.
///
/// Hides itself when the group has 0 or 1 tour — the switcher only
/// earns a slot when there is something to switch to.
class TournamentCategorySwitcher extends ConsumerStatefulWidget {
  const TournamentCategorySwitcher({super.key});

  @override
  ConsumerState<TournamentCategorySwitcher> createState() =>
      _TournamentCategorySwitcherState();
}

class _TournamentCategorySwitcherState
    extends ConsumerState<TournamentCategorySwitcher>
    with SingleTickerProviderStateMixin {
  late final FPopoverController _controller = FPopoverController(vsync: this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(tourDetailScreenProvider);
    final tourData = detail.valueOrNull;
    if (tourData == null || tourData.tours.length <= 1) {
      return const SizedBox.shrink();
    }

    final selectedId = tourData.aboutTourModel.id;
    final selected = tourData.tours.firstWhere(
      (m) => m.tour.id == selectedId,
      orElse: () => tourData.tours.first,
    );
    final label = _categoryLabel(selected.tour.name);

    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _controller,
        popoverBuilder:
            (context, _) => _CategoryMenu(
              tours: tourData.tours,
              selectedId: selectedId,
              onPick: (tourId) {
                _controller.hide();
                ref
                    .read(tourDetailScreenProvider.notifier)
                    .updateSelection(tourId);
              },
            ),
        child: _SwitcherTrigger(
          onTap: _controller.toggle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: kPrimaryColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: kPrimaryColor.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    '${tourData.tours.length}',
                    style: const TextStyle(
                      color: kPrimaryColor,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 17,
                  color: kWhiteColor70,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitcherTrigger extends StatefulWidget {
  const _SwitcherTrigger({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_SwitcherTrigger> createState() => _SwitcherTriggerState();
}

class _SwitcherTriggerState extends State<_SwitcherTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: _hovered ? kBlack3Color : kBlack2Color,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color:
                    _hovered
                        ? kPrimaryColor.withValues(alpha: 0.45)
                        : kDividerColor,
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _CategoryMenu extends StatefulWidget {
  const _CategoryMenu({
    required this.tours,
    required this.selectedId,
    required this.onPick,
  });

  final List<TourModel> tours;
  final String selectedId;
  final ValueChanged<String> onPick;

  @override
  State<_CategoryMenu> createState() => _CategoryMenuState();
}

class _CategoryMenuState extends State<_CategoryMenu> {
  static const double _maxMenuHeight = 560;

  final ScrollController _scrollController = ScrollController();
  GlobalKey _selectedRowKey = GlobalKey();
  String? _revealedSelectedId;

  @override
  void didUpdateWidget(covariant _CategoryMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedId == widget.selectedId) return;
    _selectedRowKey = GlobalKey();
    _revealedSelectedId = null;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _revealSelectionAfterLayout() {
    if (_revealedSelectedId == widget.selectedId) return;
    _revealedSelectedId = widget.selectedId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selectedContext = _selectedRowKey.currentContext;
      if (selectedContext == null) return;
      Scrollable.ensureVisible(
        selectedContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    _revealSelectionAfterLayout();
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final maxHeight = (_maxMenuHeight).clamp(180.0, viewportHeight - 32);

    return Container(
      width: 320,
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Text(
              'CATEGORY',
              style: TextStyle(
                color: kLightGreyColor,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.9,
              ),
            ),
          ),
          Flexible(
            child: Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              child: ListView.builder(
                controller: _scrollController,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: widget.tours.length,
                itemBuilder: (context, index) {
                  final model = widget.tours[index];
                  final selected = model.tour.id == widget.selectedId;
                  return _CategoryRow(
                    key: selected ? _selectedRowKey : null,
                    model: model,
                    selected: selected,
                    onTap: () => widget.onPick(model.tour.id),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryRow extends StatefulWidget {
  const _CategoryRow({
    super.key,
    required this.model,
    required this.selected,
    required this.onTap,
  });

  final TourModel model;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_CategoryRow> createState() => _CategoryRowState();
}

class _CategoryRowState extends State<_CategoryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tour = widget.model.tour;
    final selected = widget.selected;
    // `tour.info.location` is free-form ("Wijk aan Zee, Netherlands",
    // "Saint Louis, USA"). `CountryFlag.fromCountryCode` expects an ISO-2
    // code — passing raw location text rendered as a blank white rectangle.
    // Resolve to a real 2-letter code (or null when no match) and hide the
    // flag slot entirely on failure so the row looks deliberate.
    final flagCode = extractCountryFromLocation(tour.info.location);

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color:
                  selected
                      ? kPrimaryColor.withValues(alpha: 0.14)
                      : (_hovered ? kBlack3Color : Colors.transparent),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color:
                    selected
                        ? kPrimaryColor.withValues(alpha: 0.45)
                        : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _categoryLabel(tour.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: kWhiteColor,
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (tour.info.tc != null &&
                              tour.info.tc!.trim().isNotEmpty)
                            Flexible(
                              child: Text(
                                tour.info.tc!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: kLightGreyColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (flagCode != null && flagCode.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: SizedBox(
                        width: 18,
                        height: 12,
                        child: CountryFlag.fromCountryCode(flagCode),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Strip the parent broadcast title so the chip reads "Open" / "Women" /
/// "U18", not the full `Tournament | Open`. Mobile parses with regex on
/// `|` and `:` separators (see `category_dropdown.dart`).
String _categoryLabel(String tourName) {
  final name = tourName.trim();
  if (name.isEmpty) return 'Category';
  for (final sep in const [' | ', ' : ', ' - ', ' — ']) {
    final idx = name.lastIndexOf(sep);
    if (idx > 0 && idx + sep.length < name.length) {
      return name.substring(idx + sep.length).trim();
    }
  }
  // Fallback: keep last whitespace-delimited token if it looks like a
  // category marker (Open, Women, U18, U21, A, B, …).
  final tokens = name.split(RegExp(r'\s+'));
  if (tokens.length > 1) {
    final last = tokens.last;
    final looksLikeCategory = RegExp(
      r'^(U\d+|[A-Z]|Open|Women|Men|Junior|Senior)$',
    ).hasMatch(last);
    if (looksLikeCategory) return last;
  }
  return name;
}
