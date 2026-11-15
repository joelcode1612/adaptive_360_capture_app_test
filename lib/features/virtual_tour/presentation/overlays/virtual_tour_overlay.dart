import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_renderer.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/overlays/glb_target_overlay.dart';

/// The projected markers plus the aiming reticle, over the AR camera feed.
///
/// When the GLB assets load, [triangles] contains all 30 world-locked markers
/// that are in view and the fixed bezel HUD, and this widget is a thin
/// [CustomPaint] over them. When they do not load it degrades to a drawn
/// reticle rather than an empty screen, and says why in a banner — the same
/// rule the single-target overlay follows.
class VirtualTourOverlay extends StatelessWidget {
  const VirtualTourOverlay({
    super.key,
    required this.triangles,
    required this.revision,
    required this.modelsReady,
    required this.hudColor,
    this.failureReason,
    this.holdProgress = 0,
    this.topInset = 64,
  });

  final List<GlbScreenTriangle> triangles;

  /// Changes whenever [triangles] is a new frame; [GlbTargetOverlayPainter]
  /// repaints only when this changes.
  final int revision;

  /// False while the assets are loading and after a load failure.
  final bool modelsReady;

  /// Drives the fallback reticle's colour and the hold arc.
  final Color hudColor;
  final double holdProgress;
  final String? failureReason;

  /// The failure banner starts below the screen's top bar.
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final failed = failureReason != null;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (modelsReady && triangles.isNotEmpty)
            CustomPaint(
              painter: GlbTargetOverlayPainter(
                triangles: triangles,
                revision: revision,
              ),
            ),
          if (!modelsReady)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox.square(
                    dimension: CaptureColors.reticleSize,
                    child: CustomPaint(
                      painter: _FallbackReticlePainter(
                        color: hudColor,
                        progress: holdProgress,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    failed ? 'Markers unavailable' : 'Loading markers…',
                    style: const TextStyle(
                      color: CaptureColors.mutedOnDark,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          if (failed)
            Positioned(
              left: 12,
              right: 12,
              top: topInset,
              child: GlbRenderFailureBanner(reason: failureReason!),
            ),
        ],
      ),
    );
  }
}

/// The screen-centred marker used when the GLB assets cannot be drawn.
class _FallbackReticlePainter extends CustomPainter {
  const _FallbackReticlePainter({required this.color, required this.progress});

  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;
    // A dark outline under the ring: this fallback is drawn over the live feed,
    // and a 2.4 dp pale circle disappeared against a bright wall.
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7.5
        ..color = Colors.black.withValues(alpha: 0.5),
    );
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = color.withValues(alpha: 0.92);
    canvas.drawCircle(centre, radius, ring);

    final tick = Paint()
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.75);
    for (var i = 0; i < 4; i++) {
      final angle = i * math.pi / 2;
      final inner = radius - 9;
      canvas.drawLine(
        centre + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        centre + Offset(math.cos(angle) * radius, math.sin(angle) * radius),
        tick,
      );
    }
    canvas.drawCircle(
      centre,
      3.4,
      Paint()..color = color.withValues(alpha: 0.95),
    );

    final arc = progress.clamp(0.0, 1.0);
    if (arc > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: radius - 6),
        -math.pi / 2,
        2 * math.pi * arc,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round
          ..color = CaptureColors.ok,
      );
    }
  }

  @override
  bool shouldRepaint(_FallbackReticlePainter old) =>
      old.color != color || old.progress != progress;
}
