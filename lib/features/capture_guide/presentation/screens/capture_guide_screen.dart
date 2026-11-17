import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/capture_guide/domain/capture_guide_content.dart';
import 'package:adaptive_360_capture_app/features/capture_guide/presentation/widgets/camera_hud_painter.dart';
import 'package:adaptive_360_capture_app/features/capture_guide/presentation/widgets/sphere_plan_painter.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/presentation/screens/sphere_capture_screen.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// The native pre-capture guide, converted from
/// `SiteWise_360_Capture_Guidelines.html` (five sections, six posture modes,
/// a 12-direction ring selector).
///
/// Shown by the launcher before a new capture session starts. It opens the
/// real [SphereCaptureScreen] only from its final **Start Capture** action;
/// nothing in this screen touches the camera, the controller or captured
/// photographs, so its state (selected tutorial mode and direction) is fully
/// separate from capture state. The same screen doubles as in-session help:
/// with [showStartAction] false the final action returns to the live session
/// instead of starting a second one.
class CaptureGuideScreen extends StatefulWidget {
  const CaptureGuideScreen({super.key, this.showStartAction = true});

  /// True when opened before a new capture: the final section's primary
  /// action starts the capture. False when opened as help over an active
  /// session: the action returns to that session.
  final bool showStartAction;

  @override
  State<CaptureGuideScreen> createState() => _CaptureGuideScreenState();
}

class _CaptureGuideScreenState extends State<CaptureGuideScreen> {
  final PageController _page = PageController();
  int _sectionIndex = 0;

  // Tutorial state. Deliberately outside the capture domain: closing the
  // guide never marks anything captured, and reopening keeps the selection.
  CaptureGuideModeId _modeId = CaptureGuideModeId.start;
  int _directionIndex = 0;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  CaptureGuideMode get _mode =>
      captureGuideModes.firstWhere((m) => m.id == _modeId);

  void _goTo(int index) {
    final clamped = index.clamp(0, CaptureGuideSection.values.length - 1);
    _page.animateToPage(
      clamped,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _startCapture() {
    if (!widget.showStartAction) {
      Navigator.of(context).maybePop();
      return;
    }
    // Replace the guide so back from the capture screen returns to the
    // launcher — the user never lands back inside the instructions loop.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const SphereCaptureScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final section = CaptureGuideSection.values[_sectionIndex];
    final isIntro = _sectionIndex == 0;
    final isFinal =
        _sectionIndex == CaptureGuideSection.values.length - 1;
    final String primaryLabel;
    if (isFinal) {
      primaryLabel = widget.showStartAction
          ? 'Start Capture'
          : 'Return to capture';
    } else {
      primaryLabel = switch (section) {
        CaptureGuideSection.intro => 'See the capture plan',
        CaptureGuideSection.plan => 'Learn the camera controls',
        _ => 'Next',
      };
    }
    return Scaffold(
      backgroundColor: SiteWiseColors.surface,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              title: section.navLabel,
              showBack: !isIntro,
              onBack: isIntro
                  ? null
                  : () => _goTo(_sectionIndex - 1),
            ),
            _SectionIndicator(
              currentIndex: _sectionIndex,
              onSelect: _goTo,
            ),
            Expanded(
              child: PageView(
                controller: _page,
                onPageChanged: (index) =>
                    setState(() => _sectionIndex = index),
                children: [
                  _buildIntro(context),
                  _buildPlan(context),
                  _buildCamera(context),
                  _buildProgress(context),
                  _buildTutorial(context),
                ],
              ),
            ),
            _BottomBar(
              showBack: !isIntro,
              onBack: () => _goTo(_sectionIndex - 1),
              primaryLabel: primaryLabel,
              onPrimary: isFinal
                  ? _startCapture
                  : () => _goTo(_sectionIndex + 1),
              isFinal: isFinal,
            ),
          ],
        ),
      ),
    );
  }

  // ── shared pieces ─────────────────────────────────────────────────────────

  Widget _pill(String text) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: SiteWiseColors.softBlue,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: SiteWiseColors.primary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    ),
  );

  Widget _title(String text) => Text(
    text,
    style: const TextStyle(
      color: SiteWiseColors.ink,
      fontSize: 23,
      fontWeight: FontWeight.w800,
      height: 1.2,
      letterSpacing: -0.4,
    ),
  );

  Widget _desc(String text) => Text(
    text,
    style: const TextStyle(
      color: SiteWiseColors.muted,
      fontSize: 14,
      height: 1.5,
    ),
  );

  Widget _card(Widget child) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: SiteWiseColors.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: SiteWiseColors.border),
    ),
    child: child,
  );

  Widget _callout(String heading, String body) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: SiteWiseColors.softBlue,
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: SiteWiseColors.borderStrong),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          heading,
          style: const TextStyle(
            color: SiteWiseColors.primaryPressed,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          body,
          style: const TextStyle(
            color: Color(0xFF1E3A8A),
            fontSize: 12.5,
            height: 1.5,
          ),
        ),
      ],
    ),
  );

  Widget _body(Widget child) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
    child: child,
  );

  Widget _gap(double height) => SizedBox(height: height);

  // ── section 1 · intro ─────────────────────────────────────────────────────

  Widget _buildIntro(BuildContext context) {
    final plan = CaptureGuidePlan.instance;
    return _body(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _pill('BEFORE YOU START'),
          _gap(12),
          _title(CaptureGuideSection.intro.title),
          _gap(8),
          _desc(
            'You will take ${plan.total} photos, guided by the camera. Follow '
            'one target at a time — the app takes each photo for you.',
          ),
          _gap(14),
          Center(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = mathMin(260.0, constraints.maxWidth);
                return SizedBox(
                  width: size,
                  height: size,
                  child: CustomPaint(
                    painter: const SpherePlanPainter(
                      style: SphereMapStyle.plan,
                    ),
                  ),
                );
              },
            ),
          ),
          _gap(8),
          for (final (symbol, heading, body) in kCaptureGuideIntroEntries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: SiteWiseColors.softBlue,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      symbol,
                      style: const TextStyle(
                        color: SiteWiseColors.primary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          heading,
                          style: const TextStyle(
                            color: SiteWiseColors.ink,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          body,
                          style: const TextStyle(
                            color: SiteWiseColors.muted,
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          _gap(2),
          _callout(
            'For clearer results',
            'Turn the camera smoothly. When practical, keep it near the same '
            'viewpoint so nearby objects line up better between photos.',
          ),
        ],
      ),
    );
  }

  // ── section 2 · capture plan ──────────────────────────────────────────────

  Widget _buildPlan(BuildContext context) {
    final plan = CaptureGuidePlan.instance;
    return _body(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _pill('${plan.total} DIRECTIONS'),
          _gap(12),
          _title(CaptureGuideSection.plan.title),
          _gap(8),
          _desc(
            'The guide covers the room at three heights, plus the ceiling and '
            'floor. You do not need to memorize these angles.',
          ),
          _gap(14),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Capture directions',
                  style: TextStyle(
                    color: SiteWiseColors.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                _gap(10),
                for (final (name, count) in captureGuidePlanRows())
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: SiteWiseColors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          name,
                          style: const TextStyle(
                            color: SiteWiseColors.slate,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          count,
                          style: const TextStyle(
                            color: SiteWiseColors.muted,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          _gap(12),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'How far apart are the targets?',
                  style: TextStyle(
                    color: SiteWiseColors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Targets are about 30° apart around each ring. If a marker '
                  'is outside your screen, an arrow tells you which way to '
                  'turn or tilt.',
                  style: const TextStyle(
                    color: SiteWiseColors.muted,
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          _gap(12),
          _callout(
            'No setup steps to memorize',
            'The app sets the starting direction automatically. Follow the '
            'on-screen marker when you begin.',
          ),
        ],
      ),
    );
  }

  // ── section 3 · camera guide ──────────────────────────────────────────────

  Widget _buildCamera(BuildContext context) {
    final plan = CaptureGuidePlan.instance;
    final example = captureGuideModes
        .firstWhere((m) => m.id == CaptureGuideModeId.middle)
        .hudTarget!;
    return _body(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CameraTeachCard(example: example, total: plan.total),
          _gap(8),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: SiteWiseColors.softBlue,
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                'Camera control illustration',
                style: TextStyle(
                  color: SiteWiseColors.primaryPressed,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          _gap(14),
          _title(CaptureGuideSection.camera.title),
          _gap(8),
          Text(
            'White center ring = where to aim. Numbered circle = your next '
            'photo.',
            style: const TextStyle(
              color: SiteWiseColors.slate,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          _gap(8),
          _desc(
            'Turn or tilt to move the numbered target into the white center '
            'ring. When they line up, the ring turns green and the app '
            'captures automatically.',
          ),
        ],
      ),
    );
  }

  // ── section 4 · progress map ──────────────────────────────────────────────

  Widget _buildProgress(BuildContext context) {
    final plan = CaptureGuidePlan.instance;
    return _body(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _pill('${plan.total}-TARGET PROGRESS'),
          _gap(12),
          _title(CaptureGuideSection.progress.title),
          _gap(8),
          _desc(
            'Every saved photo marks one direction as complete. The map helps '
            'you see which parts of the room are covered.',
          ),
          _gap(14),
          _card(
            Column(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final size = mathMin(240.0, constraints.maxWidth);
                    return SizedBox(
                      width: size,
                      height: size,
                      child: CustomPaint(
                        painter: const SpherePlanPainter(
                          style: SphereMapStyle.progressExample,
                        ),
                      ),
                    );
                  },
                ),
                _gap(8),
                Text(
                  '${plan.total} planned directions · Example map (not live '
                  'progress)',
                  style: const TextStyle(
                    color: SiteWiseColors.muted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          _gap(12),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Progress by direction',
                  style: TextStyle(
                    color: SiteWiseColors.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                _gap(8),
                for (final (name, sub) in captureGuidePlanRows())
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: SiteWiseColors.muted,
                              width: 1.4,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          name,
                          style: const TextStyle(
                            color: SiteWiseColors.slate,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          sub,
                          style: const TextStyle(
                            color: SiteWiseColors.muted,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          _gap(12),
          _callout(
            'How to read the markers',
            'Green with a check means saved. A plain white outline means not '
            'yet captured. The numbered circle is the next target.',
          ),
        ],
      ),
    );
  }

  // ── section 5 · how to capture ────────────────────────────────────────────

  Widget _buildTutorial(BuildContext context) {
    final mode = _mode;
    final direction = captureGuideDirections[_directionIndex];
    return _body(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(CaptureGuideSection.tutorial.title),
          _gap(8),
          _desc(
            'Choose a direction below to see how to hold the phone and where '
            'the numbered target should go.',
          ),
          _gap(12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in captureGuideModes)
                Semantics(
                  button: true,
                  selected: m.id == _modeId,
                  label: '${m.label} guidance mode',
                  child: KeyedSubtree(
                    key: Key('guide_mode_${m.id.name}'),
                    child: OutlinedButton(
                      onPressed: () => setState(() {
                        _modeId = m.id;
                        _directionIndex = 0;
                      }),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: m.id == _modeId
                            ? CaptureColors.selectedFill
                            : SiteWiseColors.surface,
                        side: BorderSide(
                          color: m.id == _modeId
                              ? SiteWiseColors.primary
                              : SiteWiseColors.border,
                        ),
                        foregroundColor: m.id == _modeId
                            ? SiteWiseColors.primary
                            : SiteWiseColors.slate,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      child: Text(
                        m.label,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          _gap(12),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        mode.pattern,
                        style: const TextStyle(
                          color: SiteWiseColors.ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Text(
                      'Illustrated guidance',
                      style: TextStyle(
                        color: SiteWiseColors.muted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
                _gap(10),
                _HudPair(mode: mode),
                _gap(8),
                const Text(
                  'The center ring has four small ticks and never moves. The '
                  'numbered target is separate and follows the direction you '
                  'need to capture.',
                  style: TextStyle(
                    color: SiteWiseColors.muted,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          _gap(10),
          const Text(
            'How to hold the phone',
            style: TextStyle(
              color: SiteWiseColors.ink,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          _gap(8),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              color: SiteWiseColors.softBlue,
              constraints: const BoxConstraints(maxHeight: 240),
              width: double.infinity,
              child: Image.asset(
                mode.imageAsset,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    color: SiteWiseColors.muted,
                  ),
                ),
              ),
            ),
          ),
          _gap(12),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PHONE POSITION',
                  style: TextStyle(
                    color: SiteWiseColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                _gap(4),
                Text(
                  mode.prompt,
                  style: const TextStyle(
                    color: SiteWiseColors.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                _gap(6),
                Text(
                  mode.summary,
                  style: const TextStyle(
                    color: SiteWiseColors.muted,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                _gap(8),
                for (final tip in mode.tips)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: SiteWiseColors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tip,
                            style: const TextStyle(
                              color: SiteWiseColors.slate,
                              fontSize: 12.5,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          _gap(10),
          if (mode.hasRingSelector)
            _DirectionRow(
              direction: direction,
              index: _directionIndex,
              onSelect: (index) =>
                  setState(() => _directionIndex = index),
            )
          else
            _card(
              Row(
                children: [
                  const Icon(
                    Icons.explore_outlined,
                    size: 16,
                    color: SiteWiseColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      mode.id == CaptureGuideModeId.start
                          ? 'The first heading is set automatically — no fixed '
                              'station anchor.'
                          : 'The pole target has no fixed station anchor.',
                      style: const TextStyle(
                        color: SiteWiseColors.muted,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          _gap(12),
          for (final (heading, body) in kCaptureGuideRules)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      heading,
                      style: const TextStyle(
                        color: SiteWiseColors.ink,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      body,
                      style: const TextStyle(
                        color: SiteWiseColors.muted,
                        fontSize: 12.5,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small local helper so the layout code reads cleanly without importing
/// `dart:math` in several widgets.
double mathMin(double a, double b) => a < b ? a : b;

// ── top bar / indicator / bottom bar ────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.showBack,
    required this.onBack,
  });

  final String title;
  final bool showBack;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 6, 16, 0),
    child: Row(
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: showBack
              ? IconButton(
                  onPressed: onBack,
                  icon: const Icon(
                    Icons.chevron_left,
                    color: SiteWiseColors.ink,
                  ),
                  tooltip: 'Back to previous guide section',
                )
              : Center(
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: const BoxDecoration(
                      color: SiteWiseColors.primary,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.threesixty,
                      color: Colors.white,
                      size: 17,
                    ),
                  ),
                ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: SiteWiseColors.ink,
              fontSize: 16.5,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
        ),
        const Text(
          'Capture guide',
          style: TextStyle(color: SiteWiseColors.muted, fontSize: 12),
        ),
      ],
    ),
  );
}

class _SectionIndicator extends StatelessWidget {
  const _SectionIndicator({required this.currentIndex, required this.onSelect});

  final int currentIndex;
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: Row(
      children: [
        for (var i = 0; i < CaptureGuideSection.values.length; i++)
          Semantics(
            button: true,
            selected: i == currentIndex,
            label: '${CaptureGuideSection.values[i].navLabel} guide section',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Container(
                  width: i == currentIndex ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == currentIndex
                        ? SiteWiseColors.primary
                        : SiteWiseColors.border,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.showBack,
    required this.onBack,
    required this.primaryLabel,
    required this.onPrimary,
    required this.isFinal,
  });

  final bool showBack;
  final VoidCallback onBack;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final bool isFinal;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
    decoration: const BoxDecoration(
      color: SiteWiseColors.surface,
      border: Border(top: BorderSide(color: SiteWiseColors.border)),
    ),
    child: Row(
      children: [
        if (showBack)
          Expanded(
            flex: 2,
            child: OutlinedButton(
              key: const Key('guide_back'),
              onPressed: onBack,
              style: OutlinedButton.styleFrom(
                foregroundColor: SiteWiseColors.slate,
                side: const BorderSide(color: SiteWiseColors.border),
                minimumSize: const Size.fromHeight(
                  CaptureMetrics.primaryButtonHeight,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text(
                'Back',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        if (showBack) const SizedBox(width: 12),
        Expanded(
          flex: showBack ? 3 : 1,
          child: Semantics(
            button: true,
            label: isFinal
                ? '$primaryLabel — opens the capture camera'
                : 'Next guide section',
            child: FilledButton(
              key: const Key('guide_next'),
              onPressed: onPrimary,
              style: FilledButton.styleFrom(
                backgroundColor: SiteWiseColors.primary,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(
                  CaptureMetrics.primaryButtonHeight,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                primaryLabel,
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

// ── camera teaching card (section 3) ───────────────────────────────────────

/// The large mock camera card: the capture screen's chrome around a large
/// schematic HUD, teaching "which circle to follow" before the camera exists.
class _CameraTeachCard extends StatelessWidget {
  const _CameraTeachCard({required this.example, required this.total});

  /// The real target whose id and progress label the mock shows.
  final SphereTargetSpec example;
  final int total;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0xFF26384A),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: SiteWiseColors.border),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          child: Row(
            children: [
              const Icon(
                Icons.close,
                size: 14,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              Text(
                'Sphere synced',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.radio_button_checked,
                size: 13,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              Text(
                '1 / $total',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        AspectRatio(
          aspectRatio: 330 / 440,
          child: CustomPaint(
            painter: CameraHudPainter(
              targetId: example.targetId,
              targetFraction: captureGuideHudTargetOffsets[
                  CaptureGuideModeId.middle]!,
              large: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Turn right to align Target ${example.targetId}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                example.progressLabel,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Bring the numbered target into the fixed center circle. '
                'Capture is automatic.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.66),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ── HUD pair (section 5 stage) ──────────────────────────────────────────────

/// The two schematic HUD states for the selected mode: before alignment and
/// aligned with the green capture hold.
class _HudPair extends StatelessWidget {
  const _HudPair({required this.mode});

  final CaptureGuideMode mode;

  @override
  Widget build(BuildContext context) {
    final fraction = captureGuideHudTargetOffsets[mode.id]!;
    final target = mode.hudTarget!;
    Widget panel({
      required bool aligned,
      required String caption,
      required String note,
    }) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 330 / 220,
            child: CustomPaint(
              painter: CameraHudPainter(
                targetId: target.targetId,
                targetFraction: fraction,
                aligned: aligned,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            caption,
            style: const TextStyle(
              color: SiteWiseColors.ink,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            note,
            style: const TextStyle(
              color: SiteWiseColors.muted,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        panel(
          aligned: false,
          caption: 'Before alignment',
          note: 'Move the numbered marker toward the fixed white ring.',
        ),
        const SizedBox(width: 10),
        panel(
          aligned: true,
          caption: 'Aligned & capturing',
          note: 'Hold until the green progress finishes.',
        ),
      ],
    );
  }
}

// ── 12-direction selector (section 5, ring modes) ───────────────────────────

class _DirectionRow extends StatelessWidget {
  const _DirectionRow({
    required this.direction,
    required this.index,
    required this.onSelect,
  });

  final CaptureGuideDirection direction;
  final int index;
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: SiteWiseColors.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: SiteWiseColors.borderStrong),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _TurnButton(
          icon: Icons.chevron_left,
          tooltip: 'Previous target direction',
          onPressed: () => onSelect((index + 11) % 12),
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                '${direction.label} · ${direction.yawDeg.round()}°',
                key: const Key('guide_direction_label'),
                style: const TextStyle(
                  color: SiteWiseColors.ink,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                direction.turn,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: SiteWiseColors.muted,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 5,
                runSpacing: 5,
                children: [
                  for (var i = 0; i < captureGuideDirections.length; i++)
                    Semantics(
                      button: true,
                      selected: i == index,
                      label: captureGuideDirections[i].label,
                      child: GestureDetector(
                        onTap: () => onSelect(i),
                        child: Container(
                          width: i == index ? 18 : 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: i == index
                                ? SiteWiseColors.primary
                                : SiteWiseColors.border,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        _TurnButton(
          icon: Icons.chevron_right,
          tooltip: 'Next target direction',
          key: const Key('guide_dir_next'),
          onPressed: () => onSelect((index + 1) % 12),
        ),
      ],
    ),
  );
}

class _TurnButton extends StatelessWidget {
  const _TurnButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: SiteWiseColors.softBlue,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, color: SiteWiseColors.primary, size: 22),
        ),
      ),
    ),
  );
}
