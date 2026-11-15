import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/application/sphere_capture_controller.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// Paints the 38 projected targets, the aiming ring and the hold arc.
///
/// Repaints directly from the controller ([CustomPainter.repaint]) so a 50 Hz
/// sensor stream does not rebuild any widget: only this canvas is repainted.
/// That is what keeps the camera preview and the rest of the tree at 60 FPS
/// while the sphere follows the phone.
///
/// ## Draw order is a correctness property, not a style choice
///
/// 1. every captured and pending marker, **except** the selected one;
/// 2. the aiming ring;
/// 3. the selected marker, **on top of** the ring;
/// 4. the off-screen arrow.
///
/// The selected marker used to be skipped as soon as it came within the old
/// opaque plate, so the target the user was aligning vanished exactly when it
/// was about to be captured. Drawing it last means the user can watch it enter
/// the ring, which is the whole visual contract of an automatic shutter.
class SphereOverlayPainter extends CustomPainter {
  SphereOverlayPainter({required this.controller, required this.projection})
    : super(repaint: controller);

  final SphereCaptureController controller;
  final SphereProjection projection;

  /// Marker radius in logical pixels, scaled to the viewport and clamped.
  double get _baseRadius =>
      (math.min(projection.width, projection.height) * 0.030).clamp(13.0, 22.0);

  /// Radius of the aiming ring, in logical pixels.
  ///
  /// **This radius is the 5° capture cone**, not a decoration: a target centre
  /// inside this circle is inside the shutter's tolerance, so the ring fills.
  /// That is what lets the user predict the shutter instead of guessing.
  ///
  /// The clamp is a sanity floor/ceiling only — it is deliberately wide enough
  /// never to bite on a real phone viewport, because a ring drawn larger than
  /// the cone would invite the user to stop turning while the shutter is still
  /// shut. The capture gate itself always uses the true 3-D angle and never
  /// reads this number.
  double get _aimRadius => projection.toleranceRadiusPx.clamp(24.0, 160.0);

  @override
  void paint(Canvas canvas, Size size) {
    final device = controller.deviceToWorld;
    final start = controller.startDeviceToWorld;
    final activeId = controller.activeTargetId;
    final aligned =
        controller.activeErrorDeg <= controller.toleranceDeg &&
        controller.phase == SphereCapturePhase.ready;

    // Project first, draw second. The selected point has to be known *before*
    // any captured marker is drawn, so a finished target sitting on top of the
    // current one can fade instead of competing with it.
    final projected = _projectTargets(device, start);
    Offset? activePoint;
    for (final entry in projected) {
      if (entry.target.spec.targetId == activeId) {
        activePoint = entry.point;
        break;
      }
    }

    for (final entry in projected) {
      if (entry.target.spec.targetId == activeId) continue;
      if (entry.target.captured) {
        final near =
            activePoint != null &&
            (entry.point - activePoint).distance < _baseRadius * 3.4;
        _paintCaptured(canvas, entry.point, nearActive: near);
      } else {
        _paintPending(canvas, entry.point);
      }
    }

    _paintAimingRing(canvas, aligned: aligned);

    if (activePoint != null && activeId != null) {
      _paintActive(
        canvas,
        activePoint,
        targetId: activeId,
        aligned: aligned,
        progress: controller.holdProgress,
      );
    }
    _paintGuideArrow(canvas, device, start);
  }

  /// Every target that is currently in front of the camera and near enough to
  /// the viewport to be worth drawing.
  List<({SphereTargetState target, Offset point})> _projectTargets(
    Quat? device,
    Quat? start,
  ) {
    if (device == null || start == null) {
      return const <({SphereTargetState target, Offset point})>[];
    }
    final out = <({SphereTargetState target, Offset point})>[];
    for (final target in controller.targets) {
      final direction = sphereTargetCameraDirection(
        deviceToWorld: device,
        startDeviceToWorld: start,
        startDirection: target.spec.direction,
      );
      final point = projection.project(direction);
      if (point == null) continue;
      if (!projection.isOnScreen(point, margin: 40)) continue;
      out.add((target: target, point: point));
    }
    return out;
  }

  void _paintCaptured(Canvas canvas, Offset point, {required bool nearActive}) {
    final radius = _baseRadius * 0.78;
    // A finished target must never compete with the one being aimed at, so it
    // fades back when it happens to sit on top of the selected marker.
    final alpha = nearActive ? 0.30 : 0.90;
    canvas.drawCircle(
      point,
      radius,
      Paint()..color = CaptureColors.ok.withValues(alpha: alpha),
    );
    canvas.drawCircle(
      point,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: nearActive ? 0.3 : 0.75),
    );
    if (nearActive) return;
    // A small tick, so "captured" survives a colour-blind palette too.
    final tick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.20
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    canvas.drawLine(
      point + Offset(-radius * 0.42, radius * 0.07),
      point + Offset(-radius * 0.11, radius * 0.39),
      tick,
    );
    canvas.drawLine(
      point + Offset(-radius * 0.11, radius * 0.39),
      point + Offset(radius * 0.48, -radius * 0.36),
      tick,
    );
  }

  /// A target that is not the selected one.
  ///
  /// Deliberately **never** tinted green, even when it happens to sit under the
  /// reticle. Only the selected target can be captured, so a green ring on any
  /// other marker would advertise a shutter that will never fire — which is
  /// exactly what made "the arrow and the automatic capture pick different
  /// targets" look true.
  void _paintPending(Canvas canvas, Offset point) {
    final radius = _baseRadius;
    canvas.drawCircle(
      point,
      radius,
      Paint()..color = Colors.black.withValues(alpha: 0.26),
    );
    canvas.drawCircle(
      point,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = Colors.white.withValues(alpha: 0.78),
    );
  }

  void _paintActive(
    Canvas canvas,
    Offset point, {
    required int targetId,
    required bool aligned,
    required double progress,
  }) {
    final radius = _baseRadius * 1.55;
    final ringRadius = _baseRadius * 2.05;
    final colour = aligned ? CaptureColors.ok : Colors.white;

    // A dark core keeps the white ring and the number readable over a bright
    // window without hiding the scene the way the old opaque plate did.
    canvas.drawCircle(
      point,
      radius,
      Paint()..color = Colors.black.withValues(alpha: 0.42),
    );
    canvas.drawCircle(
      point,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..color = colour,
    );

    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: point, radius: ringRadius),
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..strokeCap = StrokeCap.round
          ..color = CaptureColors.ok,
      );
    }

    // The id inside the active marker makes the pill's "Target N" claim
    // checkable at a glance instead of requiring a mental count.
    final label = TextPainter(
      text: TextSpan(
        text: '$targetId',
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.82,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, point - Offset(label.width / 2, label.height / 2));

    // A hairline from the reticle to the active target makes the turn
    // direction legible at a glance when the marker is near the edge.
    final center = Offset(projection.width / 2, projection.height / 2);
    final delta = point - center;
    final distance = delta.distance;
    if (distance > _aimRadius + 10 && distance < 460) {
      final unit = delta / distance;
      canvas.drawLine(
        center + unit * (_aimRadius + 4),
        point - unit * (radius * 1.15),
        Paint()
          ..strokeWidth = 1.2
          ..color = Colors.white.withValues(alpha: 0.22),
      );
    }
  }

  /// The centre aiming ring: a visible circle with a **transparent interior**.
  ///
  /// It used to be a 93%-opaque white disc. That disc covered the middle of the
  /// viewfinder — the one part of the frame the user is aiming — and a target
  /// approaching the centre disappeared behind it. A ring keeps the aim point
  /// unmistakable while leaving the scene, and the incoming marker, visible.
  ///
  /// Three states are drawn from real controller state, never from a timer:
  /// the green arc is [SphereCaptureController.holdProgress], the ring turns
  /// green when the target is inside the 5° cone, and the centre dot is the
  /// exact optical axis.
  void _paintAimingRing(Canvas canvas, {required bool aligned}) {
    final center = Offset(projection.width / 2, projection.height / 2);
    final radius = _aimRadius;
    final progress = controller.holdProgress.clamp(0.0, 1.0);

    // Dark halo first, so the ring survives a white wall or a bright window.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.6
        ..color = Colors.black.withValues(alpha: 0.22),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = aligned
            ? CaptureColors.ok
            : Colors.white.withValues(alpha: 0.94),
    );

    // A second, fainter ring at 62% reads as a sight rather than a bubble.
    canvas.drawCircle(
      center,
      radius * 0.62,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = Colors.white.withValues(alpha: 0.26),
    );

    // Four cardinal ticks sit outside the ring so they never cover the marker.
    final tick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.85);
    for (var i = 0; i < 4; i++) {
      final angle = i * math.pi / 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * (radius + 3),
        center + direction * (radius + 9),
        tick,
      );
    }

    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..strokeCap = StrokeCap.round
          ..color = CaptureColors.ok,
      );
    }

    if (aligned) {
      canvas.drawCircle(
        center,
        radius + 5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = CaptureColors.ok.withValues(alpha: 0.55),
      );
    }

    canvas.drawCircle(
      center,
      2.6,
      Paint()..color = Colors.black.withValues(alpha: 0.35),
    );
    canvas.drawCircle(center, 1.8, Paint()..color = Colors.white);
  }

  /// An edge arrow to the selected target while it is outside the viewfinder.
  ///
  /// With 30° ring spacing and a ~50° horizontal field of view, the next target
  /// is normally **outside** the screen while the current one is centred — the
  /// specification is explicit that this is expected and must not be papered
  /// over by moving the target. So the arrow is the primary instruction: it
  /// carries the live turn angle and the direction, and disappears the moment
  /// the real marker is on screen and the hairline takes over.
  void _paintGuideArrow(Canvas canvas, Quat? device, Quat? start) {
    if (controller.phase != SphereCapturePhase.ready) return;
    final guide = controller.guideTarget;
    if (guide == null || device == null || start == null) return;

    final direction = sphereTargetCameraDirection(
      deviceToWorld: device,
      startDeviceToWorld: start,
      startDirection: guide.spec.direction,
    );
    final point = projection.project(direction);
    final safe = Rect.fromLTRB(
      28,
      96,
      projection.width - 28,
      projection.height - 210,
    );
    final center = Offset(projection.width / 2, projection.height / 2);
    if (point != null && !controller.guideBehind && safe.contains(point)) {
      return;
    }

    final Offset bearing;
    if (point != null && !controller.guideBehind) {
      bearing = point - center;
    } else {
      // Behind the camera there is no projection at all. The horizontal part is
      // taken from the *signed turn angle* rather than from `direction.x`,
      // because `x` collapses to zero exactly when the target is behind — which
      // is when the arrow matters most. A target dead astern has no preferred
      // way round, and "turn right" is the honest 180° answer.
      final turn = controller.guideTurnDeg;
      final pitchRad = controller.guidePitchDeg * math.pi / 180;
      bearing = Offset(
        turn.abs() < 1e-3 ? 1 : (turn > 0 ? 1 : -1),
        -math.sin(pitchRad),
      );
    }
    final length = bearing.distance;
    if (length < 1e-6) return;
    final unit = bearing / length;
    final edge = _rayToRect(center, unit, safe);
    final tip = edge - unit * 4;
    final base = tip - unit * 16;
    final perpendicular = Offset(-unit.dy, unit.dx);

    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(base.dx + perpendicular.dx * 9, base.dy + perpendicular.dy * 9)
      ..lineTo(base.dx - perpendicular.dx * 9, base.dy - perpendicular.dy * 9)
      ..close();
    canvas.drawPath(
      path,
      Paint()..color = CaptureColors.ok.withValues(alpha: 0.95),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.85),
    );

    // Two components, not one total: the user needs to know *which* way to
    // turn and how far to tilt, because a 40° error made of 10° turn and 39°
    // tilt is a completely different instruction from 40° turn and level.
    // Both come from the controller's projected target direction — the same
    // numbers the hold gate uses — never from screen geometry.
    final turn = controller.guideTurnDeg;
    final pitch = controller.guidePitchDeg;
    final String horizontal = turn.abs() < 1
        ? 'aligned'
        : '${turn.abs().round()}° ${turn > 0 ? 'right' : 'left'}';
    final String vertical = pitch.abs() < 1
        ? 'level'
        : '${pitch.abs().round()}° ${pitch > 0 ? 'up' : 'down'}';
    final label = TextPainter(
      text: TextSpan(
        text: '$horizontal\n$vertical',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          height: 1.25,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    // Keep the two-line box just inside the arrow, offset by its own height so
    // a vertical edge does not clip it.
    final labelCenter = tip - unit * (label.height / 2 + 12);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: labelCenter,
          width: label.width + 12,
          height: label.height + 6,
        ),
        const Radius.circular(9),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    label.paint(
      canvas,
      labelCenter - Offset(label.width / 2, label.height / 2),
    );
  }

  /// Where a ray from [origin] along [unit] leaves [rect].
  Offset _rayToRect(Offset origin, Offset unit, Rect rect) {
    var distance = double.infinity;
    if (unit.dx > 1e-6) {
      distance = math.min(distance, (rect.right - origin.dx) / unit.dx);
    }
    if (unit.dx < -1e-6) {
      distance = math.min(distance, (rect.left - origin.dx) / unit.dx);
    }
    if (unit.dy > 1e-6) {
      distance = math.min(distance, (rect.bottom - origin.dy) / unit.dy);
    }
    if (unit.dy < -1e-6) {
      distance = math.min(distance, (rect.top - origin.dy) / unit.dy);
    }
    if (!distance.isFinite || distance <= 0) return origin;
    return origin + unit * distance;
  }

  @override
  bool shouldRepaint(SphereOverlayPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.projection.width != projection.width ||
      oldDelegate.projection.height != projection.height;
}
