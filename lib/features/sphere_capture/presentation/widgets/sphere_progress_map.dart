import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/application/sphere_capture_controller.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/presentation/widgets/sphere_ring_palette.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// The 38-node capture progress map for the top-right corner.
///
/// It draws the same `buildSphereTargets()` directions the projection and the
/// shutter use, orthographically with a slight tilt so the three rings read as
/// a sphere rather than three lines. Four things have to be distinguishable at
/// 58 logical pixels, and they are separated by **shape**, not only colour, so
/// the map still works for a colour-blind user:
///
/// | state | mark |
/// |---|---|
/// | pending | hollow ring in the ring's own colour |
/// | captured | filled disc in the ring's own colour, white outline |
/// | current | solid white dot inside an amber halo |
/// | where you are looking | white dot with a dark core |
///
/// The ring colour therefore survives capture — middle blue, upper green, lower
/// orange, ceiling purple, floor red — which is what makes "the middle ring is
/// finished, the lower ring is next" readable without a legend.
class SphereProgressMap extends StatelessWidget {
  const SphereProgressMap({
    super.key,
    required this.controller,
    this.size = 58,
  });

  final SphereCaptureController controller;

  /// Diameter of the sphere drawing, in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (BuildContext context, Widget? child) => Container(
      width: size + 20,
      height: size + 22,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CaptureColors.hairlineOnDark),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _SphereProgressPainter(
              targets: controller.targets,
              guideTargetId: controller.guideTargetId,
              look: controller.lookDirectionInStartFrame,
            ),
          ),
          Positioned(
            bottom: 3,
            left: 0,
            right: 0,
            child: Text(
              '${controller.capturedCount} / $kSphereTargetCount',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.78),
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _SphereProgressPainter extends CustomPainter {
  _SphereProgressPainter({
    required this.targets,
    required this.guideTargetId,
    required this.look,
  });

  final List<SphereTargetState> targets;
  final int? guideTargetId;

  /// The phone's optical axis in the frozen start frame, or `null` before the
  /// first rotation sample.
  final Vec3? look;

  static const double _tiltDeg = 18;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 5;
    final tilt = _tiltDeg * math.pi / 180;
    final cosT = math.cos(tilt);
    final sinT = math.sin(tilt);

    /// Orthographic projection with the sphere tipped towards the viewer.
    /// Shared by the ring outlines, the dots and the look marker so they cannot
    /// disagree about where a direction is.
    Offset project(Vec3 d) {
      final y = d.y * cosT - d.z * sinT;
      return center + Offset(d.x * radius, -y * radius);
    }

    double depth(Vec3 d) => d.y * sinT + d.z * cosT;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = Colors.white.withValues(alpha: 0.18),
    );

    // The three ring planes, drawn as sampled polylines. Seeing the equator
    // level is how the user confirms the sphere was calibrated against gravity
    // rather than against the phone's tilt at Start.
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = Colors.white.withValues(alpha: 0.13);
    for (final pitch in <double>[0, kSphereRingPitchDeg, -kSphereRingPitchDeg]) {
      final path = Path();
      for (var i = 0; i <= 36; i++) {
        final p = project(sphereDirection(i * 10.0, pitch));
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(path, ringPaint);
    }

    // Back hemisphere first, so the front dots read as nearer.
    final ordered = List<SphereTargetState>.of(targets)
      ..sort((SphereTargetState a, SphereTargetState b) {
        final da = depth(a.spec.direction);
        final db = depth(b.spec.direction);
        return db.compareTo(da);
      });

    for (final target in ordered) {
      final d = target.spec.direction;
      final point = project(d);
      final front = depth(d) <= 0;
      final colour = sphereRingColor(target.spec);
      final isGuide = target.spec.targetId == guideTargetId;

      if (isGuide) {
        // Halo first so the marker itself stays crisp on top of it.
        canvas.drawCircle(
          point,
          5.4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = CaptureColors.warn,
        );
      }

      if (target.captured) {
        canvas.drawCircle(
          point,
          2.6,
          Paint()..color = colour.withValues(alpha: front ? 1 : 0.55),
        );
        canvas.drawCircle(
          point,
          2.6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = Colors.white.withValues(alpha: front ? 0.85 : 0.4),
        );
      } else {
        canvas.drawCircle(
          point,
          1.9,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1
            ..color = colour.withValues(alpha: front ? 0.8 : 0.28),
        );
      }

      if (isGuide) {
        canvas.drawCircle(
          point,
          1.7,
          Paint()..color = Colors.white,
        );
      }
    }

    final lookDirection = look;
    if (lookDirection != null) {
      final point = project(lookDirection);
      canvas.drawCircle(
        point,
        3.4,
        Paint()..color = Colors.black.withValues(alpha: 0.55),
      );
      canvas.drawCircle(point, 2.2, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_SphereProgressPainter oldDelegate) =>
      oldDelegate.guideTargetId != guideTargetId ||
      oldDelegate.look != look ||
      // Comparing counts alone would miss a retake: the same number of targets
      // captured, but a different set.
      !_sameCaptured(oldDelegate.targets, targets);

  static bool _sameCaptured(
    List<SphereTargetState> a,
    List<SphereTargetState> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].captured != b[i].captured) return false;
    }
    return true;
  }
}
