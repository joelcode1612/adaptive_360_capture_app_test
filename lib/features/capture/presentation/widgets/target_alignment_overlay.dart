import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/capture/domain/services/alignment_calculator.dart';
import 'package:adaptive_360_capture_app/features/capture/presentation/widgets/bezel_reticle.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/guidance/projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// The guidance overlay: the bezel ring, and the arrow that points at the target.
///
/// The ring replaced a plain stroked circle. It is the same shape the target
/// wears, so what the user aims with is what will appear on the wall — and it can
/// carry the capture progress, which the circle could not.
///
/// **One pose, one target, one angle.** [alignment] is the same unsmoothed
/// [AlignmentResult] the instruction, the ring's verdict and the shutter read.
/// The arrow used to be built from a filtered copy of the camera orientation,
/// which meant that while the phone was turning it pointed where the target
/// *had been* — a pointer that disagrees with the arithmetic it is supposed to
/// be a picture of. Display smoothing costs jitter; it also costs truth, and
/// the direction is the part the user acts on.
///
/// What stays display-only is the ring's **fill**: [stabilityProgress] is the
/// hold, and [withinTolerance] is the raw alignment, so a ring cannot look
/// settled while the phone is still moving.
class TargetAlignmentOverlay extends StatelessWidget {
  const TargetAlignmentOverlay({
    super.key,
    required this.alignment,
    required this.withinTolerance,
    required this.stabilityProgress,
    this.captureBlocked = false,
    this.holdComplete = false,
    required this.anchored,
    required this.poseValid,
    required this.displayFov,
    this.displayProjectionMatrix,
    this.bezel,
    this.completed = false,
  });

  /// The authoritative alignment: the same result the gate and the instruction
  /// were computed from. Arrow geometry comes from its projected direction.
  final AlignmentResult? alignment;

  /// The display field of view the arrow projects the target with, in degrees.
  ///
  /// Required rather than defaulted because without it there is no honest
  /// projection: the pointer is drawn towards where the target lands on *this*
  /// viewport, which is a statement about the lens as well as the geometry.
  final ({double hfovDeg, double vfovDeg}) displayFov;

  /// The native renderer's display-geometry-aware camera projection for this
  /// frame. When unavailable, [displayFov] remains the safe fallback.
  final Float64List? displayProjectionMatrix;

  /// Whether the **unsmoothed** alignment is inside tolerance.
  final bool withinTolerance;

  /// 0…1 fill of the stability window.
  final double stabilityProgress;

  /// Whether a hard gate blocks the shutter despite the current aim. The AR
  /// capture screen uses this for station drift, so the central reticle mirrors
  /// the native target's amber warning instead of looking ready.
  final bool captureBlocked;

  /// The real hold completed and has authorized the shutter transaction.
  final bool holdComplete;

  /// Whether the target is in the scene: placed, at a known world position.
  ///
  /// A placed anchor ARCore has paused is still drawn — the renderer reads
  /// `anchor.pose` every frame and the mesh keeps the world position this app
  /// computed — so this is *not* "and tracked". What a pause costs is ARCore's
  /// confidence, and the shutter stays blocked on that separately.
  final bool anchored;

  /// Whether a camera pose may be aimed with.
  ///
  /// The arrow's direction is the target's world position projected through
  /// the camera pose, so without a valid pose there is no honest direction to
  /// draw — and an arrow built from a stale pose points somewhere the marker is
  /// not. When this is false nothing is drawn and the instruction line names
  /// the tracking state instead.
  final bool poseValid;

  /// The parsed bezel, or `null` before the asset loads.
  final GlbModel? bezel;

  /// Whether the target has been captured and recorded.
  final bool completed;

  @override
  Widget build(BuildContext context) {
    // The ring is the aim reference, so its size is a legibility decision, not
    // a decorative one: 0.34 of the short side puts a 390 dp phone at 133 dp and
    // a 320 dp phone at 116 dp, clamped to the specification's 128–144 band.
    // The previous 80–120 dp band read as a small badge over a busy camera
    // image, which is exactly the "difficult to locate" complaint.
    //
    // This is display-only. No tolerance, projection or capture gate reads it;
    // the ring is drawn on the optical axis and the shutter still fires from
    // `CaptureState.captureBlockReason`.
    final reticleSize = CaptureMetrics.reticleFor(MediaQuery.sizeOf(context));
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Stack(
          alignment: Alignment.center,
          children: [
            BezelReticle(
              size: reticleSize,
              progress: withinTolerance ? stabilityProgress : 0,
              withinTolerance: withinTolerance,
              completed: completed,
              holdComplete: holdComplete,
              captureBlocked: captureBlocked,
              bezel: bezel,
            ),
            CustomPaint(
              painter: _ArrowPainter(
                alignment: alignment,
                anchored: anchored,
                poseValid: poseValid,
                displayFov: displayFov,
                displayProjectionMatrix: displayProjectionMatrix,
                reticleSize: reticleSize,
              ),
              child: const SizedBox.expand(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The arrow that tells the user which way to move the phone.
///
/// Drawn from the **authoritative camera-frame target direction**,
/// [AlignmentResult.directionInCamera] — the same frozen target position and
/// live camera pose the marker, the wording and the capture gate are computed
/// from. Projecting it with ARCore's own camera matrix puts the pointer, the
/// GLB the renderer draws at the anchor and the sentence on one
/// world → camera → screen chain.
///
/// **Why not the display-filtered direction.** [AlignmentResult.pointerDirection]
/// is de-jittered for the marker, but the arrow is an instruction the user acts
/// on *now*: a smoothed bearing lags a real turn by a few frames and can keep
/// telling the user to turn after they have already arrived. The filter is
/// display-only by design, so the pointer reads the unsmoothed truth.
///
/// **Why not `atan2(−pitchCorrection, yawCorrection)`.** Those are angles, and
/// the pixel offset a direction produces is `fx·tan(yaw)` by `fy·tan(pitch)` —
/// the two focal lengths are not equal on a portrait display (`fy` is roughly
/// 1.6× `fx` for the shipped field of view), and even with square pixels the
/// `tan` is nonlinear. An arrow built from the angles is therefore right in
/// every quadrant and wrong in every diagonal: a 20°/20° error draws an arrow
/// about 14° away from where the marker actually is. Projecting the
/// camera-frame direction — which [AlignmentResult.directionInCamera] already
/// is — costs one call and removes the discrepancy, including the poles, where
/// the same call has no yaw to get wrong.
///
/// A target that is off screen is handled by [projectWithArCoreProjection]
/// itself: it pins the direction to the viewport edge along its own projected
/// bearing, and the shaft is clipped there. A target **behind** the camera has
/// no screen position at all; it gets the same edge bearing plus a second
/// chevron, so "keep turning" stays visually distinct from "the marker is just
/// outside the frame". When the target is exactly behind, the projection has no
/// x/y bearing to use, so the sign of the signed yaw correction picks the edge
/// to turn toward.
///
/// It disappears once the error is inside tolerance: at that point the ring's
/// fill is the whole message, and an arrow pointing at nothing is noise. That is
/// display-only — arming the shutter still reads
/// `CaptureState.captureBlockReason`, which never consults the arrow.
class _ArrowPainter extends CustomPainter {
  _ArrowPainter({
    required this.alignment,
    required this.anchored,
    required this.poseValid,
    required this.displayFov,
    required this.displayProjectionMatrix,
    required this.reticleSize,
  });

  final AlignmentResult? alignment;
  final bool anchored;
  final bool poseValid;

  /// Screen-x and screen-y field of view, in degrees: the same pair the
  /// projection contract uses to turn a camera-frame direction into pixels.
  final ({double hfovDeg, double vfovDeg}) displayFov;
  final Float64List? displayProjectionMatrix;

  /// Diameter of the aiming reticle, in logical pixels.
  final double reticleSize;

  @override
  void paint(Canvas canvas, Size size) {
    final a = alignment;
    // Three gates, and they are three different facts: a tracked node is in
    // the scene, there is a pose to aim with, and the alignment has an answer.
    // A paused anchor is deliberately hidden rather than projected from its
    // stale pose, so the arrow must remain neutral at the same time.
    if (!anchored || !poseValid || a == null || !a.usable) return;
    if (a.withinTolerance) return;
    if (size.width <= 0 || size.height <= 0) return;

    // Where the target lands on this viewport, from the frozen target position
    // and the live camera pose — the same two facts the marker and the capture
    // gate read. `directionInCamera` is deliberately unsmoothed: see the class
    // doc for why the pointer must not inherit the display filter's lag.
    final projection = projectWithArCoreProjection(
      a.directionInCamera,
      size.width,
      size.height,
      displayProjectionMatrix,
      fallbackHfovDeg: displayFov.hfovDeg,
      fallbackVfovDeg: displayFov.vfovDeg,
    );

    // `projectWithArCoreProjection` still returns a usable edge bearing for a
    // target behind the camera, because it falls back to the camera-frame x/y.
    // Only the exactly-behind case collapses to the viewport centre, where
    // there is no bearing left to draw.
    final behind = !a.inFront;
    final centre = Offset(size.width / 2, size.height / 2);
    var toTarget = Offset(projection.u, projection.v) - centre;
    var targetDistance = toTarget.distance;
    if (targetDistance < 1e-6) {
      // Dead centre with the target in front: no direction to point along.
      // Dead centre with the target behind: it sits on the optical axis, 180°
      // away, so derive the bearing from the signed yaw — the same sign the
      // "Turn right/left" sentence uses.
      if (!behind) return;
      final side = a.yawCorrectionDeg >= 0 ? 1.0 : -1.0;
      toTarget = Offset(side, 0);
      targetDistance = 1;
    }
    final direction = toTarget / targetDistance;

    const wing = 11.0;
    final magnitude = (a.angularErrorDeg / 90).clamp(0.25, 1.0);
    final start = reticleSize / 2 + 10;
    // The shaft still grows with the 3-D error, as it always did.
    var wanted = start + 30 + magnitude * (size.shortestSide * 0.20);
    if (projection.onScreen) {
      // ...but it stops at the marker instead of sailing past it: an overshoot
      // would put the head where the target is not. The floor keeps a visible
      // shaft for a target that projects inside the ring.
      wanted = math.max(start + 30, math.min(wanted, targetDistance - wing));
    }
    // Clipped at the viewport edge, so an off-screen target leaves an edge
    // indicator instead of a shaft running off the display.
    final tip = math.min(wanted, _distanceToEdge(centre, direction, size));
    final from = centre + direction * start;
    final to = centre + direction * tip;
    if (tip <= start + 1) return;

    final paint = Paint()
      ..color = CaptureColors.warn
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(from, to, paint);

    _drawChevron(canvas, to, direction, paint, wing);
    if (behind) {
      // A second chevron behind the first: "»" rather than "›". Behind is a
      // different instruction from "just outside the frame" — the user has to
      // turn roughly 180°, not nudge the phone a few degrees.
      _drawChevron(
        canvas,
        to - direction * (wing * 1.2),
        direction,
        paint,
        wing,
      );
    }
  }

  /// One arrowhead at [tip], opening back along [direction].
  static void _drawChevron(
    Canvas canvas,
    Offset tip,
    Offset direction,
    Paint paint,
    double wing,
  ) {
    final back = -direction;
    final perp = Offset(-direction.dy, direction.dx);
    canvas.drawLine(tip, tip + back * wing + perp * wing * 0.6, paint);
    canvas.drawLine(tip, tip + back * wing - perp * wing * 0.6, paint);
  }

  /// How far [direction] may be followed from [centre] before it leaves the
  /// viewport, with the same inset [project] pins its edge markers to.
  static double _distanceToEdge(Offset centre, Offset direction, Size size) {
    const inset = 12.0;
    var reach = double.infinity;
    if (direction.dx.abs() > 1e-9) {
      final edge = direction.dx > 0 ? size.width - inset : inset;
      reach = math.min(reach, (edge - centre.dx) / direction.dx);
    }
    if (direction.dy.abs() > 1e-9) {
      final edge = direction.dy > 0 ? size.height - inset : inset;
      reach = math.min(reach, (edge - centre.dy) / direction.dy);
    }
    // Only negative for a degenerate viewport; never draw backwards.
    return reach.isFinite ? math.max(reach, 0.0) : 0.0;
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.alignment != alignment ||
      old.anchored != anchored ||
      old.poseValid != poseValid ||
      old.displayFov != displayFov ||
      !identical(old.displayProjectionMatrix, displayProjectionMatrix) ||
      old.reticleSize != reticleSize;
}
