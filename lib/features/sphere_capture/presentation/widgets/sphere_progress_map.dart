import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/application/sphere_capture_controller.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/presentation/widgets/sphere_ring_palette.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// The 38-node capture progress map for the top-right corner.
///
/// The dots are the same `buildSphereTargets()` directions the projection and
/// the shutter use, drawn orthographically with a slight tilt so the three
/// rings read as a sphere rather than three lines. Captured nodes are green,
/// the guided node has an amber ring, and the rest are dim — the reference
/// design's widget, reduced to the size a phone can actually show.
class SphereProgressMap extends StatelessWidget {
  const SphereProgressMap({
    super.key,
    required this.controller,
    this.size = 54,
  });

  final SphereCaptureController controller;

  /// Diameter of the sphere drawing, in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (BuildContext context, Widget? child) => Container(
      width: size + 20,
      height: size + 20,
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
                color: Colors.white.withValues(alpha: 0.72),
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
  _SphereProgressPainter({required this.targets, required this.guideTargetId});

  final List<SphereTargetState> targets;
  final int? guideTargetId;

  static const double _tiltDeg = 18;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = Colors.white.withValues(alpha: 0.18),
    );

    final tilt = _tiltDeg * math.pi / 180;
    final cosT = math.cos(tilt);
    final sinT = math.sin(tilt);

    for (final target in targets) {
      final d = target.spec.direction;
      final y = d.y * cosT - d.z * sinT;
      final depth = d.y * sinT + d.z * cosT;
      final point = center + Offset(d.x * radius, -y * radius);
      final front = depth <= 0;
      final captured = target.captured;

      final Color colour;
      if (captured) {
        colour = CaptureColors.ok;
      } else {
        // Pending dots carry their ring's colour, matching the reference
        // legend; the back half is dimmed so the sphere reads in 3D.
        colour = sphereRingColor(
          target.spec,
        ).withValues(alpha: front ? 0.85 : 0.3);
      }
      canvas.drawCircle(point, captured ? 2.6 : 1.9, Paint()..color = colour);
      if (target.spec.targetId == guideTargetId) {
        canvas.drawCircle(
          point,
          4.6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = CaptureColors.warn,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SphereProgressPainter oldDelegate) =>
      oldDelegate.guideTargetId != guideTargetId ||
      oldDelegate.targets.where((SphereTargetState t) => t.captured).length !=
          targets.where((SphereTargetState t) => t.captured).length;
}
