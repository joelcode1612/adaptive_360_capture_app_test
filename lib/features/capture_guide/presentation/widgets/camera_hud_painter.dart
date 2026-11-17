import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Schematic camera-overlay illustration, ported from the reference's
/// `guideHudSvg` (nominal 330×220, or 330×440 for the large teaching card).
///
/// It shows the three things the live capture screen reports — the fixed
/// centre aiming ring, a separate numbered target marker, and the green hold
/// arc once aligned — plus the "pending" marker styles the progress map
/// legend describes. Geometry is deliberately schematic: the real screen
/// projects markers from sensor data via `SphereProjection`.
///
/// This is an instructional drawing only; it never reads the camera.
class CameraHudPainter extends CustomPainter {
  const CameraHudPainter({
    required this.targetId,
    required this.targetFraction,
    this.aligned = false,
    this.large = false,
  });

  /// The number printed inside the example target marker (from the real plan).
  final int targetId;

  /// Where the example target sits, as fractions of the nominal box.
  final Offset targetFraction;

  /// Whether the aligned state (green ring + hold arc) is drawn.
  final bool aligned;

  /// Large teaching-card proportions (330×440) instead of the 330×220 pair.
  final bool large;

  static const Color _stage = Color(0xFF26384A);
  static const Color _green = Color(0xFF36D399);
  static const Color _ringIdle = Color(0xFFF8FAFC);

  @override
  void paint(Canvas canvas, Size size) {
    final nominalH = large ? 440.0 : 220.0;
    final scale = size.width / 330;
    double x(double nominalX) => nominalX * scale;
    double y(double nominalY) => nominalY * scale;
    double w(double nominalW) => nominalW * scale;

    // Stage.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = _stage,
    );

    // Wall sketch and reference grid.
    final wall = Paint()
      ..color = const Color(0xFF7890A4).withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w(2);
    final wallPath = Path()
      ..moveTo(0, y(nominalH * 0.32))
      ..lineTo(x(120), y(nominalH * 0.25))
      ..lineTo(x(330), y(nominalH * 0.34));
    canvas.drawPath(wallPath, wall);
    final grid = Paint()
      ..color = const Color(0xFF9AB0BF).withValues(alpha: 0.23)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w(2);
    canvas.drawLine(Offset(x(105), 0), Offset(x(105), size.height), grid);
    canvas.drawLine(
      Offset(0, y(nominalH * 0.76)),
      Offset(size.width, y(nominalH * 0.76)),
      grid,
    );

    // Window on the back wall.
    final windowRect = Rect.fromLTWH(
      x(15),
      y(nominalH * 0.47),
      w(66),
      y(nominalH * 0.25),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(windowRect, Radius.circular(w(2))),
      Paint()..color = const Color(0xFF3A5366),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(windowRect, Radius.circular(w(2))),
      Paint()
        ..color = const Color(0xFF728CA0).withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w(1.4),
    );
    canvas.drawLine(
      Offset(x(22), y(nominalH * 0.60)),
      Offset(x(73), y(nominalH * 0.60)),
      Paint()
        ..color = const Color(0xFF819CAF).withValues(alpha: 0.4)
        ..strokeWidth = w(1.4),
    );

    // Pending-marker pair: an unfilled marker and a saved one with a check.
    final pendingWhite = Offset(
      x(large ? 67 : 62),
      y(large ? 94 : 61),
    );
    canvas.drawCircle(
      pendingWhite,
      w(13),
      Paint()..color = Colors.black.withValues(alpha: 0.26),
    );
    canvas.drawCircle(
      pendingWhite,
      w(13),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.78)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w(1.8),
    );
    final pendingSaved = Offset(x(267), y(large ? 133 : 64));
    canvas.drawCircle(pendingSaved, w(11), Paint()..color = const Color(0xFF0D9488));
    canvas.drawCircle(
      pendingSaved,
      w(11),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.75)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w(1.4),
    );
    final check = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = w(2.2)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(pendingSaved.dx - w(6), pendingSaved.dy + w(1))
        ..lineTo(pendingSaved.dx - w(2), pendingSaved.dy + w(5))
        ..lineTo(pendingSaved.dx + w(6), pendingSaved.dy - w(4)),
      check,
    );

    // The fixed centre aiming ring. It never moves.
    final cx = x(165);
    final cy = y(nominalH / 2);
    final r = w(large ? 35 : 31);
    final ringColor = aligned ? _green : _ringIdle;
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w(4.6),
    );
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = w(2.2),
    );
    canvas.drawCircle(
      Offset(cx, cy),
      r * 0.62,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.26)
        ..style = PaintingStyle.stroke,
    );
    final tick = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w(2)
      ..strokeCap = StrokeCap.round;
    for (final deg in const [0.0, 90.0, 180.0, 270.0]) {
      final a = deg * math.pi / 180;
      canvas.drawLine(
        Offset(cx + (r + w(3)) * math.cos(a), cy + (r + w(3)) * math.sin(a)),
        Offset(cx + (r + w(9)) * math.cos(a), cy + (r + w(9)) * math.sin(a)),
        tick,
      );
    }
    canvas.drawCircle(
      Offset(cx, cy),
      w(2.6),
      Paint()..color = Colors.black.withValues(alpha: 0.35),
    );
    canvas.drawCircle(Offset(cx, cy), w(1.8), Paint()..color = Colors.white);

    // Connector line between the ring and the not-yet-aligned target.
    final mr = w(large ? 21 : 20);
    final tx = x(targetFraction.dx * 330);
    final ty = y(targetFraction.dy * nominalH);
    if (!aligned) {
      canvas.drawLine(
        Offset(cx + r + w(4), cy),
        Offset(tx - mr - w(3), ty),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.3)
          ..strokeWidth = w(1.2),
      );
    }

    // The numbered target marker: a separate circle that moves.
    canvas.drawCircle(
      Offset(tx, ty),
      mr,
      Paint()..color = Colors.black.withValues(alpha: 0.42),
    );
    canvas.drawCircle(
      Offset(tx, ty),
      mr,
      Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = w(2.6),
    );
    final number = TextPainter(
      text: TextSpan(
        text: '$targetId',
        style: TextStyle(
          color: Colors.white,
          fontSize: w(large ? 18 : 17),
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    number.paint(canvas, Offset(tx - number.width / 2, ty - number.height / 2));

    if (aligned) {
      // The green hold arc: a partial sweep that finishes into a capture.
      final arcR = mr + w(9);
      final sweep = 1.3 * math.pi;
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: arcR),
        -math.pi / 2,
        sweep,
        false,
        Paint()
          ..color = _green
          ..style = PaintingStyle.stroke
          ..strokeWidth = w(4.5)
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(
        Offset(cx, cy),
        r + w(5),
        Paint()
          ..color = _green.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w(1.6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CameraHudPainter oldDelegate) =>
      oldDelegate.targetId != targetId ||
      oldDelegate.targetFraction != targetFraction ||
      oldDelegate.aligned != aligned ||
      oldDelegate.large != large;
}
