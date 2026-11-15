import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/coverage.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_frame.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_guidance.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';

/// The words the capture screen shows, and the small strings around them.
///
/// Pure Dart, and deliberately pulled out of the widget in
/// `ui/screens/ar_capture_screen.dart`. The `ui/` layer cannot be widget-tested
/// in this environment (`flutter test` does not run here), so every decision a
/// screen makes that is *not* about layout lives here instead, where the
/// plain-`dart` suite can check it.
///
/// A wrong instruction is a real bug — it sends the user the wrong way — and it
/// is far easier to pin as a string than as a widget tree.
///
/// `ui/` reads this for every line it shows, and `capture_flow_engine.dart` uses
/// it for the few sentences it has to write into a station record. Nothing here
/// imports Flutter, which is what lets the suite reach it.

/// The headline for the instruction panel.
///
/// [status] is the engine's own status line, used only while aligning: when the
/// guidance has something specific to say ("Turn right 12°") that is more useful
/// than the generic "Aim at the marker".
String instructionTitle(CapturePhase? phase, {String status = ''}) =>
    switch (phase) {
      null => 'Preparing…',
      CapturePhase.initialise => 'Initialising…',
      CapturePhase.survey => 'Checking the room…',
      CapturePhase.plan => 'Planning the views…',
      CapturePhase.align => status.isEmpty ? 'Aim at the marker' : status,
      CapturePhase.settle => 'Target aligned — hold still',
      CapturePhase.capture => 'Capturing… hold still',
      CapturePhase.validate => 'Checking the image…',
      CapturePhase.accept => 'Captured',
      CapturePhase.retry => 'Not marked as done — retrying',
      CapturePhase.nextTarget => 'Next view',
      CapturePhase.verify => 'Checking the coverage…',
      CapturePhase.nextViewpoint => 'Another station is recommended',
      CapturePhase.complete => 'Station complete',
    };

/// The hint under the headline.
///
/// Falls back to the one piece of advice that is true at every phase: AR needs
/// the phone to move, slowly, before it can find the room.
String instructionHint(String? message) => message == null || message.isEmpty
    ? 'Move the phone slowly so AR can find the room.'
    : message;

/// The one-line description of the target being aimed at.
///
/// The poles get words rather than numbers. "View 26" tells the user nothing
/// about where to point, and the whole point of the zenith frame is that it is
/// straight up — so saying so is the instruction, not decoration.
String targetLabel(PlanFrame target) {
  final which = target.isZenith
      ? 'Straight up'
      : target.isNadir
      ? 'Straight down'
      : 'View ${target.index + 1}';
  final lens = '${target.hfovDeg.toStringAsFixed(0)}° lens';
  final repair = target.isRepair ? ' · added to fill a gap' : '';
  return '$which · $lens$repair';
}

/// The capture counter, with the skipped count when there is one.
///
/// Skipped targets are named because they are a decision the user made, and a
/// count that silently ignores them would read as a lie the moment the panorama
/// comes back with holes.
String progressLine({
  required int captured,
  required int total,
  int skipped = 0,
}) =>
    '$captured of $total captured'
    '${skipped > 0 ? ' · $skipped skipped' : ''}';

// ── The prototype's 6-state capture guidance copy ────────────────────────
//
// These are the strings the AR capture screen shows while the 6-state machine
// (`domain/session/capture_guidance.dart`) runs. They are ported verbatim from
// the prototype's `tick()` block (the `tt`, `sub` and `b` locals), so a change
// here is a behaviour change and the plain-`dart` suite pins every one of them.

/// The instruction headline for each guidance state.
///
/// [searchDirection] is [searchDirection]'s value, substituted for `search`
/// (the prototype uses the live "Turn right"/"Look up" text there).
String guidanceTitle(
  CaptureGuidanceState state, {
  String searchDirection = '',
}) => switch (state) {
  CaptureGuidanceState.init => 'Initializing AR…',
  CaptureGuidanceState.search => searchDirection,
  CaptureGuidanceState.align => 'Target aligned — hold still',
  CaptureGuidanceState.cap => 'Capturing… Hold still',
  CaptureGuidanceState.done => 'Captured',
  CaptureGuidanceState.fail => 'Image capture failed',
};

/// The one-line detail under [guidanceTitle].
///
/// Exactly the prototype's `sub`: a fixed sentence for `init`/`fail`, the
/// out-of-view warning during `search`, and otherwise the target's ring name
/// and ordinal ("Middle ring · 1 of 8"), from the fixed plan's ring metadata.
String guidanceSub(
  CaptureGuidanceState state,
  PlanFrame target, {
  bool outOfView = false,
}) {
  if (state == CaptureGuidanceState.init) {
    return 'Move the phone slowly so AR can find the room.';
  }
  if (state == CaptureGuidanceState.fail) {
    return 'This position is not marked as done.';
  }
  if (state == CaptureGuidanceState.search && outOfView) {
    return 'The target is outside the view.';
  }
  return frameTitle(target);
}

/// The target's name the way the prototype spells it: ring plus ordinal.
///
/// Shared by the guidance subtitle and the review gallery so the two can never
/// call the same view by different names.
String frameTitle(PlanFrame target) {
  final name = target.ringName ?? 'View ${target.index + 1}';
  final k = (target.indexInRing ?? 0) + 1;
  final c = target.countInRing ?? 1;
  return '$name · $k of $c';
}

/// The small status banner, ported from the prototype's `b` local.
///
/// Motion is checked first, and the banner only appears for the three states
/// that have something transient to say.
String guidanceBanner(CaptureGuidanceState state, {bool moving = false}) {
  if (moving) return 'Phone moving too much — hold steady';
  if (state == CaptureGuidanceState.init) return 'Initializing AR tracking…';
  if (state == CaptureGuidanceState.fail) return 'Capture failed';
  return '';
}

/// The turn/look instruction during `search`, ported from the prototype's
/// `dirT`. [dyDeg] is the signed yaw error (positive = turn right) and [dpDeg]
/// the pitch error (positive = look up); the yaw error is zeroed for poles.
///
/// The prototype names one axis. When both are large the phone has to move
/// diagonally, and "Turn right" alone sends the user past the target — so a
/// genuine two-axis correction is said as one instruction, "Turn right and tilt
/// down". The single-axis strings are unchanged, which keeps every case the
/// prototype covers word-for-word.
String searchDirection(double dyDeg, double dpDeg) {
  final yaw = dyDeg.abs();
  final pitch = dpDeg.abs();
  if (yaw >= 2 && pitch >= 2 && pitch >= yaw * 0.4) {
    return 'Turn ${dyDeg > 0 ? 'right' : 'left'} and tilt '
        '${dpDeg > 0 ? 'up' : 'down'}';
  }
  if (yaw >= pitch) return dyDeg > 0 ? 'Turn right' : 'Turn left';
  return dpDeg > 0
      ? (dpDeg > 25 ? 'Look up' : 'Look slightly up')
      : (dpDeg < -25 ? 'Look down' : 'Look slightly down');
}

// ── Naming the part of the room that is missing ──────────────────────────

/// Where an uncovered patch sits, in the words the review screen needs.
///
/// VERIFY measures coverage on the sphere, which knows each hole's yaw and
/// pitch but cannot say anything a user can act on. This turns the direction
/// into an area: "behind you and to your left, above eye level".
///
/// The yaw signs follow this engine's convention, the one [guidanceErrorDeg]
/// states: `+x̂` is the physical left, so a **positive** yaw is **to the left**.
/// Angles are relative to the direction the station was locked at, which is what
/// the plan is built against — not to any compass.
///
/// The bands are coarse on purpose. A coverage bin is 15° wide and its centre is
/// an average of the samples inside it, so a finer name ("22° to your left")
/// would be reporting precision the measurement does not have.
String gapAreaName(double yawDeg, double pitchDeg) {
  if (pitchDeg >= 85) return 'straight up, on the ceiling';
  if (pitchDeg <= -85) return 'straight down, on the floor';

  final y = ((yawDeg + 180) % 360) - 180;
  final a = y.abs();
  final side = switch (a) {
    _ when a <= 22.5 => 'ahead of you',
    _ when a < 67.5 =>
      y >
              0 //
          ? 'ahead and to your left'
          : 'ahead and to your right',
    _ when a < 112.5 =>
      y >
              0 //
          ? 'to your left'
          : 'to your right',
    _ when a < 157.5 =>
      y >
              0 //
          ? 'behind you and to your left'
          : 'behind you and to your right',
    _ => 'behind you',
  };
  final height = switch (pitchDeg) {
    _ when pitchDeg >= 45 => 'high, near the ceiling',
    _ when pitchDeg >= 20 => 'above eye level',
    _ when pitchDeg <= -45 => 'low, near the floor',
    _ when pitchDeg <= -20 => 'below eye level',
    _ => 'at eye level',
  };
  return '$side, $height';
}

/// The areas a coverage report is missing, largest first.
///
/// Capped at three: the point is to tell the user where to look, and a list of
/// every 15° bin that came out empty is a wall of text that says the same thing
/// the percentage already said.
List<String> gapAreaNames(List<UncoveredRegion> regions) => [
  for (final r in regions.take(3))
    '${gapAreaName(r.yawDeg, r.pitchDeg)} '
        '(${r.sharePct.toStringAsFixed(1)}% of the sphere)',
];
