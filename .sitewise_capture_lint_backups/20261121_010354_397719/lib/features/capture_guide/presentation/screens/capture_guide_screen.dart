import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/capture_guide/domain/capture_guide_content.dart';
import 'package:adaptive_360_capture_app/features/capture_guide/presentation/widgets/sphere_plan_painter.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/presentation/screens/sphere_capture_screen.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// Four-screen onboarding for the existing 38-target 3DoF sphere capture.
///
/// Pages 1–4 are documentation only: the camera/sensors are NOT started here.
/// Page 3 deliberately renders a clean, painted sample room with the real
/// capture screen's visual vocabulary; it is NOT a screenshot or camera feed.
/// Page 4's Start Capture enters the existing capture engine immediately.
/// When opened as help during a capture, the same final action returns to it.
class CaptureGuideScreen extends StatefulWidget {
  const CaptureGuideScreen({super.key, this.showStartAction = true});

  final bool showStartAction;

  @override
  State<CaptureGuideScreen> createState() => _CaptureGuideScreenState();
}

class _CaptureGuideScreenState extends State<CaptureGuideScreen> {
  static const int _steps = 4;
  final PageController _controller = PageController();
  int _step = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int page) {
    _controller.animateToPage(
      page.clamp(0, _steps - 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _begin() {
    if (!widget.showStartAction) {
      Navigator.of(context).maybePop();
      return;
    }
    // Replace the guide and skip the old second Start button. The capture
    // engine, frame persistence, resume and stitch paths remain unchanged.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => const SphereCaptureScreen(autoStart: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = _step == 2;
    return Scaffold(
      backgroundColor: dark ? Colors.black : SiteWiseColors.surface,
      body: SafeArea(
        child: Column(
          children: [
            _GuideHeader(
              dark: dark,
              onBack: () {
                if (_step > 0) {
                  _go(_step - 1);
                } else {
                  Navigator.of(context).maybePop();
                }
              },
            ),
            _GuideProgress(step: _step, dark: dark),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (value) => setState(() => _step = value),
                children: const [
                  _GetReady(),
                  _CaptureDirections(),
                  _TargetPreview(),
                  _ReadyToCapture(),
                ],
              ),
            ),
            _GuideFooter(
              dark: dark,
              isFinal: _step == _steps - 1,
              label: _step == _steps - 1
                  ? (widget.showStartAction ? 'Start Capture' : 'Return to capture')
                  : 'Next',
              onPressed: _step == _steps - 1 ? _begin : () => _go(_step + 1),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideHeader extends StatelessWidget {
  const _GuideHeader({required this.dark, required this.onBack});
  final bool dark;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 16, 4),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: IconButton(
                tooltip: 'Go back',
                onPressed: onBack,
                icon: Icon(Icons.arrow_back_ios_new,
                    color: dark ? Colors.white : SiteWiseColors.ink),
              ),
            ),
            Expanded(
              child: Text(
                'SiteWise 360° Capture',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: dark ? Colors.white : SiteWiseColors.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 48),
          ],
        ),
      );
}

class _GuideProgress extends StatelessWidget {
  const _GuideProgress({required this.step, required this.dark});
  final int step;
  final bool dark;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF273345) : SiteWiseColors.softBlue,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Text(
                '${step + 1} of 4',
                style: TextStyle(
                  color: dark ? Colors.white : SiteWiseColors.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 18),
            for (var index = 0; index < 4; index++) ...[
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: index <= step
                      ? (dark ? const Color(0xFF60A5FA) : SiteWiseColors.primary)
                      : (dark ? const Color(0xFF566477) : const Color(0xFFD6E4F8)),
                ),
              ),
            ],
          ],
        ),
      );
}

class _GuideFooter extends StatelessWidget {
  const _GuideFooter({
    required this.dark,
    required this.isFinal,
    required this.label,
    required this.onPressed,
  });
  final bool dark;
  final bool isFinal;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        decoration: BoxDecoration(
          color: dark ? Colors.black : SiteWiseColors.surface,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton.icon(
                key: const Key('guide_next'),
                onPressed: onPressed,
                icon: Icon(isFinal ? Icons.photo_camera_outlined : Icons.arrow_forward,
                    size: 20),
                label: Text(
                  label,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: SiteWiseColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            if (isFinal) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.info_outline, color: SiteWiseColors.primary, size: 17),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'You can pause and resume later.',
                      style: TextStyle(color: SiteWiseColors.muted, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
}

class _GuideText extends StatelessWidget {
  const _GuideText({required this.title, required this.subtitle, this.dark = false});
  final String title;
  final String subtitle;
  final bool dark;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: dark ? Colors.white : SiteWiseColors.ink,
              fontSize: 25,
              fontWeight: FontWeight.w800,
              height: 1.13,
              letterSpacing: -0.7,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            subtitle,
            style: TextStyle(
              color: dark ? const Color(0xFFCAD4E0) : SiteWiseColors.slate,
              fontSize: 16,
              height: 1.43,
            ),
          ),
        ],
      );
}

class _GuideCheck extends StatelessWidget {
  const _GuideCheck(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.check_circle_outline,
                size: 23, color: SiteWiseColors.primary),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                    fontSize: 15, height: 1.4, color: SiteWiseColors.slate),
              ),
            ),
          ],
        ),
      );
}

class _GetReady extends StatelessWidget {
  const _GetReady();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _GuideText(
                title: 'Get ready',
                subtitle: 'Prepare your space and position before capturing.',
              ),
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  height: constraints.maxHeight < 480 ? 170 : 235,
                  color: SiteWiseColors.softBlue,
                  child: Image.asset(
                    'assets/images/capture_guide/guide_start.webp',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(Icons.threesixty,
                          size: 96, color: SiteWiseColors.primary),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              const _GuideCheck('Stand near the centre of the room.'),
              const _GuideCheck('Hold your phone upright (portrait).'),
              const _GuideCheck('Keep the area well lit, but avoid direct glare.'),
              const _GuideCheck('Keep fans still and turn in place, not walk.'),
            ],
          ),
        ),
      );
}

class _CaptureDirections extends StatelessWidget {
  const _CaptureDirections();

  @override
  Widget build(BuildContext context) {
    final plan = CaptureGuidePlan.instance;
    final pitch = plan.ringPitchDeg.round();
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _GuideText(
              title: 'Understand the 38 directions',
              subtitle: 'Capture the room from 38 guided angles in a fixed sequence.',
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: CustomPaint(
                      painter: const SpherePlanPainter(style: SphereMapStyle.plan),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      _RingCount('Upper ring', plan.upperCount, '+$pitch°'),
                      const SizedBox(height: 9),
                      _RingCount('Middle ring', plan.middleCount, '0°', active: true),
                      const SizedBox(height: 9),
                      _RingCount('Lower ring', plan.lowerCount, '−$pitch°'),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: const [
                Expanded(child: _PoleCount(icon: Icons.arrow_upward, name: 'Ceiling', count: '1')),
                SizedBox(width: 12),
                Expanded(child: _PoleCount(icon: Icons.arrow_downward, name: 'Floor', count: '1')),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: SiteWiseColors.softBlue,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: SiteWiseColors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${plan.total} photos: ${plan.middleCount} middle + '
                      '${plan.upperCount} upper + ${plan.lowerCount} lower + '
                      '1 ceiling + 1 floor. Start with the middle ring.',
                      style: const TextStyle(
                        color: SiteWiseColors.slate,
                        fontSize: 14,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingCount extends StatelessWidget {
  const _RingCount(this.name, this.count, this.angle, {this.active = false});
  final String name;
  final int count;
  final String angle;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        decoration: BoxDecoration(
          color: active ? SiteWiseColors.primary : SiteWiseColors.softBlue,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(name,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: active ? Colors.white : SiteWiseColors.slate)),
            Text('($count) · $angle',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    color: active ? Colors.white : SiteWiseColors.slate)),
          ],
        ),
      );
}

class _PoleCount extends StatelessWidget {
  const _PoleCount({required this.icon, required this.name, required this.count});
  final IconData icon;
  final String name;
  final String count;

  @override
  Widget build(BuildContext context) => Container(
        height: 62,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: SiteWiseColors.softBlue,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: SiteWiseColors.primary, size: 24),
            const SizedBox(width: 8),
            Text('$name\n($count)',
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  color: SiteWiseColors.slate,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
      );
}

/// The same visual information as the real camera, but a clean illustrated room
/// (the guide must not open a real camera or claim to show actual progress).
class _TargetPreview extends StatelessWidget {
  const _TargetPreview();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      color: const Color(0xFF232B37),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.my_location, size: 15, color: Color(0xFF93C5FD)),
                        SizedBox(width: 7),
                        Text('Sphere synced',
                            style: TextStyle(color: Color(0xFF93C5FD),
                                fontSize: 13, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 82,
                    height: 76,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFF4B5563)),
                        borderRadius: BorderRadius.circular(14),
                        color: const Color(0xFF111827)),
                    child: const CustomPaint(painter: _MiniSpherePainter()),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: constraints.maxHeight < 520 ? 1.0 : 0.90,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const CustomPaint(painter: _SampleRoomPainter()),
                      const Center(child: _AimReticle()),
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 14,
                        child: Center(
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: const BoxDecoration(
                              color: Color(0xFF10B981), shape: BoxShape.circle),
                            child: const Icon(Icons.check, color: Colors.white, size: 25),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        top: 85,
                        child: Row(
                          children: const [
                            _AngleBadge(),
                            Icon(Icons.navigation,
                                color: Color(0xFF10B981), size: 27),
                          ],
                        ),
                      ),
                      const Positioned(
                        left: 0,
                        right: 0,
                        bottom: 28,
                        child: Center(
                          child: _SmallReticle(),
                        ),
                      ),
                      const Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Center(
                          child: Text('Camera guidance example',
                              style: TextStyle(color: Color(0xFF374151),
                                  fontSize: 12, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF3E4856)),
                  color: const Color(0xFF090B0E),
                ),
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Turn right 31° to target 2.',
                        style: TextStyle(color: Colors.white, fontSize: 14)),
                    const SizedBox(height: 7),
                    const Text('Target 2 / 38 — Middle ring (30°)',
                        style: TextStyle(color: Colors.white,
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: const LinearProgressIndicator(
                        value: 0.08,
                        minHeight: 5,
                        color: Color(0xFF10B981),
                        backgroundColor: Color(0xFF3D3D3D),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 9),
              const Text(
                'Move the numbered target into the centre circle and hold '
                'steady. The photo is taken automatically.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFC9D4E0),
                    fontSize: 13, height: 1.4),
              ),
            ],
          ),
        ),
      );
}

class _AngleBadge extends StatelessWidget {
  const _AngleBadge();
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(right: 5),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xAA1F2937),
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Text('32°',
            style: TextStyle(color: Colors.white,
                fontWeight: FontWeight.w700, fontSize: 15)),
      );
}

class _AimReticle extends StatelessWidget {
  const _AimReticle();
  @override
  Widget build(BuildContext context) => Container(
        width: 116,
        height: 116,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white, width: 3),
          shape: BoxShape.circle,
        ),
        child: const Center(
          child: SizedBox(
            width: 7,
            height: 7,
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.white,
                  shape: BoxShape.circle),
            ),
          ),
        ),
      );
}

class _SmallReticle extends StatelessWidget {
  const _SmallReticle();
  @override
  Widget build(BuildContext context) => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
            border: Border.all(color: Colors.white, width: 2),
            shape: BoxShape.circle),
      );
}

class _MiniSpherePainter extends CustomPainter {
  const _MiniSpherePainter();
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 - 5);
    final radius = math.min(size.width, size.height) * 0.36;
    for (var ring = 0; ring < 3; ring++) {
      final pitch = (ring - 1) * 0.52;
      for (var point = 0; point < 12; point++) {
        final angle = point * math.pi / 6;
        final offset = Offset(
          center.dx + math.cos(angle) * radius * math.cos(pitch),
          center.dy + math.sin(pitch) * radius + math.sin(angle) * radius * 0.20,
        );
        canvas.drawCircle(offset, 2.5, Paint()
          ..color = ring == 1
              ? const Color(0xFF60A5FA)
              : (ring == 0 ? const Color(0xFFFB923C) : const Color(0xFF34D399))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
      }
    }
    final marker = Offset(center.dx + radius * 0.75, center.dy - 4);
    canvas.drawCircle(marker, 4.2, Paint()..color = Colors.amber
      ..style = PaintingStyle.stroke..strokeWidth = 2);
    final text = TextPainter(
      text: const TextSpan(text: '2 / 38',
        style: TextStyle(fontSize: 9, color: Colors.white,
            fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset((size.width - text.width) / 2, size.height - 10));
  }
  @override
  bool shouldRepaint(covariant _MiniSpherePainter oldDelegate) => false;
}

/// Clean empty commercial room as seen in the user's UI reference. Deliberately
/// not an embedded real-room photograph; the guide remains device-independent.
class _SampleRoomPainter extends CustomPainter {
  const _SampleRoomPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final wallY = h * 0.70;
    final linePaint = Paint()..color = const Color(0xFFB7B8BC)..strokeWidth = 1.2;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFE8E7E7));
    final ceiling = Path()
      ..moveTo(0, 0)..lineTo(w, 0)
      ..lineTo(w * .76, h * .24)..lineTo(w * .24, h * .24)..close();
    canvas.drawPath(ceiling, Paint()..color = const Color(0xFFF4F3F1));
    final backWall = Rect.fromLTWH(w * .24, h * .24, w * .52, wallY - h * .24);
    canvas.drawRect(backWall, Paint()..color = const Color(0xFFE5E3E0));
    final leftWall = Path()
      ..moveTo(0, 0)..lineTo(w * .24, h * .24)
      ..lineTo(w * .24, wallY)..lineTo(0, h)..close();
    canvas.drawPath(leftWall, Paint()..color = const Color(0xFFF3F3F2));
    final rightWall = Path()
      ..moveTo(w, 0)..lineTo(w * .76, h * .24)
      ..lineTo(w * .76, wallY)..lineTo(w, h)..close();
    canvas.drawPath(rightWall, Paint()..color = const Color(0xFFEFECE9));
    final floor = Path()
      ..moveTo(0, h)..lineTo(w * .24, wallY)
      ..lineTo(w * .76, wallY)..lineTo(w, h)..close();
    canvas.drawPath(floor, Paint()..color = const Color(0xFFD3D2CF));
    for (var i = 1; i < 5; i++) {
      final t = i / 5;
      final left = Offset(w * .24 * (1 - t), wallY + (h - wallY) * t);
      final right = Offset(w * (.76 + .24 * t), wallY + (h - wallY) * t);
      canvas.drawLine(left, right, linePaint);
    }
    for (var i = 0; i <= 6; i++) {
      canvas.drawLine(Offset(w * .24 + i * w * .52 / 6, wallY),
          Offset(i * w / 6, h), linePaint);
    }
    final window = Path()
      ..moveTo(0, h * .25)..lineTo(w * .20, h * .33)
      ..lineTo(w * .20, h * .67)..lineTo(0, h * .78)..close();
    canvas.drawPath(window, Paint()..color = const Color(0xFFB7D7E5));
    canvas.drawLine(Offset(w*.10,h*.29), Offset(w*.10,h*.73), linePaint);
    canvas.drawLine(Offset(0,h*.52), Offset(w*.20,h*.51), linePaint);
    final door = Rect.fromLTWH(w * .79, h*.31, w*.16, h*.44);
    canvas.drawRect(door, Paint()..color = const Color(0xFFB18B60));
    canvas.drawRect(door.deflate(4), Paint()..color = const Color(0xFFD3AE7D));
    canvas.drawCircle(Offset(w*.91,h*.55), 2.5,
        Paint()..color = const Color(0xFF69513C));
    for (var i = 0; i < 3; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w*(.36+i*.13),h*.15,w*.05,h*.012),
          const Radius.circular(3)),
        Paint()..color = Colors.white);
    }
  }
  @override
  bool shouldRepaint(covariant _SampleRoomPainter oldDelegate) => false;
}

class _ReadyToCapture extends StatelessWidget {
  const _ReadyToCapture();
  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _GuideText(
                title: 'Ready to capture?',
                subtitle: 'You’re all set. Start the 38-photo capture now.',
              ),
              const SizedBox(height: 20),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: constraints.maxHeight < 480 ? 150 : 190,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const CustomPaint(painter: _SampleRoomPainter()),
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Text('360°',
                                style: TextStyle(color: Colors.white,
                                    shadows: [Shadow(color: Colors.black54, blurRadius: 5)],
                                    fontSize: 35, fontWeight: FontWeight.w800)),
                            Icon(Icons.threesixty, color: Colors.white, size: 58,
                                shadows: [Shadow(color: Colors.black45, blurRadius: 5)]),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              const _FeatureLine(Icons.view_in_ar_outlined,
                  'Create a 360° virtual tour'),
              const SizedBox(height: 16),
              const _FeatureLine(Icons.bar_chart_outlined,
                  'Give a realistic view of the space'),
              const SizedBox(height: 16),
              const _FeatureLine(Icons.storefront_outlined,
                  'Support better property decisions'),
            ],
          ),
        ),
      );
}

class _FeatureLine extends StatelessWidget {
  const _FeatureLine(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 39,
            height: 39,
            decoration: BoxDecoration(
              color: SiteWiseColors.softBlue,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: SiteWiseColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: SiteWiseColors.slate)),
          ),
        ],
      );
}
