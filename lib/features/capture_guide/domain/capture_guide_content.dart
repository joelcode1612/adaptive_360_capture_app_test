import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';

/// Instructional content for the pre-capture guide, converted from the
/// supplied `SiteWise_360_Capture_Guidelines.html`.
///
/// **The real capture plan is the source of truth.** Every count, ring pitch
/// and example target id in this file is derived from [buildSphereTargets] /
/// [kSphereTargetCount] rather than hard-coded from the HTML, so if the
/// capture algorithm's plan ever changes, the guide's numbers follow it. The
/// HTML's own values (38 directions: 12+12+12+1+1 at 0°/±35°/±90°) were
/// verified against `sphere_target.dart` before being written down here.
///
/// Everything here is a teaching example: no live camera, no AR pose data and
/// no captured photographs are involved.
enum CaptureGuideModeId { start, middle, upper, lower, zenith, nadir }

/// One section of the guide, in the order the user walks through it.
enum CaptureGuideSection {
  intro('Introduction', 'Capture your space in 360°'),
  plan('Capture plan', 'Cover the room from every angle'),
  camera('Camera guide', 'Know which circle to follow'),
  progress('Progress map', 'See which directions are saved'),
  tutorial('How to capture', 'Follow the target into the center circle');

  const CaptureGuideSection(this.navLabel, this.title);

  /// Short label for the section indicator.
  final String navLabel;

  /// The section's heading.
  final String title;
}

/// Ring/target counts read from the real capture plan.
class CaptureGuidePlan {
  CaptureGuidePlan._(List<SphereTargetSpec> targets)
    : total = kSphereTargetCount,
      ringPitchDeg = kSphereRingPitchDeg,
      middleCount = targets
          .where((t) => t.pitchDeg.abs() < 1e-9)
          .length,
      upperCount = targets
          .where((t) => t.pitchDeg > 1e-9 && !t.isZenith)
          .length,
      lowerCount = targets
          .where((t) => t.pitchDeg < -1e-9 && !t.isNadir)
          .length,
      exampleStartTarget = targets.firstWhere(
        (t) => t.pitchDeg.abs() < 1e-9 && t.yawDeg.abs() < 1e-9,
      ),
      exampleMiddleTarget = targets.firstWhere(
        (t) => t.pitchDeg.abs() < 1e-9 && (t.yawDeg - 30).abs() < 1e-9,
      ),
      exampleUpperTarget = targets
          .where((t) => t.pitchDeg > 1e-9 && !t.isZenith)
          .reduce(
            (a, b) => a.targetId > b.targetId ? a : b,
          ),
      exampleLowerTarget = targets
          .where((t) => t.pitchDeg < -1e-9 && !t.isNadir)
          .reduce(
            (a, b) => a.targetId < b.targetId ? a : b,
          ),
      exampleZenithTarget = targets.firstWhere((t) => t.isZenith),
      exampleNadirTarget = targets.firstWhere((t) => t.isNadir);

  /// The verified plan, built once.
  static final CaptureGuidePlan instance = CaptureGuidePlan._(
    buildSphereTargets(),
  );

  final int total;
  final double ringPitchDeg;
  final int middleCount;
  final int upperCount;
  final int lowerCount;

  /// The example targets the HUD illustrations use, taken from the real
  /// capture order: target 1 (first shot), target 2 (the example "turn right"
  /// step), the upper ring's last id, the lower ring's first id and the poles.
  final SphereTargetSpec exampleStartTarget;
  final SphereTargetSpec exampleMiddleTarget;
  final SphereTargetSpec exampleUpperTarget;
  final SphereTargetSpec exampleLowerTarget;
  final SphereTargetSpec exampleZenithTarget;
  final SphereTargetSpec exampleNadirTarget;
}

/// One of the six posture patterns the tutorial section teaches.
class CaptureGuideMode {
  const CaptureGuideMode({
    required this.id,
    required this.label,
    required this.pitchDeg,
    required this.prompt,
    required this.summary,
    required this.tips,
    required this.pattern,
    required this.imageAsset,
    required this.hudTarget,
  });

  final CaptureGuideModeId id;
  final String label;

  /// The phone pitch the mode demonstrates; `null` means "keep it level" (the
  /// start posture, where the app sets the first heading itself).
  final double? pitchDeg;
  final String prompt;
  final String summary;
  final List<String> tips;

  /// The stage's small pattern badge, e.g. `Middle · 0°`.
  final String pattern;

  /// Asset path of the supplied posture illustration.
  final String imageAsset;

  /// The real target the HUD examples project, from [CaptureGuidePlan].
  /// Null only in the declarative seed list; [captureGuideModes] fills it.
  final SphereTargetSpec? hudTarget;

  /// The bottom-left angle line, as the HTML renders it.
  String get angleLabel {
    final pitch = pitchDeg;
    if (pitch == null) return 'Keep camera level';
    if (pitch == 0) return 'Phone level';
    if (pitch > 0) return 'Tilt up ${pitch.round()}°';
    return 'Tilt down ${pitch.abs().round()}°';
  }

  /// Whether the 12-direction ring selector applies to this mode.
  bool get hasRingSelector =>
      id == CaptureGuideModeId.middle ||
      id == CaptureGuideModeId.upper ||
      id == CaptureGuideModeId.lower;
}

const List<CaptureGuideMode> kCaptureGuideModes = [
  CaptureGuideMode(
    id: CaptureGuideModeId.start,
    label: 'Start position',
    pitchDeg: null,
    prompt: 'Begin facing forward with the phone level',
    summary:
        'Hold the phone upright and level. After you press Start, the app '
        'establishes the first heading automatically; the first target is '
        'straight ahead.',
    tips: [
      'The fixed center aiming circle stays in the middle of the camera '
          'preview.',
      'The numbered target marker is a separate circle that moves on screen '
          'as you turn.',
      'There is no manual setup step before the first photo.',
    ],
    pattern: 'First target · 0°',
    imageAsset: 'assets/images/capture_guide/guide_start.webp',
    hudTarget: null, // filled below with the plan's target 1
  ),
  CaptureGuideMode(
    id: CaptureGuideModeId.middle,
    label: 'Middle ring',
    pitchDeg: 0,
    prompt: 'Follow the middle-ring targets horizontally',
    summary:
        'The middle ring has 12 directions, spaced 30° apart. Turn until the '
        'numbered target moves into the fixed center aiming circle.',
    tips: [
      'Keep the phone approximately level for middle-ring targets.',
      'Only the highlighted numbered marker is the target to capture.',
      'A green ring and filling arc mean the automatic capture hold is '
          'active.',
    ],
    pattern: 'Middle · 0°',
    imageAsset: 'assets/images/capture_guide/guide_middle.webp',
    hudTarget: null,
  ),
  CaptureGuideMode(
    id: CaptureGuideModeId.upper,
    label: 'Upper ring',
    pitchDeg: kSphereRingPitchDeg,
    prompt: 'Aim slightly upward toward the upper targets',
    summary:
        'Tilt your phone upward about 35° from level, then follow the next '
        'numbered marker. There are 12 upper targets, spaced 30° '
        'horizontally.',
    tips: [
      'The numbered marker moves; the white aiming ring stays centered.',
      'Follow the on-screen turn/tilt arrow if the marker is outside the '
          'preview.',
      'Hold alignment until the photograph is saved.',
    ],
    pattern: 'Upper · +35°',
    imageAsset: 'assets/images/capture_guide/guide_upper.webp',
    hudTarget: null,
  ),
  CaptureGuideMode(
    id: CaptureGuideModeId.lower,
    label: 'Lower ring',
    pitchDeg: -kSphereRingPitchDeg,
    prompt: 'Aim slightly downward toward the lower targets',
    summary:
        'Tilt downward approximately 35° from level and align the highlighted '
        'numbered marker with the fixed central ring.',
    tips: [
      'There are 12 lower targets, spaced 30° horizontally.',
      'The white aiming ring stays in the middle of the screen.',
      'The green hold arc indicates automatic capture in progress.',
    ],
    pattern: 'Lower · −35°',
    imageAsset: 'assets/images/capture_guide/guide_lower.webp',
    hudTarget: null,
  ),
  CaptureGuideMode(
    id: CaptureGuideModeId.zenith,
    label: 'Ceiling',
    pitchDeg: 90,
    prompt: 'Point the rear camera upward for the ceiling',
    summary:
        'Follow the active target toward the ceiling (zenith, +90°) until it '
        'enters the center aiming circle.',
    tips: [
      'The directional arrow helps when the target is off-screen.',
      'Follow the numbered marker into the center ring.',
      'Hold alignment for automatic capture.',
    ],
    pattern: 'Ceiling · +90°',
    imageAsset: 'assets/images/capture_guide/guide_zenith.webp',
    hudTarget: null,
  ),
  CaptureGuideMode(
    id: CaptureGuideModeId.nadir,
    label: 'Floor',
    pitchDeg: -90,
    prompt: 'Point the rear camera downward for the floor',
    summary:
        'Follow the active target toward the floor (nadir, −90°), then align '
        'it with the fixed center aiming circle.',
    tips: [
      'Avoid obscuring the camera lens while aiming downward.',
      'Follow the green hold indicator and wait for the saved-photo '
          'confirmation.',
      'After every required target is saved, the app starts panorama '
          'generation.',
    ],
    pattern: 'Floor · −90°',
    imageAsset: 'assets/images/capture_guide/guide_nadir.webp',
    hudTarget: null,
  ),
];

/// The six modes, with their HUD example targets resolved from the real plan.
///
/// A top-level `final` list built from [kCaptureGuideModes] because the
/// `hudTarget: null` placeholders above keep the const list declarative; the
/// real target ids come from [CaptureGuidePlan.instance].
final List<CaptureGuideMode> captureGuideModes = () {
  final plan = CaptureGuidePlan.instance;
  final byId = <CaptureGuideModeId, SphereTargetSpec>{
    CaptureGuideModeId.start: plan.exampleStartTarget,
    CaptureGuideModeId.middle: plan.exampleMiddleTarget,
    CaptureGuideModeId.upper: plan.exampleUpperTarget,
    CaptureGuideModeId.lower: plan.exampleLowerTarget,
    CaptureGuideModeId.zenith: plan.exampleZenithTarget,
    CaptureGuideModeId.nadir: plan.exampleNadirTarget,
  };
  return kCaptureGuideModes
      .map(
        (m) => CaptureGuideMode(
          id: m.id,
          label: m.label,
          pitchDeg: m.pitchDeg,
          prompt: m.prompt,
          summary: m.summary,
          tips: m.tips,
          pattern: m.pattern,
          imageAsset: m.imageAsset,
          hudTarget: byId[m.id]!,
        ),
      )
      .toList();
}();

/// One selectable ring direction in the tutorial's 12-direction row.
class CaptureGuideDirection {
  const CaptureGuideDirection({
    required this.label,
    required this.yawDeg,
    required this.turn,
  });

  /// `Forward`, `Behind`, `30° right`, `150° left`, …
  final String label;
  final double yawDeg;

  /// The one-line instruction under the label.
  final String turn;
}

/// The 12 ring directions, labelled exactly as the reference does.
final List<CaptureGuideDirection> captureGuideDirections = List<
  CaptureGuideDirection
>.generate(12, (i) {
  final yaw = i * 30.0;
  final label = yaw == 0
      ? 'Forward'
      : yaw == 180
      ? 'Behind'
      : yaw < 180
      ? '${yaw.round()}° right'
      : '${(360 - yaw).round()}° left';
  return CaptureGuideDirection(
    label: label,
    yawDeg: yaw,
    turn: yaw == 0
        ? 'Face your starting direction.'
        : 'Rotate toward the ${label.toLowerCase()} direction; the app will '
              'show the actual active marker.',
  );
});

/// The intro section's three entry points, as the reference lists them.
const List<(String, String, String)> kCaptureGuideIntroEntries = [
  (
    '⌖',
    'Begin with the phone level',
    'Hold the phone upright, facing ahead. Your starting direction is set '
        'automatically.',
  ),
  (
    '◎',
    'Find the numbered target',
    'The white aiming ring stays in the middle. Move the phone to bring the '
        'numbered circle inside it.',
  ),
  (
    '✓',
    'Wait for the green ring',
    'Keep the target aligned until the green progress finishes and the photo '
        'is saved.',
  ),
];

/// The plan/progress section's five direction rows, with counts from the
/// verified plan.
List<(String, String)> captureGuidePlanRows() {
  final plan = CaptureGuidePlan.instance;
  return [
    ('Middle ring · 0°', '${plan.middleCount} targets'),
    ('Upper ring · +${plan.ringPitchDeg.round()}°', '${plan.upperCount} targets'),
    ('Lower ring · −${plan.ringPitchDeg.round()}°', '${plan.lowerCount} targets'),
    ('Zenith · +90°', 'Ceiling · 1'),
    ('Nadir · −90°', 'Floor · 1'),
  ];
}

/// The three closing rules of the tutorial section.
const List<(String, String)> kCaptureGuideRules = [
  (
    'Only follow the numbered target',
    'The white ring stays fixed in the middle. Aim the numbered marker inside '
        'it and wait for the green capture progress.',
  ),
  (
    'Help the photos join cleanly',
    'Move smoothly between views. When practical, keep the camera near the '
        'same point to reduce visible joins around nearby objects.',
  ),
  (
    'About these illustrations',
    'The people show how to hold the phone. The dark panels show what the two '
        'circles look like in the camera. This guide does not take photos.',
  ),
];

/// Offsets of the numbered example target inside the schematic HUD, expressed
/// as fractions of the HUD size, per mode — ported from the reference's
/// `guideHudSvg` geometry (330×220 nominal box, centre ring at 0.5/0.5).
/// The painter scales these by its own canvas size.
final Map<CaptureGuideModeId, Offset> captureGuideHudTargetOffsets = () {
  // Fractional positions from the HTML's absolute ones (W=330, H=220,
  // cx=165, cy=110): start (229,110), middle (245,110), upper (189,42),
  // lower (189,178), zenith (165,27), nadir (165,193).
  Offset frac(double x, double y) => Offset(x / 330, y / 220);
  return {
    CaptureGuideModeId.start: frac(229, 110),
    CaptureGuideModeId.middle: frac(245, 110),
    CaptureGuideModeId.upper: frac(189, 42),
    CaptureGuideModeId.lower: frac(189, 178),
    CaptureGuideModeId.zenith: frac(165, 27),
    CaptureGuideModeId.nadir: frac(165, 193),
  };
}();

/// Polar position of one plan direction on the schematic sphere, ported from
/// the reference's `sphere()` (112-centre, 91-radius, 0.34 tilt model in a
/// 224 box). Returned as fractions of the square canvas.
Offset spherePointFraction(double pitchDeg, double yawDeg) {
  const tilt = 0.34;
  final pitch = pitchDeg * math.pi / 180;
  final yaw = yawDeg * math.pi / 180;
  final x = math.cos(pitch) * math.sin(yaw);
  final y = math.sin(pitch);
  final z = math.cos(pitch) * math.cos(yaw);
  const c = 112.0;
  final r = 91.0;
  final px = c + r * x;
  final py = c - r * (y * math.cos(tilt) - z * math.sin(tilt));
  return Offset(px / 224, py / 224);
}
