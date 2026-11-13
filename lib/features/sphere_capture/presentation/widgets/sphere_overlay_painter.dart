import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/application/sphere_capture_controller.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// Paints the 38 projected targets, the fixed reticle and the hold ring.
///
/// Repaints directly from the controller ([CustomPainter.repaint]) so a 50 Hz
/// sensor stream does not rebuild any widget: only this canvas is repainted.
/// That is what keeps the camera preview and the rest of the tree at 60 FPS
/// while the sphere follows the phone.
class SphereOverlayPainter extends CustomPainter {
  SphereOverlayPainter({required this.controller, required this.projection})
    : super(repaint: controller);

  final SphereCaptureController controller;
  final SphereProjection projection;

  /// Marker radius in logical pixels, scaled to the viewport and clamped.
  ///
  /// About 14 px on a 443-logical-pixel-wide phone — roughly double the
  /// previous 8 px pending marker, which the device recording showed as
  /// barely visible. The clamp keeps a tablet from getting dinner-plate
  /// markers while still scaling up on a large phone.
  double get _baseRadius =>
      (math.min(projection.width, projection.height) * 0.032).clamp(14.0, 24.0);

  /// Radius of the centre aiming plate, in logical pixels.
  ///
  /// **The plate edge is the 5° alignment cone.** That is what makes the
  /// reference design's big white circle functional rather than decorative:
  /// a target under the plate is inside the shutter's tolerance, so the green
  /// wedge is filling; a target outside it keeps its own marker and hairline.
  /// A larger plate would hide targets that are close but not yet aligned.
  double get _plateRadius => projection.toleranceRadiusPx.clamp(60.0, 118.0);

  double get _ringRadius => _plateRadius * 0.44;

  double get _ringWidth => _plateRadius * 0.11;

  @override
  void paint(Canvas canvas, Size size) {
    final device = controller.deviceToWorld;
    final start = controller.startDeviceToWorld;
    final activeId = controller.activeTargetId;
    final aligned =
        controller.activeErrorDeg <= controller.toleranceDeg &&
        controller.phase == SphereCapturePhase.ready;

    _paintTargets(canvas, device, start, activeId, aligned);
    _paintReticle(canvas);
    _paintGuideArrow(canvas, device, start);
  }

  void _paintTargets(
    Canvas canvas,
    Quat? device,
    Quat? start,
    int? activeId,
    bool aligned,
  ) {
    if (device == null || start == null) return;
    final toleranceRadius = projection.toleranceRadiusPx;
    final center = Offset(projection.width / 2, projection.height / 2);

    for (final target in controller.targets) {
      final direction = sphereTargetCameraDirection(
        deviceToWorld: device,
        startDeviceToWorld: start,
        startDirection: target.spec.direction,
      );
      final point = projection.project(direction);
      if (point == null) continue;
      if (!projection.isOnScreen(point, margin: 48)) continue;

      final isActive = target.spec.targetId == activeId;
      final error = isActive
          ? controller.activeErrorDeg
          : reticleErrorDeg(direction);
      // A target is "in the cone" when it is inside the same angle the shutter
      // uses. Drawing it green before the gate agrees would be a lie.
      final inCone = error <= controller.toleranceDeg;

      if (target.captured) {
        _paintCaptured(canvas, point);
        continue;
      }

      // The centre plate represents the target being aimed at; drawing its
      // marker underneath an opaque plate would be invisible ink.
      if (isActive && (point - center).distance < _plateRadius) continue;

      if (isActive) {
        _paintActive(
          canvas,
          point,
          targetId: target.spec.targetId,
          aligned: aligned && inCone,
          progress: controller.holdProgress,
          toleranceRadius: toleranceRadius,
        );
      } else {
        _paintPending(canvas, point, inCone: inCone);
      }
    }
  }

  void _paintCaptured(Canvas canvas, Offset point) {
    final radius = _baseRadius * 0.85;
    canvas.drawCircle(
      point,
      radius,
      Paint()..color = CaptureColors.ok.withValues(alpha: 0.9),
    );
    canvas.drawCircle(
      point,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = Colors.white.withValues(alpha: 0.8),
    );
    // A small tick, so "captured" survives a colour-blind palette too.
    final tick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.18
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

  void _paintPending(Canvas canvas, Offset point, {required bool inCone}) {
    final radius = _baseRadius;
    canvas.drawCircle(
      point,
      radius,
      Paint()
        ..color = inCone
            ? CaptureColors.ok.withValues(alpha: 0.35)
            : Colors.black.withValues(alpha: 0.28),
    );
    canvas.drawCircle(
      point,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = inCone
            ? CaptureColors.ok
            : Colors.white.withValues(alpha: 0.8),
    );
  }

  void _paintActive(
    Canvas canvas,
    Offset point, {
    required int targetId,
    required bool aligned,
    required double progress,
    required double toleranceRadius,
  }) {
    final radius = _baseRadius * 1.55;
    final ringRadius = _baseRadius * 2.05;
    final colour = aligned ? CaptureColors.ok : Colors.white;
    canvas.drawCircle(
      point,
      radius,
      Paint()..color = Colors.black.withValues(alpha: 0.35),
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
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = CaptureColors.ok;
      canvas.drawArc(
        Rect.fromCircle(center: point, radius: ringRadius),
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        arc,
      );
    }

    // The id inside the active marker makes the pill's "Target N" claim
    // checkable at a glance instead of requiring a mental count.
    final label = TextPainter(
      text: TextSpan(
        text: '$targetId',
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.8,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, point - Offset(label.width / 2, label.height / 2));

    // A hairline from the reticle to the active target makes the turn
    // direction legible at a glance when the marker is near the edge.
    final center = Offset(projection.width / 2, projection.height / 2);
    final distance = (point - center).distance;
    if (distance > toleranceRadius + 12 && distance < 420) {
      canvas.drawLine(
        center + (point - center) / distance * (toleranceRadius + 6),
        point - (point - center) / distance * (radius * 1.2),
        Paint()
          ..strokeWidth = 1.2
          ..color = Colors.white.withValues(alpha: 0.2),
      );
    }
  }

  /// The centre aiming plate: a white disc, a grey ring and a green wedge.
  ///
  /// This is the reference design's target plate used as the reticle: the
  /// white disc is the aim point, the grey ring is the target's bezel, and the
  /// green wedge fills with [SphereCaptureController.holdProgress] while the
  /// active target is inside the 5° cone. The wedge therefore means "the
  /// shutter is arming", not merely "a target exists".
  void _paintReticle(Canvas canvas) {
    final center = Offset(projection.width / 2, projection.height / 2);
    final plate = _plateRadius;
    final ring = _ringRadius;
    final ringWidth = _ringWidth;

    canvas.drawCircle(
      center,
      plate,
      Paint()..color = Colors.white.withValues(alpha: 0.93),
    );
    canvas.drawCircle(
      center,
      plate,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.black.withValues(alpha: 0.10),
    );
    canvas.drawCircle(
      center,
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..color = const Color(0xFF6F7C88),
    );

    final progress = controller.holdProgress.clamp(0.0, 1.0);
    if (progress > 0) {
      final inner = ring - ringWidth / 2;
      final wedge = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(
          Rect.fromCircle(center: center, radius: inner),
          -math.pi / 2,
          2 * math.pi * progress,
          false,
        )
        ..close();
      canvas.drawPath(wedge, Paint()..color = CaptureColors.ok);
    }

    final aligned =
        controller.activeErrorDeg <= controller.toleranceDeg &&
        controller.phase == SphereCapturePhase.ready;
    if (aligned) {
      canvas.drawCircle(
        center,
        ring + ringWidth / 2 + 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = CaptureColors.ok,
      );
    }

    canvas.drawCircle(center, 2.5, Paint()..color = const Color(0xFF6F7C88));
  }

  /// An edge arrow to the next frame in the stitch path.
  ///
  /// Only drawn when the guide target is outside the safe area (or behind the
  /// camera); an on-screen target is already visible as a marker with the
  /// hairline from the reticle. The arrow carries the live turn angle, so the
  /// user can follow it without reading the pill.
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
    if (point != null && safe.contains(point)) return;

    final Offset bearing;
    if (point != null) {
      bearing = point - center;
    } else {
      // Behind the camera: there is no projection, so use the horizontal and
      // vertical components directly. A target exactly behind has no bearing
      // at all; pointing right is the honest "turn to find it" default.
      bearing = Offset(direction.x, -direction.y);
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

    final label = TextPainter(
      text: TextSpan(
        text: '${controller.guideErrorDeg.round()}°',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelCenter = tip - unit * 34;
    final background = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: labelCenter,
        width: label.width + 12,
        height: label.height + 6,
      ),
      const Radius.circular(9),
    );
    canvas.drawRRect(
      background,
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
