import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/data/equirectangular_stitcher.dart';
import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/application/sphere_capture_controller.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_projection.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/platform/rotation_sensor.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/platform/sphere_camera.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/presentation/screens/sphere_panorama_screen.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/presentation/widgets/sphere_overlay_painter.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/presentation/widgets/sphere_progress_map.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/presentation/widgets/sphere_ring_palette.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// SiteWise 360° Capture — the 38-target, sphere-follows-phone flow.
///
/// Start screen → live camera with 38 projected targets → automatic shutter
/// inside 5° → completion modal with the stitched 360° panorama.
///
/// The sphere's centre is the phone at all times: there is no AR session, no
/// plane detection and no world anchor, so walking cannot leave a target
/// behind and there is no position estimate to drift.
class SphereCaptureScreen extends StatefulWidget {
  const SphereCaptureScreen({
    super.key,
    this.camera,
    this.rotation,
    this.repository,
    this.stitcher,
    this.motionStream,
  });

  /// Injection points for tests and for callers that already hold a station.
  final SphereCamera? camera;
  final RotationSource? rotation;
  final CaptureRepository? repository;
  final PanoramaStitcher? stitcher;
  final Stream<Vec3>? motionStream;

  @override
  State<SphereCaptureScreen> createState() => _SphereCaptureScreenState();
}

class _SphereCaptureScreenState extends State<SphereCaptureScreen>
    with WidgetsBindingObserver {
  SphereCaptureController? _controller;
  SphereCamera? _camera;
  bool _starting = false;
  String? _startError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android revokes the camera when the app goes to the background. Without
    // forwarding this, the preview is black on return with no message.
    final controller = _controller;
    if (controller == null) return;
    controller.handleAppLifecycle(state).whenComplete(() {
      // A reopen creates a *new* CameraController, so the preview's
      // ValueListenableBuilder must be rebuilt against it; the old one is
      // disposed and would otherwise keep rendering its final frame.
      if (mounted) setState(() {});
    });
  }

  Future<void> _start() async {
    if (_starting || _controller != null) return;
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final camera = widget.camera ?? PluginSphereCamera();
      final rotation = widget.rotation ?? NativeRotationSource();
      final repository =
          widget.repository ?? await FileCaptureRepository.create();
      final controller = SphereCaptureController(
        rotation: rotation,
        camera: camera,
        repository: repository,
        stitcher: widget.stitcher ?? const EquirectangularStitcher(),
        stationId: 'sphere-${DateTime.now().millisecondsSinceEpoch}',
        motion:
            widget.motionStream ??
            accelerometerEventStream(
              samplingPeriod: SensorInterval.normalInterval,
            ).map((AccelerometerEvent e) => Vec3(e.x, e.y, e.z)),
      );
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _camera = camera;
        _starting = false;
      });
      await controller.start();
      // The first build after the setState above happens before the camera
      // controller exists, so `preview()` has nothing to listen to yet. One
      // rebuild after start attaches the live texture; without it the preview
      // stays on the black placeholder for the whole session.
      if (mounted) setState(() {});
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _startError = 'The capture could not start: $error';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final camera = _camera;
    if (controller == null || camera == null) {
      return _StartScreen(
        onStart: _starting ? null : _start,
        starting: _starting,
        error: _startError,
      );
    }
    return _LiveCapture(controller: controller, camera: camera);
  }
}

// ── start screen ───────────────────────────────────────────────────────────

class _StartScreen extends StatelessWidget {
  const _StartScreen({
    required this.onStart,
    required this.starting,
    this.error,
  });

  final VoidCallback? onStart;
  final bool starting;
  final String? error;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: CaptureColors.cameraChrome,
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.threesixty,
                  color: CaptureColors.accent,
                  size: 26,
                ),
                const SizedBox(width: 8),
                Text(
                  'SiteWise',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  '360° Capture',
                  style: TextStyle(
                    color: CaptureColors.mutedOnDark,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            const Spacer(flex: 2),
            const Center(child: _SphereDiagram(size: 220)),
            const SizedBox(height: 30),
            const Text(
              'AR 360° Capture ($kSphereTargetCount Targets)',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 25,
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'A sphere of $kSphereTargetCount targets follows the phone. Turn '
              'to bring each target into the centre reticle, hold steady, and '
              'the photograph is taken automatically.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: CaptureColors.mutedOnDark,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const Spacer(flex: 3),
            if (error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: CaptureColors.danger.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: CaptureColors.danger.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  error!,
                  style: const TextStyle(
                    color: CaptureColors.danger,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: onStart,
              style: FilledButton.styleFrom(
                backgroundColor: CaptureColors.accent,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: starting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text(
                      'Start Capture',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            const Text(
              '3DoF rotation only · no calibration · the sphere is locked to '
              'the phone',
              textAlign: TextAlign.center,
              style: TextStyle(color: CaptureColors.mutedOnDark, fontSize: 11),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The 38 dots, drawn orthographically so the layout is visible before Start.
class _SphereDiagram extends StatelessWidget {
  const _SphereDiagram({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _SphereDiagramPainter()),
  );
}

class _SphereDiagramPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = Colors.white.withValues(alpha: 0.28);
    canvas.drawCircle(center, radius, outline);

    // The three rings, foreshortened the way a sphere reads in a still image.
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = Colors.white.withValues(alpha: 0.16);
    final ringHeight = radius * 0.30;
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: radius * 2,
        height: ringHeight * 2,
      ),
      ringPaint,
    );
    for (final pitch in <double>[kSphereRingPitchDeg, -kSphereRingPitchDeg]) {
      final y = -math.sin(pitch * math.pi / 180) * radius;
      final rx = math.cos(pitch * math.pi / 180) * radius;
      canvas.drawOval(
        Rect.fromCenter(
          center: center + Offset(0, y),
          width: rx * 2,
          height: ringHeight * 2 * math.cos(pitch * math.pi / 180),
        ),
        ringPaint,
      );
    }

    for (final target in buildSphereTargets()) {
      final d = target.direction;
      final point = center + Offset(d.x * radius, -d.y * radius);
      final front = d.z <= 0;
      final isPole = target.isZenith || target.isNadir;
      canvas.drawCircle(
        point,
        isPole ? 4.2 : 3.2,
        Paint()
          ..color = sphereRingColor(target).withValues(alpha: front ? 1 : 0.35),
      );
    }

    // The reference diagram's phone at the centre: the sphere's origin is the
    // device, not a tripod, and drawing it is the clearest way to say so.
    final phoneWidth = radius * 0.18;
    final phoneHeight = radius * 0.34;
    final phone = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: phoneWidth, height: phoneHeight),
      Radius.circular(radius * 0.03),
    );
    canvas.drawRRect(phone, Paint()..color = CaptureColors.cameraChrome);
    canvas.drawRRect(
      phone,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = Colors.white.withValues(alpha: 0.9),
    );
    final screen = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center,
        width: phoneWidth * 0.76,
        height: phoneHeight * 0.82,
      ),
      Radius.circular(radius * 0.012),
    );
    canvas.drawRRect(screen, Paint()..color = const Color(0xFF2A3640));
  }

  @override
  bool shouldRepaint(_SphereDiagramPainter oldDelegate) => false;
}

// ── live capture ───────────────────────────────────────────────────────────

class _LiveCapture extends StatelessWidget {
  const _LiveCapture({required this.controller, required this.camera});

  final SphereCaptureController controller;
  final SphereCamera camera;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: camera.preview()),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                RepaintBoundary(
                  child: CustomPaint(
                    painter: SphereOverlayPainter(
                      controller: controller,
                      projection: SphereProjection(
                        width: constraints.maxWidth,
                        height: constraints.maxHeight,
                      ),
                    ),
                  ),
                ),
          ),
        ),
        SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                top: 8,
                left: 12,
                right: 12,
                child: _TopBar(controller: controller),
              ),
              Positioned(
                top: 92,
                left: 24,
                right: 24,
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (BuildContext context, Widget? child) =>
                      _CapturedBanner(visible: controller.banner != null),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (BuildContext context, Widget? child) =>
                      _BottomPanel(controller: controller),
                ),
              ),
            ],
          ),
        ),
        AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, Widget? child) {
            if (controller.phase == SphereCapturePhase.complete) {
              return _CompletionOverlay(controller: controller);
            }
            if (controller.phase == SphereCapturePhase.failed) {
              return _FailureOverlay(controller: controller);
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller});

  final SphereCaptureController controller;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _GlassButton(
        icon: Icons.close,
        onTap: () => Navigator.of(context).maybePop(),
      ),
      const SizedBox(width: 8),
      AnimatedBuilder(
        animation: controller,
        builder: (BuildContext context, Widget? child) =>
            _MotionChip(moving: controller.moving),
      ),
      const Spacer(),
      SphereProgressMap(controller: controller),
    ],
  );
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.45),
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(9),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    ),
  );
}

class _CapturedBanner extends StatelessWidget {
  const _CapturedBanner({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 180),
    child: visible
        ? Container(
            key: const ValueKey<String>('captured'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: CaptureColors.ok.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check, color: Colors.white, size: 16),
                SizedBox(width: 6),
                Text(
                  'Captured!',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          )
        : const SizedBox.shrink(),
  );
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({required this.controller});

  final SphereCaptureController controller;

  @override
  Widget build(BuildContext context) {
    final aligned = controller.activeErrorDeg <= controller.toleranceDeg;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: CaptureColors.hairlineOnDark),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            controller.guidance,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: aligned ? CaptureColors.ok : Colors.white,
              fontSize: 12.5,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            controller.progressLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: controller.capturedCount / kSphereTargetCount,
              minHeight: 4,
              backgroundColor: Colors.white.withValues(alpha: 0.14),
              valueColor: const AlwaysStoppedAnimation<Color>(CaptureColors.ok),
            ),
          ),
        ],
      ),
    );
  }
}

class _MotionChip extends StatelessWidget {
  const _MotionChip({required this.moving});

  final bool moving;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: CaptureColors.hairlineFaint),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          moving ? Icons.directions_walk : Icons.my_location,
          color: CaptureColors.linkOnDark,
          size: 14,
        ),
        const SizedBox(width: 5),
        Text(
          moving ? 'Moving' : 'Sphere synced',
          style: const TextStyle(
            color: CaptureColors.linkOnDark,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _CompletionOverlay extends StatelessWidget {
  const _CompletionOverlay({required this.controller});

  final SphereCaptureController controller;

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.black.withValues(alpha: 0.72),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
          decoration: BoxDecoration(
            color: CaptureColors.sheet,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: CaptureColors.hairlineOnDark),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: CaptureColors.ok, size: 54),
              const SizedBox(height: 12),
              const Text(
                'Capture Complete!',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${controller.capturedCount} / $kSphereTargetCount Targets',
                style: const TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
              _PanoramaStatus(controller: controller),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: controller.panoramaPath == null
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SpherePanoramaScreen(
                            panoramaPath: controller.panoramaPath!,
                          ),
                        ),
                      ),
                icon: const Icon(Icons.threesixty, size: 18),
                label: const Text('View 360° Panorama'),
                style: FilledButton.styleFrom(
                  backgroundColor: CaptureColors.accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(46),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: controller.exporting
                    ? null
                    : () => _saveAndFinish(context),
                icon: controller.exporting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_alt, size: 18),
                label: const Text('Save & Finish'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(46),
                  side: const BorderSide(color: CaptureColors.hairlineOnDark),
                ),
              ),
              if (controller.exportPath != null) ...[
                const SizedBox(height: 10),
                Text(
                  'Exported to ${controller.exportPath}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: CaptureColors.mutedOnDark,
                    fontSize: 10.5,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _saveAndFinish(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final path = await controller.saveAndFinish();
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          path == null
              ? controller.message ?? 'The export failed.'
              : 'Exported $kSphereTargetCount photographs and the panorama to $path',
        ),
      ),
    );
    if (path != null) navigator.pop();
  }
}

class _PanoramaStatus extends StatelessWidget {
  const _PanoramaStatus({required this.controller});

  final SphereCaptureController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.stitching) {
      return Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              controller.stitchStage ?? 'Stitching the panorama…',
              style: const TextStyle(
                color: CaptureColors.mutedOnDark,
                fontSize: 12,
              ),
            ),
          ),
        ],
      );
    }
    if (controller.stitchError != null) {
      return Column(
        children: [
          Text(
            controller.stitchError!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: CaptureColors.warn,
              fontSize: 11.5,
              height: 1.4,
            ),
          ),
          TextButton(
            onPressed: controller.retryStitching,
            child: const Text('Retry stitching'),
          ),
        ],
      );
    }
    if (controller.panoramaPath != null) {
      return Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check, color: CaptureColors.ok, size: 15),
              SizedBox(width: 6),
              Text(
                '360° panorama ready',
                style: TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          if (controller.galleryPath != null) ...[
            const SizedBox(height: 4),
            Text(
              'Saved to ${controller.galleryFolder}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: CaptureColors.linkOnDark,
                fontSize: 10.5,
                height: 1.4,
              ),
            ),
          ],
        ],
      );
    }
    return const Text(
      'The panorama will be generated from the $kSphereTargetCount saved '
      'photographs.',
      textAlign: TextAlign.center,
      style: TextStyle(color: CaptureColors.mutedOnDark, fontSize: 11.5),
    );
  }
}

class _FailureOverlay extends StatelessWidget {
  const _FailureOverlay({required this.controller});

  final SphereCaptureController controller;

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.black.withValues(alpha: 0.82),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              color: CaptureColors.danger,
              size: 42,
            ),
            const SizedBox(height: 14),
            Text(
              controller.message ?? 'The capture stopped.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: controller.start,
              style: FilledButton.styleFrom(
                backgroundColor: CaptureColors.accent,
              ),
              child: const Text('Try again'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text(
                'Back',
                style: TextStyle(color: CaptureColors.mutedOnDark),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
