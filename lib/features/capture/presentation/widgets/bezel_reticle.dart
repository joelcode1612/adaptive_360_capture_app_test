import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// The annulus the shipped bezel traces, in model metres.
///
/// Measured from `white_frame_bezel.glb` rather than hard-coded, so a changed
/// asset is reflected here instead of being silently overridden. The values are
/// pinned by a test: inner 0.270, outer 0.350.
({double inner, double outer}) bezelAnnulus(GlbModel bezel) {
  var inner = double.infinity;
  var outer = 0.0;
  for (final drawable in bezel.drawables) {
    for (final p in drawable.positions) {
      final r = math.sqrt(p.x * p.x + p.y * p.y);
      if (r < inner) inner = r;
      if (r > outer) outer = r;
    }
  }
  if (!inner.isFinite || outer <= 0) return (inner: 0.27, outer: 0.35);
  return (inner: inner, outer: outer);
}

/// Builds the ring's **front face** as a path, in a [size] × [size] box.
///
/// The triangles come from the parsed GLB, so the shape on screen is the asset's
/// own annulus — 64 facets and all — rather than a circle drawn from its radius.
/// Only the top face is taken: the ring is a rectangular-section torus, and its
/// walls and underside would project on top of the face and thicken the outline.
///
/// Built once per (model, size) and cached, because a repaint should cost one
/// `drawPath`, not 512 triangle projections.
Path buildBezelRingPath(GlbModel bezel, {required double size}) {
  final cached = _pathCache[bezel];
  if (cached != null && cached.size == size) return cached.path;

  final annulus = bezelAnnulus(bezel);
  final scale = (size / 2) / annulus.outer;
  final centre = Offset(size / 2, size / 2);

  var maxZ = 0.0;
  for (final drawable in bezel.drawables) {
    for (final p in drawable.positions) {
      if (p.z > maxZ) maxZ = p.z;
    }
  }
  final threshold = maxZ * 0.9;

  final path = Path();
  for (final drawable in bezel.drawables) {
    final positions = drawable.positions;
    for (var i = 0; i + 2 < positions.length; i += 3) {
      final a = drawable.transform.apply(positions[i]);
      final b = drawable.transform.apply(positions[i + 1]);
      final c = drawable.transform.apply(positions[i + 2]);
      if ((a.z + b.z + c.z) / 3 < threshold) continue;
      final pa = centre + Offset(a.x * scale, -a.y * scale);
      final pb = centre + Offset(b.x * scale, -b.y * scale);
      final pc = centre + Offset(c.x * scale, -c.y * scale);
      path
        ..moveTo(pa.dx, pa.dy)
        ..lineTo(pb.dx, pb.dy)
        ..lineTo(pc.dx, pc.dy)
        ..close();
    }
  }

  _pathCache[bezel] = (size: size, path: path);
  return path;
}

/// One cached outline per model, rebuilt only when the requested size changes.
final Map<GlbModel, ({double size, Path path})> _pathCache =
    <GlbModel, ({double size, Path path})>{};

/// The guidance reticle, drawn as the shipped bezel ring.
///
/// ## What it replaces
///
/// A plain stroked circle. The circle carried no information: it was the same
/// grey whatever the state, and its only job was to mark the aim point. The ring
/// is the same shape the target itself wears, so the thing the user aims with is
/// the thing that will appear on the wall — and it can carry the progress, which
/// a circle could not.
///
/// ## The progress
///
/// The ring fills **clockwise from twelve o'clock** with [progress], in green,
/// over a white base. When [completed] the whole ring is green. Nothing here
/// reports "aligned": the base colour is driven by the caller's
/// `withinTolerance`, which comes from the unsmoothed pose, so a ring that looks
/// settled cannot appear while the phone is still moving.
class BezelReticle extends StatelessWidget {
  const BezelReticle({
    super.key,
    required this.size,
    required this.progress,
    required this.withinTolerance,
    required this.completed,
    this.holdComplete = false,
    this.captureBlocked = false,
    this.bezel,
  });

  /// Diameter in logical pixels.
  final double size;

  /// 0…1, the stability window's fill. Ignored unless [withinTolerance].
  final double progress;

  /// Whether the *raw* alignment is inside tolerance.
  final bool withinTolerance;

  /// Whether the target has been captured and recorded.
  final bool completed;

  /// Whether a genuine completed hold has already armed the current shutter.
  ///
  /// While the real image is being saved, retaining the full green ring makes
  /// the successful 600 ms hold visible without adding any delay or timer.
  final bool holdComplete;

  /// Whether another capture requirement blocks the shutter despite alignment.
  ///
  /// The station-distance gate uses this when the camera has left the
  /// calibrated point. Amber is deliberately stronger than a white aligned
  /// ring: an aligned reticle must not look ready while the shutter is locked.
  final bool captureBlocked;

  /// The parsed bezel, or `null` before the asset has loaded. When null a plain
  /// circle of the same diameter is drawn, so the reticle never blinks out.
  final GlbModel? bezel;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _BezelReticlePainter(
        progress: progress,
        withinTolerance: withinTolerance,
        completed: completed,
        holdComplete: holdComplete,
        captureBlocked: captureBlocked,
        bezel: bezel,
      ),
    ),
  );
}

class _BezelReticlePainter extends CustomPainter {
  _BezelReticlePainter({
    required this.progress,
    required this.withinTolerance,
    required this.completed,
    required this.holdComplete,
    required this.captureBlocked,
    required this.bezel,
  });

  final double progress;
  final bool withinTolerance;
  final bool completed;
  final bool holdComplete;
  final bool captureBlocked;
  final GlbModel? bezel;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final diameter = size.shortestSide;
    final model = bezel;

    // Base ring. The state table the brief pins is green the moment alignment
    // is real, amber when another hard capture requirement blocks the shutter,
    // and neutral while the user is still turning. Green-on-alignment is what
    // makes "correctly aligned" a confirmation rather than a same-coloured
    // ring with a different fill; the half-opacity base keeps the hold sweep
    // legible on top of it.
    final baseColor = completed || holdComplete
        ? CaptureColors.ok
        : (captureBlocked
              ? CaptureColors.warn
              : (withinTolerance
                    ? CaptureColors.ok.withValues(alpha: 0.55)
                    : CaptureColors.reticleIdle));

    final base = Paint()..color = baseColor;
    // Two hairlines, not one: a dark outline lifts the ring off a white wall
    // and a faint light halo lifts it off a dark corner. Together they are the
    // "sufficient contrast for bright and dark environments" the brief asks
    // for, without a glow or a shadow that would soften the aim edge.
    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.62)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6;
    final halo = Paint()
      ..color = Colors.white.withValues(alpha: 0.20)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.2;

    final Path ring;
    final Paint progressPaint = Paint()..color = CaptureColors.ok;
    if (model == null) {
      // The asset has not loaded yet. Same diameter, so nothing pops. Keep this
      // fallback as a stroked circle, but route it through the same progress
      // painter as the GLB path so readiness never depends on asset loading.
      final radius = diameter / 2 - 2;
      ring = Path()..addOval(Rect.fromCircle(center: centre, radius: radius));
      progressPaint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5;
      canvas.drawPath(
        ring,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.62)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8,
      );
      canvas.drawPath(
        ring,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.22)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7,
      );
      canvas.drawPath(
        ring,
        Paint()
          ..color = baseColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5,
      );
    } else {
      ring = buildBezelRingPath(model, size: diameter).shift(
        Offset((size.width - diameter) / 2, (size.height - diameter) / 2),
      );
      // A dark hairline behind the ring keeps a white marker legible over a
      // white wall, which is exactly the surface this app is pointed at.
      canvas.drawPath(ring, halo);
      canvas.drawPath(ring, shadow);
      canvas.drawPath(ring, base);
    }

    // The progress sweep, clipped to the ring so it fills the band rather than
    // sitting beside it. This is shared by the GLB and fallback paths.
    final p = progress.clamp(0.0, 1.0);
    if (completed ||
        holdComplete ||
        (!captureBlocked && withinTolerance && p >= 1)) {
      canvas.drawPath(ring, progressPaint);
    } else if (!captureBlocked && withinTolerance && p > 0) {
      canvas.save();
      canvas.clipPath(
        Path()
          ..moveTo(centre.dx, centre.dy)
          ..arcTo(
            Rect.fromCircle(center: centre, radius: diameter),
            -math.pi / 2,
            p * 2 * math.pi,
            false,
          )
          ..close(),
      );
      canvas.drawPath(ring, progressPaint);
      canvas.restore();
    }

    // No crosshair. The ring's inner edge is the aim reference: the centre of the
    // band is exactly where the target will sit, and a second mark inside it only
    // competed with the ring for attention.
  }

  @override
  bool shouldRepaint(_BezelReticlePainter old) =>
      old.progress != progress ||
      old.withinTolerance != withinTolerance ||
      old.completed != completed ||
      old.holdComplete != holdComplete ||
      old.captureBlocked != captureBlocked ||
      !identical(old.bezel, bezel);
}
