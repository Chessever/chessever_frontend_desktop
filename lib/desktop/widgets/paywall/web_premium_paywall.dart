import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/services/billing/desktop_pricing.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/png_asset.dart';

/// Browser-only presentation. Membership, pricing and checkout stay owned by
/// DesktopPaywallView; this widget never creates or launches a purchase.
class WebPremiumPaywall extends StatelessWidget {
  const WebPremiumPaywall({
    super.key,
    required this.subtitle,
    required this.children,
    this.contextDetail,
    this.capacityLine,
  });

  final String subtitle;
  final String? contextDetail;
  final String? capacityLine;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(26, 26, 18, 0),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Image.asset(
                PngAsset.newAppLogo,
                excludeFromSemantics: true,
              ),
            ),
            const SizedBox(width: 13),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ChessEver',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'PREMIUM',
                    style: TextStyle(
                      color: kPrimaryColor,
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            DesktopDialogIconButton(
              icon: Icons.close_rounded,
              tooltip: 'Close',
              onPress: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(26, 26, 26, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Open the game. Go deeper.',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 28,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                subtitle,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 16,
                  height: 1.4,
                ),
              ),
              if (contextDetail != null) ...[
                const SizedBox(height: 6),
                Text(
                  contextDetail!,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
              if (capacityLine != null) ...[
                const SizedBox(height: 8),
                Text(
                  capacityLine!,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 22),
                child: Divider(height: 1, color: kDividerColor),
              ),
              const _Benefit(
                'Full games & databases',
                detail: 'Countrymen, player profiles, TWIC and more',
              ),
              const _Benefit(
                'Unlimited game reports & saves',
                detail: 'Unlimited databases and favorite players',
              ),
              const _Benefit(
                'Advanced Explorer & preparation',
                detail: 'Opening trees, Play and engine tournaments',
              ),
              const _Benefit('More daily Botvinnik access'),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      ),
    ],
  );
}

class _Benefit extends StatelessWidget {
  const _Benefit(this.title, {this.detail});
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(Icons.check_rounded, size: 18, color: kPrimaryColor),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 16,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 4),
                Text(
                  detail!,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class WebPremiumPlans extends StatelessWidget {
  const WebPremiumPlans({
    super.key,
    required this.pricing,
    required this.interval,
    required this.showsTrial,
    required this.onChanged,
  });

  final DesktopResolvedPricing? pricing;
  final String interval;
  final bool showsTrial;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final resolved = pricing;
    final tier = resolved?.pricing;
    String amount(double value) =>
        DesktopPricing.formatAmount(value, resolved!.currencyCode);
    final trialPrefix =
        showsTrial && DesktopPricing.trialDays > 0
            ? '${DesktopPricing.trialDays} days free, then '
            : '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WebPlanRow(
          name: 'Monthly',
          selected: interval == 'month',
          price: tier == null ? '—' : amount(tier.monthlyAmount),
          detail: DesktopPricing.monthlyPlanDetail(showsTrial: showsTrial),
          onPress: onChanged == null ? null : () => onChanged!('month'),
        ),
        const SizedBox(height: 12),
        _WebPlanRow(
          name: 'Annual',
          selected: interval == 'year',
          price: tier == null ? '—' : amount(tier.annualMonthlyEquivalent),
          detail:
              tier == null
                  ? 'Billed yearly'
                  : '$trialPrefix${amount(tier.annualAmount)} billed yearly',
          onPress: onChanged == null ? null : () => onChanged!('year'),
        ),
      ],
    );
  }
}

class _WebPlanRow extends StatelessWidget {
  const _WebPlanRow({
    required this.name,
    required this.selected,
    required this.price,
    required this.detail,
    required this.onPress,
  });
  final String name;
  final bool selected;
  final String price;
  final String detail;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) => FTheme(
    data: FThemes.zinc.dark,
    child: Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: FButton(
        onPress: onPress,
        style: FButtonStyle.ghost(
          (style) => style.copyWith(
            decoration: FWidgetStateMap({
              WidgetState.hovered | WidgetState.focused: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kPrimaryColor, width: 2),
              ),
              WidgetState.any: BoxDecoration(
                color:
                    selected
                        ? kPrimaryColor.withValues(alpha: 0.10)
                        : kBlack2Color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? kPrimaryColor : kDividerColor,
                  width: selected ? 2 : 1,
                ),
              ),
            }),
            contentStyle:
                (content) =>
                    content.copyWith(padding: const EdgeInsets.all(14)),
          ),
        ),
        child: Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 42),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                  color: selected ? kPrimaryColor : kWhiteColor70,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        detail,
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: price,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const TextSpan(
                          text: ' /mo',
                          style: TextStyle(color: kWhiteColor70, fontSize: 13),
                        ),
                      ],
                    ),
                    textAlign: TextAlign.right,
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

class WebPremiumCheckoutButton extends StatelessWidget {
  const WebPremiumCheckoutButton({
    super.key,
    required this.label,
    required this.onPress,
  });
  final String label;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) => FTheme(
    data: FThemes.zinc.dark,
    child: FButton(
      onPress: onPress,
      style: FButtonStyle.primary(
        (style) => style.copyWith(
          decoration: FWidgetStateMap({
            WidgetState.disabled: BoxDecoration(
              color: kBlack3Color,
              borderRadius: BorderRadius.circular(10),
            ),
            WidgetState.any: BoxDecoration(
              color: kPrimaryColor,
              borderRadius: BorderRadius.circular(10),
            ),
          }),
          contentStyle:
              (content) => content.copyWith(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 16,
                ),
              ),
        ),
      ),
      child: Flexible(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: kBackgroundColor,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
  );
}
