import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/desktop_scroll_controller.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing.dart';
import 'package:chessever/desktop/services/billing/web_intro_offer.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/png_asset.dart';

/// Shared presentation for browser and direct-download desktop subscriptions.
/// Membership, prices and checkout remain owned by DesktopPaywallView.
/// The Mac App Store edition uses its own store-supplied plans.
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
        padding: const EdgeInsets.fromLTRB(22, 18, 14, 0),
        child: Row(
          children: [
            Image.asset(
              PngAsset.newAppLogo,
              width: 28,
              height: 28,
              // The shipped icon has a black canvas; blend it into the dialog.
              color: kBlack2Color,
              colorBlendMode: BlendMode.lighten,
              excludeFromSemantics: true,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'ChessEver Premium',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
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
        child: DesktopScrollHost(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 21,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (contextDetail != null) ...[
                  const SizedBox(height: 7),
                  Text(
                    contextDetail!,
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 13,
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
                const SizedBox(height: 22),
                ...children,
                const SizedBox(height: 24),
                const Text(
                  'Every plan includes',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                const _Benefit('Full games, databases and player profiles'),
                const _Benefit('Unlimited game reports, saves and favorites'),
                const _Benefit(
                  'Advanced Explorer, opening trees and preparation',
                ),
                const _Benefit(
                  'Play, engine tournaments and more Botvinnik access',
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class _Benefit extends StatelessWidget {
  const _Benefit(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_rounded, size: 16, color: kWhiteColor70),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

/// One plan choice and one complete price statement. An introductory amount
/// never wears a recurring '/month' suffix, and annual shows the actual charge.
class WebPremiumPlans extends StatelessWidget {
  const WebPremiumPlans({
    super.key,
    required this.pricing,
    required this.interval,
    required this.showsTrial,
    required this.onChanged,
    this.introOffer,
  });

  final DesktopResolvedPricing? pricing;
  final String interval;
  final bool showsTrial;
  final ValueChanged<String>? onChanged;
  final WebIntroOffer? introOffer;

  @override
  Widget build(BuildContext context) {
    final resolved = pricing;
    final tier = resolved?.pricing;
    final monthly = interval == 'month';
    final showsIntro =
        monthly &&
        resolved != null &&
        introOffer?.matches(
              currency: resolved.currencyCode,
              monthlyAmount: resolved.pricing.monthlyAmount,
            ) ==
            true;
    String amount(double value) =>
        DesktopPricing.formatAmount(value, resolved!.currencyCode);
    final price =
        tier == null
            ? '—'
            : showsIntro
            ? r'$0.99'
            : amount(monthly ? tier.monthlyAmount : tier.annualAmount);
    final unit = monthly ? 'per month' : 'per year';
    final detail =
        tier == null
            ? 'Loading current prices'
            : showsIntro
            ? 'From month 2: ${amount(tier.monthlyAmount)}/month.'
            : !monthly
            ? '${amount(tier.annualMonthlyEquivalent)} per month, billed yearly.'
            : DesktopPricing.monthlyPlanDetail(showsTrial: showsTrial);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _PlanChoice(
                label: 'Monthly',
                selected: monthly,
                onPress: onChanged == null ? null : () => onChanged!('month'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _PlanChoice(
                label: 'Annual',
                selected: !monthly,
                onPress: onChanged == null ? null : () => onChanged!('year'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showsIntro) ...[
                const Text(
                  'First month only',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 20,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 2,
                children: [
                  if (showsIntro)
                    Semantics(
                      label:
                          'Regular monthly price ${amount(tier!.monthlyAmount)}',
                      excludeSemantics: true,
                      child: Text(
                        amount(tier.monthlyAmount),
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 24,
                          height: 1.3,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: kWhiteColor70,
                          decorationThickness: 1.5,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  Text(
                    price,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 46,
                      height: 1.1,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (!showsIntro)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                        unit,
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                detail,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
              if (showsIntro && introOffer!.requiresSignIn) ...[
                const SizedBox(height: 6),
                const Text(
                  'For first-time subscribers. Sign in to check eligibility.',
                  style: TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
              if (showsTrial &&
                  DesktopPricing.trialDays > 0 &&
                  !showsIntro) ...[
                const SizedBox(height: 6),
                Text(
                  '${DesktopPricing.trialDays} days free before your first payment.',
                  style: const TextStyle(color: kWhiteColor70, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PlanChoice extends StatelessWidget {
  const _PlanChoice({
    required this.label,
    required this.selected,
    required this.onPress,
  });
  final String label;
  final bool selected;
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
                color: kBlack3Color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kPrimaryColor.withValues(alpha: 0.7)),
              ),
              WidgetState.any: BoxDecoration(
                color:
                    selected
                        ? kPrimaryColor.withValues(alpha: 0.10)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      selected
                          ? kPrimaryColor.withValues(alpha: 0.35)
                          : kDividerColor,
                ),
              ),
            }),
            contentStyle:
                (content) => content.copyWith(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
          ),
        ),
        child: Flexible(
          child: Text(
            label,
            style: TextStyle(
              color: selected ? kPrimaryColor : kWhiteColor70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
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
              borderRadius: BorderRadius.circular(8),
            ),
            WidgetState.hovered | WidgetState.focused: BoxDecoration(
              color: kWhiteColor.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(8),
            ),
            WidgetState.any: BoxDecoration(
              color: kWhiteColor,
              borderRadius: BorderRadius.circular(8),
            ),
          }),
          contentStyle:
              (content) => content.copyWith(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 15,
                ),
              ),
        ),
      ),
      child: Flexible(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: onPress == null ? kWhiteColor70 : kBackgroundColor,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );
}
