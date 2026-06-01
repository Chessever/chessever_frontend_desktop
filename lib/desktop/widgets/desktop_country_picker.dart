import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/federation_flag.dart';

Future<Country?> showDesktopCountryPicker(
  BuildContext context, {
  Country? initialCountry,
}) {
  return showGeneralDialog<Country>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Choose country',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder:
        (ctx, _, __) => FTheme(
          data: FThemes.zinc.dark,
          child: Center(
            child: _DesktopCountryPickerDialog(initialCountry: initialCountry),
          ),
        ),
    transitionBuilder: (ctx, anim, _, child) {
      final eased = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: eased,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(eased),
          child: child,
        ),
      );
    },
  );
}

class _DesktopCountryPickerDialog extends StatefulWidget {
  const _DesktopCountryPickerDialog({required this.initialCountry});

  final Country? initialCountry;

  @override
  State<_DesktopCountryPickerDialog> createState() =>
      _DesktopCountryPickerDialogState();
}

class _DesktopCountryPickerDialogState
    extends State<_DesktopCountryPickerDialog> {
  late final TextEditingController _searchController;
  late final List<Country> _allCountries;
  late final ScrollController _scrollController;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _scrollController = ScrollController();
    _allCountries =
        CountryService().getAll()..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final selectedCode = widget.initialCountry?.countryCode.toUpperCase();
    final countries =
        query.isEmpty
            ? _allCountries
            : _allCountries
                .where((country) {
                  final name = country.name.toLowerCase();
                  final code = country.countryCode.toLowerCase();
                  return name.contains(query) || code.contains(query);
                })
                .toList(growable: false);

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
        child: Container(
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kDividerColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.48),
                blurRadius: 32,
                spreadRadius: 4,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(onClose: () => Navigator.of(context).pop()),
              const FDivider(),
              _SearchField(
                controller: _searchController,
                onChanged: (v) => setState(() => _query = v),
              ),
              Expanded(
                child:
                    countries.isEmpty
                        ? _EmptyState(query: _query)
                        : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                          itemCount: countries.length,
                          itemBuilder: (context, index) {
                            final country = countries[index];
                            final code = country.countryCode.toUpperCase();
                            final isSelected = code == selectedCode;
                            return _CountryRow(
                              country: country,
                              selected: isSelected,
                              onTap: () => Navigator.of(context).pop(country),
                            );
                          },
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 10, 14),
      child: Row(
        children: [
          const Icon(Icons.public_rounded, color: kPrimaryColor, size: 18),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Choose country',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          DesktopDialogIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Close',
            onPress: onClose,
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      child: FTextField(
        controller: controller,
        hint: 'Search country or code',
        onChange: onChanged,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.search_off_rounded,
            color: kLightGreyColor,
            size: 28,
          ),
          const SizedBox(height: 10),
          Text(
            'No countries for "$query"',
            style: const TextStyle(color: kLightGreyColor, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _CountryRow extends StatefulWidget {
  const _CountryRow({
    required this.country,
    required this.selected,
    required this.onTap,
  });

  final Country country;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_CountryRow> createState() => _CountryRowState();
}

class _CountryRowState extends State<_CountryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final code = widget.country.countryCode.toUpperCase();

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color:
                  widget.selected
                      ? kPrimaryColor.withValues(alpha: 0.14)
                      : (_hovered ? kBlack3Color : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color:
                    widget.selected
                        ? kPrimaryColor.withValues(alpha: 0.45)
                        : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                FederationFlag(
                  federation: code,
                  width: 28,
                  height: 18,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.country.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  code,
                  style: const TextStyle(
                    color: kLightGreyColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (widget.selected) ...[
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: kPrimaryColor,
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
