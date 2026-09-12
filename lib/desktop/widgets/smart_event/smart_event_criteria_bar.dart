import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/screens/group_event/smart_event/smart_aggregate_event_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:chessever/widgets/game_filter/rating_tier_filter.dart';
import 'package:chessever/widgets/search/opening_search_suggestion.dart';

const Set<String> _stateTokens = {'live', 'completed'};
const List<({String token, String label})> _timeControlOptions = [
  (token: 'standard', label: 'Classical'),
  (token: 'rapid', label: 'Rapid'),
  (token: 'blitz', label: 'Blitz'),
];

/// The smart event's generating criteria, edited as one sentence.
///
/// "Games rated [GM 2500+] that are [live or finished], [any time control],
/// [any opening]". Each bracket is a clause that opens its own menu, so the
/// whole configuration reads as what it means instead of as a form. Every
/// change re-keys the request immediately through [onChanged].
class SmartEventCriteriaBar extends StatelessWidget {
  const SmartEventCriteriaBar({
    super.key,
    required this.request,
    required this.onChanged,
    this.onResetToSaved,
  });

  final SmartEventRequest request;
  final ValueChanged<SmartEventRequest> onChanged;

  /// Non-null while a saved smart event carries unsaved criteria edits.
  final VoidCallback? onResetToSaved;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 8,
      children: [
        const _Connector('Games rated'),
        _TierClause(request: request, onChanged: onChanged),
        const _Connector('that are'),
        _StateClause(request: request, onChanged: onChanged),
        const _Connector('in'),
        _TimeControlClause(request: request, onChanged: onChanged),
        const _Connector('with'),
        _OpeningClause(request: request, onChanged: onChanged),
        if (onResetToSaved != null)
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: _ResetLink(onTap: onResetToSaved!),
          ),
      ],
    );
  }
}

class _Connector extends StatelessWidget {
  const _Connector(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: kWhiteColor.withValues(alpha: 0.55),
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

String? _selectedTierLabel(SmartEventRequest request) {
  if (!request.hasEloRange) return null;
  final normalized = RatingTierFilter.normalizeMinRating(request.minElo);
  for (final tier in RatingTierFilter.tiers) {
    if (tier.minRating == normalized) return tier.label;
  }
  return null;
}

class _TierClause extends StatelessWidget {
  const _TierClause({required this.request, required this.onChanged});

  final SmartEventRequest request;
  final ValueChanged<SmartEventRequest> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = _selectedTierLabel(request);
    final tiers = RatingTierFilter.tiers.reversed.toList(growable: false);
    final label =
        selected == null
            ? 'any level'
            : '$selected ${RatingTierFilter.tiers.firstWhere((tier) => tier.label == selected).minRating}+';
    return _Clause(
      label: label,
      tabularFigures: true,
      menuBuilder:
          (close) => _OptionList(
            children: [
              _Option(
                label: 'Any level',
                selected: selected == null,
                onTap: () {
                  close();
                  onChanged(request.withTierSelection('All'));
                },
              ),
              for (final tier in tiers)
                _Option(
                  label: tier.label,
                  detail: '${tier.minRating}+ average',
                  selected: selected == tier.label,
                  onTap: () {
                    close();
                    onChanged(request.withTierSelection(tier.label));
                  },
                ),
            ],
          ),
    );
  }
}

class _StateClause extends StatelessWidget {
  const _StateClause({required this.request, required this.onChanged});

  final SmartEventRequest request;
  final ValueChanged<SmartEventRequest> onChanged;

  void _select(String? token) {
    final next = {...request.formatsAndStates}..removeAll(_stateTokens);
    if (token != null) next.add(token);
    onChanged(request.withCriteria(formatsAndStates: next));
  }

  @override
  Widget build(BuildContext context) {
    final hasLive = request.formatsAndStates.contains('live');
    final hasCompleted = request.formatsAndStates.contains('completed');
    final liveOnly = hasLive && !hasCompleted;
    final completedOnly = hasCompleted && !hasLive;
    final label =
        liveOnly
            ? 'live now'
            : completedOnly
            ? 'finished'
            : 'live or finished';
    return _Clause(
      label: label,
      menuBuilder:
          (close) => _OptionList(
            children: [
              _Option(
                label: 'Live or finished',
                selected: !liveOnly && !completedOnly,
                onTap: () {
                  close();
                  _select(null);
                },
              ),
              _Option(
                label: 'Live now',
                selected: liveOnly,
                onTap: () {
                  close();
                  _select('live');
                },
              ),
              _Option(
                label: 'Finished',
                selected: completedOnly,
                onTap: () {
                  close();
                  _select('completed');
                },
              ),
            ],
          ),
    );
  }
}

class _TimeControlClause extends StatelessWidget {
  const _TimeControlClause({required this.request, required this.onChanged});

  final SmartEventRequest request;
  final ValueChanged<SmartEventRequest> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = {
      for (final option in _timeControlOptions)
        if (request.formatsAndStates.contains(option.token)) option.token,
    };
    final everyOrNone =
        selected.isEmpty || selected.length == _timeControlOptions.length;
    final label =
        everyOrNone
            ? 'any time control'
            : [
              for (final option in _timeControlOptions)
                if (selected.contains(option.token)) option.label.toLowerCase(),
            ].join(' or ');

    void toggle(String token) {
      final next = {...request.formatsAndStates};
      if (!next.remove(token)) next.add(token);
      onChanged(request.withCriteria(formatsAndStates: next));
    }

    return _Clause(
      label: label,
      menuBuilder:
          (close) => _OptionList(
            children: [
              _Option(
                label: 'Any time control',
                selected: everyOrNone,
                onTap: () {
                  close();
                  onChanged(
                    request.withCriteria(
                      formatsAndStates: {...request.formatsAndStates}
                        ..removeWhere(
                          (token) => _timeControlOptions.any(
                            (option) => option.token == token,
                          ),
                        ),
                    ),
                  );
                },
              ),
              for (final option in _timeControlOptions)
                _Option(
                  label: option.label,
                  selected: !everyOrNone && selected.contains(option.token),
                  multiSelect: true,
                  onTap: () => toggle(option.token),
                ),
            ],
          ),
    );
  }
}

class _OpeningClause extends StatelessWidget {
  const _OpeningClause({required this.request, required this.onChanged});

  final SmartEventRequest request;
  final ValueChanged<SmartEventRequest> onChanged;

  @override
  Widget build(BuildContext context) {
    final explanation = request.openingExplanation;
    final label =
        explanation == null
            ? 'any opening'
            : '${explanation.codeLabel} ${explanation.title}';
    return _Clause(
      label: label,
      menuBuilder:
          (close) => _OpeningMenu(
            hasOpening: !request.eco.isAll,
            onClear: () {
              close();
              onChanged(request.withCriteria(eco: GameEcoFilter.all));
            },
            onPick: (suggestion) {
              close();
              onChanged(
                request.withCriteria(
                  eco: suggestion.filter,
                  openingContext: SmartEventOpeningContext.fromSelection(
                    suggestion.selection,
                  ),
                ),
              );
            },
          ),
    );
  }
}

class _OpeningMenu extends StatefulWidget {
  const _OpeningMenu({
    required this.hasOpening,
    required this.onClear,
    required this.onPick,
  });

  final bool hasOpening;
  final VoidCallback onClear;
  final ValueChanged<OpeningSearchSuggestion> onPick;

  @override
  State<_OpeningMenu> createState() => _OpeningMenuState();
}

class _OpeningMenuState extends State<_OpeningMenu> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = searchOpeningSuggestions(_query, limit: 8);
    final tooShort =
        _query.trim().replaceAll(RegExp(r'\s+'), '').length <
            minimumOpeningSearchCharacters &&
        results.isEmpty;
    return SizedBox(
      width: 340,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopSearchField(
              controller: _controller,
              autofocus: true,
              hintText: 'Opening name, ECO code or moves',
              onChanged: (value) => setState(() => _query = value),
              onClear: () {
                _controller.clear();
                setState(() => _query = '');
              },
            ),
            const SizedBox(height: 6),
            if (widget.hasOpening)
              _Option(label: 'Any opening', onTap: widget.onClear),
            if (tooShort)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Text(
                  'Type at least $minimumOpeningSearchCharacters characters.',
                  style: TextStyle(
                    color: kWhiteColor.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
              )
            else if (results.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Text(
                  'No opening matches "${_query.trim()}".',
                  style: TextStyle(
                    color: kWhiteColor.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final suggestion in results)
                      _Option(
                        key: ValueKey<String>(suggestion.id),
                        label: '${suggestion.codeLabel}  ${suggestion.title}',
                        detail: suggestion.subtitle,
                        tabularFigures: true,
                        onTap: () => widget.onPick(suggestion),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One bracketed clause: a sidebar-vocabulary pill that opens a menu.
class _Clause extends StatefulWidget {
  const _Clause({
    required this.label,
    required this.menuBuilder,
    this.tabularFigures = false,
  });

  final String label;
  final Widget Function(VoidCallback close) menuBuilder;
  final bool tabularFigures;

  @override
  State<_Clause> createState() => _ClauseState();
}

class _ClauseState extends State<_Clause> with SingleTickerProviderStateMixin {
  late final FPopoverController _controller = FPopoverController(vsync: this);
  bool _hovered = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close() {
    if (_controller.status != AnimationStatus.dismissed) {
      unawaited(_controller.hide());
    }
  }

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _controller,
        popoverBuilder:
            (context, _) => DecoratedBox(
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDividerColor),
              ),
              child: widget.menuBuilder(_close),
            ),
        child: ClickCursor(
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _controller.toggle,
              child: Container(
                constraints: const BoxConstraints(minHeight: 32),
                padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                decoration: BoxDecoration(
                  color: _hovered ? kBlack3Color : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        _hovered
                            ? kWhiteColor.withValues(alpha: 0.18)
                            : kDividerColor,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _hovered ? kWhiteColor : kWhiteColor70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          fontFeatures:
                              widget.tabularFigures
                                  ? const [FontFeature.tabularFigures()]
                                  : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: _hovered ? kWhiteColor : kWhiteColor70,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionList extends StatelessWidget {
  const _OptionList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return IntrinsicWidth(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 220),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _Option extends StatefulWidget {
  const _Option({
    super.key,
    required this.label,
    required this.onTap,
    this.detail,
    this.selected = false,
    this.multiSelect = false,
    this.tabularFigures = false,
  });

  final String label;
  final String? detail;
  final bool selected;
  final bool multiSelect;
  final bool tabularFigures;
  final VoidCallback onTap;

  @override
  State<_Option> createState() => _OptionState();
}

class _OptionState extends State<_Option> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final trailingIcon =
        widget.multiSelect
            ? (widget.selected
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded)
            : (widget.selected ? Icons.check_rounded : null);
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _hovered ? kBlack3Color : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              widget.selected || _hovered
                                  ? kWhiteColor
                                  : kWhiteColor70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          fontFeatures:
                              widget.tabularFigures
                                  ? const [FontFeature.tabularFigures()]
                                  : null,
                        ),
                      ),
                      if (detail != null && detail.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: kWhiteColor.withValues(alpha: 0.5),
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailingIcon != null) ...[
                  const SizedBox(width: 12),
                  Icon(
                    trailingIcon,
                    size: 16,
                    color: widget.selected ? kPrimaryColor : kWhiteColor70,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResetLink extends StatefulWidget {
  const _ResetLink({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_ResetLink> createState() => _ResetLinkState();
}

class _ResetLinkState extends State<_ResetLink> {
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
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Reset to saved',
              style: TextStyle(
                color: _hovered ? kWhiteColor : kWhiteColor70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
