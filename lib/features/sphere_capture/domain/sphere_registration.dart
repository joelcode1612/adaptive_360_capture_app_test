// Rotation refinement for the 38-target sphere flow.
//
// Pure Dart — no Flutter, no OpenCV — so the registration arithmetic is
// executable on the plain VM and reviewable without a device.
//
// ## What this file is for
//
// The stitcher used to project every frame through the quaternion the sensor
// recorded, and nothing ever checked that quaternion. A gyroscope-integrated
// orientation is good to a couple of degrees and drifts; two degrees at a seam
// is a visible tear, and a torn edge is what the capture that prompted this work
// actually shipped.
//
// So the recorded quaternion stays the *prior* — it is never thrown away — and
// this file refines it against the pixels two neighbouring photographs share.
// The refinement is deliberately small-angle: the correction is expected to be a
// degree or two, and anything larger is treated as a bad match rather than as a
// discovery.
//
// ## Why not decompose a homography
//
// The textbook route is `H = K R K⁻¹`, then extract `R` and orthonormalise. It
// was not taken, for one concrete reason: this project has two camera
// conventions in play (the pose's `R·ẑ` is *forward*, while the stitcher's
// `depth = −camZ` puts forward on *−Z*). A homography decomposition has to pick
// a side and conjugate by a flip, and getting that wrong is silent — the
// panorama still renders, just slightly rotated, which looks exactly like the
// bug being fixed.
//
// Instead the residual is measured **through the same projection the stitcher
// uses**. A matched pixel in a neighbour is unprojected, carried into the world
// by that neighbour's quaternion, carried back by this frame's quaternion, and
// projected — the identical `depth = −camZ` formula. Both conventions therefore
// cancel by construction, and there is no basis left to get backwards.
library;

import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_intrinsics.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Fewer than this many geometrically consistent matches is not evidence.
const int kSphereRegistrationMinInliers = 12;

/// And a low inlier fraction means the matches were mostly coincidence, even if
/// enough of them survived RANSAC to clear [kSphereRegistrationMinInliers].
const double kSphereRegistrationMinInlierRatio = 0.35;

/// A visual correction larger than this is a misregistration, not a refinement.
/// The sensor prior is trusted to within a few degrees; a match that disagrees
/// by more than this is describing a different part of the room.
const double kSphereRegistrationMaxCorrectionDeg = 12;

/// After correction, the matches must still agree to within this many pixels of
/// the registration image. Above it the pair is registered to the wrong place
/// and its correction is refused.
///
/// Eight pixels at the quarter-scale decode is roughly half a degree — the same
/// tolerance the existing incremental worker uses for a pair it is willing to
/// merge, so the two pipelines agree on what "aligned" means.
const double kSphereRegistrationMaxResidualPx = 8;

/// Only frames whose optical axes are within this angle are matched at all.
///
/// This is the performance gate as much as a geometric one: 38 frames is 703
/// pairs, and every pair costs a knn match plus a RANSAC. Restricting to the
/// frames that actually overlap cuts that to a few hundred matches over the
/// whole station, and matching a frame against the opposite wall was never going
/// to produce inliers anyway.
const double kSphereRegistrationNeighbourDeg = 60;

/// A direction in a camera frame, in the convention the stitcher projects with:
/// `+X` right, `+Y` up, `−Z` forward.
///
/// The exact algebraic inverse of [projectCameraRay], rather than a `K⁻¹`
/// matrix, so the two cannot drift apart.
Vec3 unprojectPixel(
  double u,
  double v,
  DecodedProjection projection,
) => Vec3(
  (u - projection.cx) / projection.focalPx,
  -(v - projection.cy) / projection.focalPx,
  -1,
);

/// Projects a camera-frame direction to a pixel, or `null` when it is behind the
/// camera. The `depth <= 0` test is the same one the projection loop uses, so a
/// correspondence that would be discarded while rendering is discarded here too
/// rather than contributing a mirrored residual.
({double u, double v})? projectCameraRay(
  Vec3 ray,
  DecodedProjection projection,
) {
  final depth = -ray.z;
  if (depth <= 1e-6) return null;
  return (
    u: projection.cx + projection.focalPx * ray.x / depth,
    v: projection.cy - projection.focalPx * ray.y / depth,
  );
}

/// One geometrically consistent match between a frame and a neighbour.
///
/// Coordinates are in the **registration image** — the reduced decode the
/// features were found in, not the saved JPEG. [DecodedProjection] carries the
/// scale, so nothing here has to know which reduction was used.
class SphereCorrespondence {
  const SphereCorrespondence({
    required this.frameU,
    required this.frameV,
    required this.neighbourU,
    required this.neighbourV,
  });

  /// Where the feature is in the frame being refined.
  final double frameU;
  final double frameV;

  /// Where the same feature is in the already-trusted neighbour.
  final double neighbourU;
  final double neighbourV;
}

/// The outcome of refining one frame against one neighbour.
class SphereEdgeRefinement {
  const SphereEdgeRefinement({
    required this.correction,
    required this.correctionDeg,
    required this.inliers,
    required this.inlierRatio,
    required this.residualBeforePx,
    required this.residualAfterPx,
    required this.accepted,
    required this.rejection,
  });

  /// The world-frame rotation to left-multiply onto the frame's quaternion.
  final Quat correction;

  /// Magnitude of [correction], in degrees — the number the rejection rules test.
  final double correctionDeg;

  final int inliers;
  final double inlierRatio;

  /// Mean reprojection error before and after the refinement. Reported, and the
  /// evidence that the correction improved anything at all.
  final double residualBeforePx;
  final double residualAfterPx;

  final bool accepted;

  /// Why the edge was refused, or `null` when it was accepted. Kept as text so a
  /// failed station can explain itself instead of silently falling back.
  final String? rejection;

  /// An edge that changed nothing, for the cases where there is nothing to say.
  static const SphereEdgeRefinement none = SphereEdgeRefinement(
    correction: Quat.identity,
    correctionDeg: 0,
    inliers: 0,
    inlierRatio: 0,
    residualBeforePx: 0,
    residualAfterPx: 0,
    accepted: false,
    rejection: 'No correspondence was measured.',
  );
}

/// Refines [frameRotation] so that the [correspondences] land where the
/// neighbour says they should.
///
/// The rotation is updated as `q' = exp(δ) · q` with `δ` a world-frame
/// axis-angle vector, solved by damped Gauss–Newton on the reprojection error.
/// Gauss–Newton rather than a closed form because the residual is a projection:
/// it is nonlinear in the rotation, and the linearisation is only valid for the
/// small corrections this is meant to produce — which is also why an oversized
/// solution is rejected rather than clamped.
///
/// The Jacobian is taken by central finite differences. Three parameters and a
/// few hundred correspondences make it cheap, and it removes an entire class of
/// silent sign errors that an analytic derivative of a double-conjugated
/// projection invites.
///
/// [frameRotation] and [neighbourRotation] are camera→world, the convention of
/// `cameraOrientation` in the capture records.
SphereEdgeRefinement refineRotationFromCorrespondences({
  required Quat frameRotation,
  required Quat neighbourRotation,
  required DecodedProjection frameProjection,
  required DecodedProjection neighbourProjection,
  required List<SphereCorrespondence> correspondences,
  required int featureMatches,
}) {
  final inlierRatio = featureMatches == 0
      ? 0.0
      : correspondences.length / featureMatches;
  if (correspondences.length < kSphereRegistrationMinInliers) {
    return SphereEdgeRefinement(
      correction: Quat.identity,
      correctionDeg: 0,
      inliers: correspondences.length,
      inlierRatio: inlierRatio,
      residualBeforePx: 0,
      residualAfterPx: 0,
      accepted: false,
      rejection:
          'Only ${correspondences.length} matches survived geometric '
          'verification; $kSphereRegistrationMinInliers are needed to trust a '
          'rotation.',
    );
  }
  if (inlierRatio < kSphereRegistrationMinInlierRatio) {
    return SphereEdgeRefinement(
      correction: Quat.identity,
      correctionDeg: 0,
      inliers: correspondences.length,
      inlierRatio: inlierRatio,
      residualBeforePx: 0,
      residualAfterPx: 0,
      accepted: false,
      rejection:
          'Only ${(inlierRatio * 100).toStringAsFixed(0)}% of the matches were '
          'geometrically consistent.',
    );
  }

  // Neighbour-side rays are fixed for the whole solve, so they are computed once.
  final worldRays = <Vec3>[
    for (final SphereCorrespondence c in correspondences)
      neighbourRotation.rotate(
        unprojectPixel(c.neighbourU, c.neighbourV, neighbourProjection),
      ),
  ];

  final before = _meanResidual(
    frameRotation,
    worldRays,
    correspondences,
    frameProjection,
  );

  var rotation = frameRotation;
  var acceptedDelta = Vec3.zero;
  var residual = before;

  const iterations = 8;
  for (var iteration = 0; iteration < iterations; iteration++) {
    final linear = _linearise(
      rotation,
      worldRays,
      correspondences,
      frameProjection,
    );
    if (linear.jacobian.isEmpty) break;
    final normal = _normalEquations(linear.jacobian, linear.residual);

    final trace = normal.matrix[0] + normal.matrix[4] + normal.matrix[8];
    if (trace <= 0) break;
    // Damping scaled off the diagonal, so it is unit-consistent whether the
    // residuals are pixels or sub-pixels.
    final lambda = 1e-6 * trace / 3;
    final damped = <double>[
      normal.matrix[0] + lambda, normal.matrix[1], normal.matrix[2], //
      normal.matrix[3], normal.matrix[4] + lambda, normal.matrix[5], //
      normal.matrix[6], normal.matrix[7], normal.matrix[8] + lambda, //
    ];
    final solved = _solve3x3(damped, <double>[
      -normal.gradient[0],
      -normal.gradient[1],
      -normal.gradient[2],
    ]);
    if (solved == null) break;
    // `_solve3x3` works in plain doubles, but everything downstream of here is
    // vector math: `length`, `+`, and `_applyWorldRotation`'s axis-angle. The
    // solution becomes a Vec3 once, at the boundary, instead of being converted
    // at each use.
    final step = Vec3.fromList(solved);
    final stepLength = step.length;
    if (stepLength < 1e-9) break;

    final candidate = _applyWorldRotation(rotation, step);
    final updated = _meanResidual(
      candidate,
      worldRays,
      correspondences,
      frameProjection,
    );
    // A step that makes the alignment worse is discarded, not kept. With
    // damping this is rare, but a grazing correspondence can still push the
    // solve over a ridge, and keeping the worse of two rotations would be
    // indefensible.
    if (updated > residual + 1e-9) break;

    rotation = candidate;
    acceptedDelta = acceptedDelta + step;
    residual = updated;
  }

  final correctionDeg = acceptedDelta.length * 180 / math.pi;
  if (correctionDeg > kSphereRegistrationMaxCorrectionDeg) {
    return SphereEdgeRefinement(
      correction: Quat.identity,
      correctionDeg: correctionDeg,
      inliers: correspondences.length,
      inlierRatio: inlierRatio,
      residualBeforePx: before,
      residualAfterPx: residual,
      accepted: false,
      rejection:
          'The matches would rotate this frame by '
          '${correctionDeg.toStringAsFixed(1)}°, too far from the sensor '
          'estimate to be a refinement.',
    );
  }
  if (residual > kSphereRegistrationMaxResidualPx) {
    return SphereEdgeRefinement(
      correction: Quat.identity,
      correctionDeg: correctionDeg,
      inliers: correspondences.length,
      inlierRatio: inlierRatio,
      residualBeforePx: before,
      residualAfterPx: residual,
      accepted: false,
      rejection:
          'The matches still disagree by ${residual.toStringAsFixed(1)} px '
          'after correction.',
    );
  }
  // A correction that makes the alignment worse is not a correction. This is
  // what a repeated texture produces: many consistent-looking matches that
  // agree on the wrong offset.
  if (residual > before && before > 0) {
    return SphereEdgeRefinement(
      correction: Quat.identity,
      correctionDeg: 0,
      inliers: correspondences.length,
      inlierRatio: inlierRatio,
      residualBeforePx: before,
      residualAfterPx: before,
      accepted: false,
      rejection:
          'Correcting this frame made the alignment worse '
          '(${before.toStringAsFixed(1)} px → ${residual.toStringAsFixed(1)} px).',
    );
  }
  if (correctionDeg < 0.01) {
    return SphereEdgeRefinement(
      correction: Quat.identity,
      correctionDeg: 0,
      inliers: correspondences.length,
      inlierRatio: inlierRatio,
      residualBeforePx: before,
      residualAfterPx: residual,
      accepted: false,
      rejection: 'The sensor estimate was already correct to within 0.01°.',
    );
  }

  return SphereEdgeRefinement(
    correction: _applyWorldRotation(Quat.identity, acceptedDelta),
    correctionDeg: correctionDeg,
    inliers: correspondences.length,
    inlierRatio: inlierRatio,
    residualBeforePx: before,
    residualAfterPx: residual,
    accepted: true,
    rejection: null,
  );
}

/// Merges the corrections several neighbours propose for one frame.
///
/// Averaging is not the same as choosing, and it is deliberate: each accepted
/// edge is an independent measurement of the same small error, so their mean is
/// a better estimate than any single one, and one bad edge is outvoted instead
/// of trusted.
///
/// **Shrinkage.** When the proposals disagree — which is what a repeated texture
/// or a moving object looks like — the mean is pulled toward zero rather than
/// applied at full strength. A frame whose neighbours cannot agree is a frame
/// whose sensor prior is probably right, and a half-applied correction is a much
/// smaller mistake than a confidently wrong one.
///
/// Returns `null` when no correction should be applied, so the caller keeps the
/// recorded quaternion untouched — the path that low-texture walls take.
Quat? mergeSphereCorrections(List<SphereEdgeRefinement> refinements) {
  final accepted = <SphereEdgeRefinement>[
    for (final SphereEdgeRefinement r in refinements)
      if (r.accepted && r.correctionDeg > 0) r,
  ];
  if (accepted.isEmpty) return null;

  final vectors = <Vec3>[];
  final weights = <double>[];
  var weightSum = 0.0;
  for (final SphereEdgeRefinement r in accepted) {
    // Inlier count says how much evidence backed the proposal; the inlier
    // fraction says how clean that evidence was. Multiplying them lets a
    // well-supported, unambiguous edge dominate a large but noisy one.
    final weight = r.inliers * r.inlierRatio;
    if (weight <= 0) continue;
    vectors.add(_axisAngleVector(r.correction, r.correctionDeg));
    weights.add(weight);
    weightSum += weight;
  }
  if (weightSum <= 0) return null;

  var mean = Vec3.zero;
  for (var i = 0; i < vectors.length; i++) {
    mean = mean + vectors[i] * weights[i];
  }
  mean = mean * (1 / weightSum);
  if (mean.length <= 1e-9) return null;

  // Weighted mean absolute deviation of the proposals.
  var deviation = 0.0;
  for (var i = 0; i < vectors.length; i++) {
    deviation += weights[i] * (vectors[i] - mean).length;
  }
  deviation /= weightSum;

  final shrunk = deviation > 0.5 * mean.length ? mean * 0.5 : mean;
  final degrees = shrunk.length * 180 / math.pi;
  if (degrees < 0.01) return null;
  return _applyWorldRotation(Quat.identity, shrunk);
}

/// Angle in degrees between two camera orientations, used to decide which frames
/// are neighbours worth matching at all.
double sphereOrientationGapDeg(Quat a, Quat b) {
  final dot = (a.conjugate * b).w.abs().clamp(0.0, 1.0);
  return 2 * math.acos(dot) * 180 / math.pi;
}

/// Left-multiplies a world-frame axis-angle rotation onto [rotation].
Quat _applyWorldRotation(Quat rotation, Vec3 axisAngle) {
  final length = axisAngle.length;
  if (length <= 1e-12) return rotation;
  return (Quat.axisAngle(length * 180 / math.pi, axisAngle) * rotation)
      .normalized;
}

/// A correction quaternion as a world-frame axis-angle vector in radians.
Vec3 _axisAngleVector(Quat correction, double correctionDeg) {
  final axis = Vec3(correction.x, correction.y, correction.z);
  final length = axis.length;
  if (length <= 1e-12) return Vec3.zero;
  return axis * (correctionDeg * math.pi / 180 / length);
}

/// Mean reprojection error, in pixels, of the correspondences under [rotation].
double _meanResidual(
  Quat rotation,
  List<Vec3> worldRays,
  List<SphereCorrespondence> correspondences,
  DecodedProjection projection,
) {
  final toCamera = rotation.conjugate;
  var sum = 0.0;
  var count = 0;
  for (var i = 0; i < correspondences.length; i++) {
    final predicted = projectCameraRay(
      toCamera.rotate(worldRays[i]),
      projection,
    );
    if (predicted == null) continue;
    final du = predicted.u - correspondences[i].frameU;
    final dv = predicted.v - correspondences[i].frameV;
    sum += math.sqrt(du * du + dv * dv);
    count++;
  }
  return count == 0 ? 0 : sum / count;
}

/// The Jacobian of the reprojection error with respect to a world-frame rotation
/// increment, plus the residual it linearises — both in one pass, so the two can
/// never be built from different rotations.
///
/// `q' = exp(δ)·q`, so a positive δ rotates the *world*, which rotates the
/// camera's rays by `−δ`. The sign lives inside the difference rather than being
/// assumed.
({List<double> jacobian, List<double> residual}) _linearise(
  Quat rotation,
  List<Vec3> worldRays,
  List<SphereCorrespondence> correspondences,
  DecodedProjection projection,
) {
  const h = 1e-4; // radians
  final count = correspondences.length;
  final jacobian = List<double>.filled(count * 6, 0);
  final residual = List<double>.filled(count * 2, 0);

  final toCamera = rotation.conjugate;
  for (var i = 0; i < count; i++) {
    final predicted = projectCameraRay(
      toCamera.rotate(worldRays[i]),
      projection,
    );
    if (predicted == null) continue;
    residual[i * 2] = predicted.u - correspondences[i].frameU;
    residual[i * 2 + 1] = predicted.v - correspondences[i].frameV;
  }

  for (var axis = 0; axis < 3; axis++) {
    final unit = switch (axis) {
      0 => Vec3.unitX,
      1 => Vec3.unitY,
      _ => Vec3.unitZ,
    };
    final plus = (Quat.axisAngle(h * 180 / math.pi, unit) * rotation).normalized;
    final minus = (Quat.axisAngle(-h * 180 / math.pi, unit) * rotation)
        .normalized;
    final plusToCamera = plus.conjugate;
    final minusToCamera = minus.conjugate;
    for (var i = 0; i < count; i++) {
      final p = projectCameraRay(
        plusToCamera.rotate(worldRays[i]),
        projection,
      );
      final m = projectCameraRay(
        minusToCamera.rotate(worldRays[i]),
        projection,
      );
      if (p == null || m == null) continue;
      jacobian[i * 6 + axis] = (p.u - m.u) / (2 * h);
      jacobian[i * 6 + 3 + axis] = (p.v - m.v) / (2 * h);
    }
  }
  return (jacobian: jacobian, residual: residual);
}

/// `JᵀJ` and `Jᵀr` for the 3-parameter normal equations.
({List<double> matrix, List<double> gradient}) _normalEquations(
  List<double> jacobian,
  List<double> residual,
) {
  final matrix = List<double>.filled(9, 0);
  final gradient = List<double>.filled(3, 0);
  final rows = jacobian.length ~/ 6;
  for (var i = 0; i < rows; i++) {
    final o = i * 6;
    final ru = residual[i * 2];
    final rv = residual[i * 2 + 1];
    for (var a = 0; a < 3; a++) {
      final jaU = jacobian[o + a];
      final jaV = jacobian[o + 3 + a];
      gradient[a] += jaU * ru + jaV * rv;
      for (var b = 0; b < 3; b++) {
        matrix[a * 3 + b] += jaU * jacobian[o + b] + jaV * jacobian[o + 3 + b];
      }
    }
  }
  return (matrix: matrix, gradient: gradient);
}

/// Solves a 3×3 system by Cramer's rule, or returns `null` when it is singular.
///
/// Cramer rather than an LU decomposition because the system is 3×3 and this
/// keeps the failure case explicit: a degenerate correspondence set produces a
/// near-singular matrix, and returning `null` makes the caller keep the prior
/// instead of applying a wild step.
List<double>? _solve3x3(List<double> m, List<double> rhs) {
  double det3(
    double a,
    double b,
    double c,
    double d,
    double e,
    double f,
    double g,
    double h,
    double i,
  ) => a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);

  final det = det3(
    m[0], m[1], m[2], //
    m[3], m[4], m[5], //
    m[6], m[7], m[8], //
  );
  if (det.abs() < 1e-12) return null;
  final x =
      det3(
        rhs[0], m[1], m[2], //
        rhs[1], m[4], m[5], //
        rhs[2], m[7], m[8], //
      ) /
      det;
  final y =
      det3(
        m[0], rhs[0], m[2], //
        m[3], rhs[1], m[5], //
        m[6], rhs[2], m[8], //
      ) /
      det;
  final z =
      det3(
        m[0], m[1], rhs[0], //
        m[3], m[4], rhs[1], //
        m[6], m[7], rhs[2], //
      ) /
      det;
  return <double>[x, y, z];
}
