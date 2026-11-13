import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

// The fixed 38-direction sphere of the 3DoF capture architecture.
//
// ## The one architectural difference from the ARCore flow
//
// These directions are **not** world positions. The sphere's centre is the
// phone, always: there is no SLAM, no plane detection and no anchor, so
// walking to a new spot moves the whole sphere with the phone rather than
// leaving targets behind. Only rotation is tracked, and the rendering applies
// the inverse device quaternion to these vectors — see
// `sphereTargetCameraDirection` in `sphere_projection.dart`.
//
// ## Frame
//
// Every `SphereTargetSpec.direction` is expressed in the **start device
// frame**: `+X` is screen-right, `+Y` is screen-up and `-Z` is the direction
// the rear camera looks. That is the frame the Android rotation vector maps to
// the world, so the same quaternion serves the maths and the native sensor
// with no handedness conversion in between.
//
// ## Layout (R = 1.0)
//
// ids 1–12:  Middle Ring, pitch 0°,   yaw 0°, 30°, … 330°
// id 13:     Zenith,      pitch +90°
// ids 14–25: Upper Ring,  pitch +45°, yaw −30°, −60°, … 0° (reverse sweep)
// ids 26–37: Lower Ring,  pitch −45°, yaw 0°, 30°, … 330°
// id 38:     Nadir,       pitch −90°
//
// ## Why 38 and not 26
//
// The rear camera measures ~50° horizontal and ~69° vertical field of view in
// portrait (3072 × 4096, 4.94 mm lens). At the old 45° yaw spacing, adjacent
// frames shared only 5° — 10% overlap — and the ±30° rings left a 60° gap to
// the poles. Both are below what a stitcher can match reliably.
//
// Twelve targets per ring put the yaw step at 30°, i.e. 40% horizontal
// overlap. Rings at ±45° put the vertical and pole gaps at 45°, i.e. ~35%
// overlap against the 69° vertical field of view. The ring order is a
// continuous path (middle → upper → zenith → lower → nadir) so every guided
// step is at most 45°, and the whole sphere is covered with no pair of
// neighbours below ~35% overlap.
//
// The upper ring sweeps backwards so it starts at the yaw where the middle
// ring ended; that is what keeps the middle → upper step at 45° instead of the
// 52° a jump back to yaw 0° would cost.

/// How many directions a complete sphere has.
const int kSphereTargetCount = 38;

/// The nominal capture radius. The sphere is a direction set, so the radius is
/// documentation and future 3D previews rather than a placement input.
const double kSphereRadiusM = 1.0;

/// Elevation of the upper and lower rings, in degrees.
const double kSphereRingPitchDeg = 45;

/// The alignment cone that turns a target green and starts the hold ring.
const double kSphereAlignmentToleranceDeg = 5;

/// How far past the tolerance the error must go before a filling hold is
/// discarded. A hand tremor at the boundary must not reset the ring, but a
/// deliberate turn must.
const double kSphereAlignmentExitDeg = 7;

/// One of the 38 directions, before any photograph exists.
class SphereTargetSpec {
  /// 1-based, 1…38.
  final int targetId;

  /// Azimuth within its ring, in degrees. `0` is straight ahead at Start.
  final double yawDeg;

  /// Elevation, in degrees: `+90` zenith, `0` horizon, `−90` nadir.
  final double pitchDeg;

  /// `Middle Ring`, `Upper Ring`, `Lower Ring`, `Zenith` or `Nadir`.
  final String ringName;

  /// 1-based position within [ringName]; the poles leave it `null`.
  final int? indexInRing;

  /// Unit direction in the start device frame (`-Z` forward).
  final Vec3 direction;

  const SphereTargetSpec({
    required this.targetId,
    required this.yawDeg,
    required this.pitchDeg,
    required this.ringName,
    required this.direction,
    this.indexInRing,
  });

  bool get isZenith => pitchDeg >= 89.999;

  bool get isNadir => pitchDeg <= -89.999;

  /// `Zenith`, `Nadir`, or `Middle Ring (0°)`.
  String get ringLabel {
    if (isZenith || isNadir) return ringName;
    return '$ringName (${yawDeg.round()}°)';
  }

  /// The bottom pill's sentence: `Target 1 / 38 — Middle Ring (0°)`.
  String get progressLabel =>
      'Target $targetId / $kSphereTargetCount — '
      '$ringLabel';

  /// The target as the guidance says it out loud.
  String get shortName {
    if (isZenith) return 'the zenith target';
    if (isNadir) return 'the nadir target';
    if (yawDeg.abs() < 1e-9 && pitchDeg.abs() < 1e-9) {
      return 'the front target';
    }
    return 'target $targetId';
  }
}

/// The unit direction of `(yaw, pitch)` in the start device frame.
///
/// `x = sin(yaw)·cos(pitch)`, `y = sin(pitch)`, `z = −cos(yaw)·cos(pitch)`.
/// A positive yaw is to the user's **right**, which is why the `z` term is
/// negated: the camera looks along `−Z`, not `+Z`.
Vec3 sphereDirection(double yawDeg, double pitchDeg) {
  final yaw = yawDeg * degToRad;
  final pitch = pitchDeg * degToRad;
  final horizontal = math.cos(pitch);
  return Vec3(
    math.sin(yaw) * horizontal,
    math.sin(pitch),
    -math.cos(yaw) * horizontal,
  );
}

/// Builds the fixed 38-target layout in capture order.
///
/// Pure and deterministic: the id→angle mapping is asserted once in the test
/// suite rather than re-derived per session. The order is a continuous path —
/// middle ring, upper ring (reverse sweep), zenith, lower ring, nadir — so
/// every guided step is at most 45° and the progress pill counts through a
/// route the user can actually follow.
List<SphereTargetSpec> buildSphereTargets() {
  const List<double> middleYaws = <double>[
    0,
    30,
    60,
    90,
    120,
    150,
    180,
    -150,
    -120,
    -90,
    -60,
    -30,
  ];
  const List<double> upperYaws = <double>[
    -30,
    -60,
    -90,
    -120,
    -150,
    180,
    150,
    120,
    90,
    60,
    30,
    0,
  ];
  const List<double> lowerYaws = <double>[
    0,
    30,
    60,
    90,
    120,
    150,
    180,
    -150,
    -120,
    -90,
    -60,
    -30,
  ];

  final targets = <SphereTargetSpec>[];
  var id = 0;

  void addRing(List<double> yaws, double pitch, String ringName) {
    for (var index = 0; index < yaws.length; index++) {
      id++;
      targets.add(
        SphereTargetSpec(
          targetId: id,
          yawDeg: yaws[index],
          pitchDeg: pitch,
          ringName: ringName,
          indexInRing: index + 1,
          direction: sphereDirection(yaws[index], pitch),
        ),
      );
    }
  }

  addRing(middleYaws, 0, 'Middle Ring');

  // The zenith sits after the middle ring: 90° up from the horizon, then 45°
  // back down to the upper ring. Putting it between the upper and lower rings
  // would make the next step 135°, because the lower ring is 135° from the
  // zenith — a jump no guided path should ask for.
  id++;
  targets.add(
    SphereTargetSpec(
      targetId: id,
      yawDeg: 0,
      pitchDeg: 90,
      ringName: 'Zenith',
      direction: sphereDirection(0, 90),
    ),
  );

  addRing(upperYaws, kSphereRingPitchDeg, 'Upper Ring');
  addRing(lowerYaws, -kSphereRingPitchDeg, 'Lower Ring');

  id++;
  targets.add(
    SphereTargetSpec(
      targetId: id,
      yawDeg: 0,
      pitchDeg: -90,
      ringName: 'Nadir',
      direction: sphereDirection(0, -90),
    ),
  );
  return List<SphereTargetSpec>.unmodifiable(targets);
}
