import 'package:flutter/physics.dart';
import 'package:motor/motor.dart';

/// Canonical motion profiles for the desktop shell.
///
/// The goal of these tokens is **subtle physicality** — the user shouldn't
/// notice they're "watching an animation," only that the app feels alive.
/// Most of these are short, low-amplitude springs that nudge the eye
/// without drawing it.
///
/// Why a central catalogue rather than `CupertinoMotion(...)` inline:
///
///  1. Tuning is one-stop. If hover feels too snappy, change [hover] here
///     and the whole desktop adjusts.
///  2. Code-level vocabulary. `DesktopMotion.tap` reads the way the
///     designer talks about it; `CupertinoMotion.snappy(duration: 200ms)`
///     reads like a tuning knob.
///  3. Flutter's built-in [SpringDescription] and motor's [Motion] aren't
///     interchangeable at every API. A few things (e.g. `ScrollPhysics`,
///     `AnimationController.animateWith(SpringSimulation(...))`) want a
///     [SpringDescription] directly. Each token here exposes both.
class DesktopMotion {
  DesktopMotion._();

  /// Press / release feedback on buttons, chips, list items.
  ///
  /// Very short and slightly damped — the user's finger comes back up
  /// before the spring is even half-done if it overshoots, so we keep
  /// it subtle. Overshooting on a tap reads as "wobbly," not premium.
  static const Motion tap = CupertinoMotion.snappy(
    duration: Duration(milliseconds: 220),
  );

  /// Hover-in / hover-out elevation, scale, and tint changes.
  ///
  /// Slightly slower than [tap] because hover is exploratory and the
  /// animation gives the eye a moment to register the affordance.
  static const Motion hover = CupertinoMotion.smooth(
    duration: Duration(milliseconds: 240),
  );

  /// Selection state changes on tabs, sidebar items, score-card rows.
  ///
  /// Calls for a touch of bounce — the affordance is "this is now
  /// selected," and a hint of overshoot reinforces commitment.
  static const Motion select = CupertinoMotion.snappy(
    duration: Duration(milliseconds: 320),
  );

  /// Layout transitions: sidebar collapse/expand, sheet slide, pane
  /// swap, accordion sections opening.
  ///
  /// Smooth and unobtrusive. Long enough that the eye can track the
  /// motion, short enough that nothing feels sluggish.
  static const Motion layout = CupertinoMotion.smooth(
    duration: Duration(milliseconds: 360),
  );

  /// Drag-following motion. Used when the user is actively dragging
  /// something (a piece, a splitter, a reorderable row) — the moving
  /// element should track the cursor with very little inertia, then
  /// settle gently when released.
  static const Motion drag = CupertinoMotion.interactive(
    duration: Duration(milliseconds: 180),
  );

  /// Playful entry effects: badge pop, NAG glyph land, end-of-game
  /// king tilt, score chip mount.
  ///
  /// The one place we let bounce show through; reserved for moments
  /// of celebration / arrival, never for routine state changes.
  static const Motion arrival = CupertinoMotion.bouncy(
    duration: Duration(milliseconds: 420),
  );

  /// Continuous-value tracks: eval bar fill, depth badge counter,
  /// progress meters. Slightly slower so the reading is stable instead
  /// of jittery during rapid updates.
  static const Motion track = CupertinoMotion.smooth(
    duration: Duration(milliseconds: 440),
  );
}

/// [SpringDescription] equivalents of the same tokens, for APIs that
/// want a raw spring (custom [ScrollPhysics], [AnimationController]
/// `animateWith(SpringSimulation(...))`, route transitions).
///
/// Each one is the static description of the matching [DesktopMotion]
/// entry — so a `Motion.smooth(duration: 240ms)` and the description
/// stay in lockstep.
class DesktopSprings {
  DesktopSprings._();

  static SpringDescription get tap =>
      (DesktopMotion.tap as CupertinoMotion).description;
  static SpringDescription get hover =>
      (DesktopMotion.hover as CupertinoMotion).description;
  static SpringDescription get select =>
      (DesktopMotion.select as CupertinoMotion).description;
  static SpringDescription get layout =>
      (DesktopMotion.layout as CupertinoMotion).description;
  static SpringDescription get drag =>
      (DesktopMotion.drag as CupertinoMotion).description;
  static SpringDescription get arrival =>
      (DesktopMotion.arrival as CupertinoMotion).description;
  static SpringDescription get track =>
      (DesktopMotion.track as CupertinoMotion).description;

  /// Edge bounce-back for free-scrolling lists. Slightly stiffer than
  /// Flutter's default so a rubber-band overshoot feels intentional
  /// rather than rubbery.
  static const SpringDescription scrollEdge = SpringDescription(
    mass: 0.6,
    stiffness: 280,
    damping: 22,
  );

  /// Snap-to-page / snap-to-item physics for `PageView`, `TabBarView`,
  /// `CarouselView`, `ListWheelScrollView`. A touch of bounce so the
  /// page lands with a tiny acknowledgement instead of a stiff stop.
  static const SpringDescription pageSnap = SpringDescription(
    mass: 0.5,
    stiffness: 200,
    damping: 18,
  );
}
