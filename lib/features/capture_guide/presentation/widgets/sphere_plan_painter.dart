import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The illustrated spherical capture plan, ported from the reference's
/// `sphere()` SVG (224-box, 91 radius, 0.34 tilt, points depth-sorted and
/// shaded by z).
///
/// Two renderings:
///
/// * [SphereMapStyle.plan] — every direction drawn in its ring colour. Used by
///   the intro and capture-plan sections.
/// * [SphereMapStyle.progressExample] — an instructional example map for the
///   progress section: three saved directions (green with a check), the next
///   one numbered, everything else unfilled. It never reflects live capture
///   state; the capture screen's own progress map owns real progress.
enum SphereMapStyle { plan, progressExample }

/// A projected plan direction: screen fraction plus the depth term the
/// reference uses for back-to-front sorting and opacity.
class _Projected {
  const _Projected(this.fraction, this.z);
  final Offset fraction;
  final double z;
}

class SpherePlanPainter extends CustomPainter {
  const SpherePlanPainter({required this.style});

  final SphereMapStyle style;

  // Ring colours, from the reference SVG.
  static const Color _middle = Color(0xFF1F6FB2);
  static const Color _upper = Color(0xFF3FA97A);
  static const Color _lower = Color(0xFFE08A2E);
  static const Color _zenith = Color(0xFF8B5CF6);
  static const Color _nadir = Color(0xFFDC4C4C);
  static const double _ringPitchDeg = 35;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * (91 / 224);

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = const Color(0xFFEFF6FF),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = const Color(0xFF93C5FD)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * (2 / 224),
    );

    // Equator and meridian guides.
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: radius * 2,
        height: radius * 2 * (30 / 91),
      ),
      Paint()
        ..color = const Color(0xFF93C5FD)
        ..style = PaintingStyle.stroke,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: radius * 2 * (40 / 91),
        height: radius * 2,
      ),
      Paint()
        ..color = const Color(0xFFBFDBFE)
        ..style = PaintingStyle.stroke,
    );

    if (style == SphereMapStyle.plan) {
      _paintPlanDots(canvas, size);
    } else {
      _paintProgressExample(canvas, size);
    }
  }

  void _paintPlanDots(Canvas canvas, Size size) {
    final dots = <(_Projected, Color, bool)>[];
    for (var i = 0; i < 12; i++) {
      dots.add((_project(0, i * 30.0), _middle, false));
    }
    dots.add((_project(90, 0), _zenith, true));
    for (var i = 0; i < 12; i++) {
      dots.add((_project(_ringPitchDeg, i * 30.0), _upper, false));
    }
    for (var i = 0; i < 12; i++) {
      dots.add((_project(-_ringPitchDeg, i * 30.0), _lower, false));
    }
    dots.add((_project(-90, 0), _nadir, true));
    // The reference draws back-to-front, opacity ramping with depth.
    dots.sort((a, b) => a.$1.z.compareTo(b.$1.z));
    final poleRadius = size.width * (4.5 / 224);
    final ringRadius = size.width * (3.8 / 224);
    for (final (projected, color, isPole) in dots) {
      final opacity = 0.53 + 0.47 * ((projected.z + 1) / 2);
      _circle(
        canvas,
        size,
        projected.fraction,
        fill: color,
        radius: isPole ? poleRadius : ringRadius,
        fillOpacity: opacity,
        strokeOpacity: opacity,
      );
    }
  }

  /// The progress section's example: three saved, one next, everything else
  /// pending. This is a fixed teaching example, not live capture state.
  void _paintProgressExample(Canvas canvas, Size size) {
    const savedCount = 3;
    const nextIndex = savedCount;
    final dotRadius = size.width * (3.8 / 224);
    for (var i = 0; i < 12; i++) {
      final fraction = _project(0, i * 30.0).fraction;
      if (i < savedCount) {
        _circle(
          canvas,
          size,
          fraction,
          fill: const Color(0xFF0F766E),
          radius: dotRadius * 1.25,
        );
        _check(canvas, size, fraction, dotRadius * 0.85);
      } else if (i == nextIndex) {
        _circle(
          canvas,
          size,
          fraction,
          fill: _middle,
          radius: dotRadius * 1.45,
          label: '${i + 1}',
        );
      } else {
        _pending(canvas, size, fraction, dotRadius * 0.95);
      }
    }
    // The poles and the upper/lower rings stay pending.
    for (final (pitch, yaw) in <(double, double)>[
      (90.0, 0.0),
      (-90.0, 0.0),
      for (var i = 0; i < 12; i++) (_ringPitchDeg, i * 30.0),
      for (var i = 0; i < 12; i++) (-_ringPitchDeg, i * 30.0),
    ]) {
      _pending(canvas, size, _project(pitch, yaw).fraction, dotRadius * 0.95);
    }
  }

  void _circle(
    Canvas canvas,
    Size size,
    Offset fraction, {
    required Color fill,
    required double radius,
    double fillOpacity = 1,
    double strokeOpacity = 1,
    String? label,
  }) {
    final p = Offset(size.width * fraction.dx, size.height * fraction.dy);
    if (fillOpacity > 0) {
      canvas.drawCircle(
        p,
        radius,
        Paint()..color = fill.withValues(alpha: fillOpacity),
      );
    }
    if (strokeOpacity > 0) {
      canvas.drawCircle(
        p,
        radius,
        Paint()
          ..color = Colors.white.withValues(alpha: strokeOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * (0.7 / 224),
      );
    }
    if (label != null) {
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontSize: radius * 0.95,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }
  }

  void _pending(Canvas canvas, Size size, Offset fraction, double radius) {
    _circle(
      canvas,
      size,
      fraction,
      fill: Colors.transparent,
      radius: radius,
      strokeOpacity: 0.9,
    );
  }

  void _check(Canvas canvas, Size size, Offset fraction, double r) {
    final p = Offset(size.width * fraction.dx, size.height * fraction.dy);
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.4, r * 0.28)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(p.dx - r * 0.45, p.dy)
      ..lineTo(p.dx - r * 0.1, p.dy + r * 0.4)
      ..lineTo(p.dx + r * 0.55, p.dy - r * 0.4);
    canvas.drawPath(path, paint);
  }

  /// Orthographic projection with the reference's 0.34 vertical tilt, in a
  /// 224-box with a 91 radius, expressed as canvas fractions.
  _Projected _project(double pitchDeg, double yawDeg) {
    const tilt = 0.34;
    final pitch = pitchDeg * math.pi / 180;
    final yaw = yawDeg * math.pi / 180;
    final x = math.cos(pitch) * math.sin(yaw);
    final y = math.sin(pitch);
    final z = math.cos(pitch) * math.cos(yaw);
    const c = 112.0;
    const r = 91.0;
    final px = c + r * x;
    final py = c - r * (y * math.cos(tilt) - z * math.sin(tilt));
    return _Projected(Offset(px / 224, py / 224), z);
  }

  @override
  bool shouldRepaint(covariant SpherePlanPainter oldDelegate) =>
      oldDelegate.style != style;
}
