import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_intrinsics.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_registration.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';

/// One frame as the registration needs it: where its photograph is, where the
/// sensor thinks it was pointing, and enough metadata to derive its intrinsics.
///
/// Deliberately a plain value type rather than the capture record map. The
/// registration runs on a background isolate and must not depend on the shape of
/// `records.json` beyond what the caller has already parsed out of it.
class SphereRegistrationFrame {
  const SphereRegistrationFrame({
    required this.targetId,
    required this.imagePath,
    required this.rotation,
    required this.savedWidth,
    required this.savedHeight,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.cropOffsetX,
    required this.cropOffsetY,
  });

  final int targetId;
  final String imagePath;

  /// Camera→world, the recorded `cameraOrientation`. The prior, never replaced.
  final Quat rotation;

  final int savedWidth;
  final int savedHeight;
  final int sourceWidth;
  final int sourceHeight;
  final int cropOffsetX;
  final int cropOffsetY;
}


/// SITEWISE_OBJECT_INTEGRITY_V1: bounded image-space affine residual from
/// geometrically checked ORB matches after quaternion registration. All
/// coefficients are fractions of the decoded width/height, so a correction
/// estimated at quarter resolution scales correctly during final composition.
/// The source JPEGs are NEVER rewritten or replaced.
class SphereResidualAffine {
  const SphereResidualAffine({
    this.du0 = 0, this.duX = 0, this.duY = 0,
    this.dv0 = 0, this.dvX = 0, this.dvY = 0,
  });

  static const SphereResidualAffine identity = SphereResidualAffine();
  final double du0, duX, duY, dv0, dvX, dvY;

  /// The warp is strongest in the overlap/periphery and fades towards image
  /// centre, where altering pixels would only bend already-aligned objects.
  /// Maximum displacement per axis is 35 pixels in the composition decode.
  ({double du, double dv}) shiftAt({
    required double u,
    required double v,
    required int width,
    required int height,
    double maxPx = 35.0,
  }) {
    if (width < 1 || height < 1) return (du: 0.0, dv: 0.0);
    final nx = 2.0 * u / width - 1.0;
    final ny = 2.0 * v / height - 1.0;
    final radius = math.max(nx.abs(), ny.abs());
    final t = ((radius - 0.15) / 0.75).clamp(0.0, 1.0).toDouble();
    final peripheral = t * t * (3.0 - 2.0 * t);
    final du = (du0 + duX * nx + duY * ny) * width * peripheral;
    final dv = (dv0 + dvX * nx + dvY * ny) * height * peripheral;
    return (
      du: du.clamp(-maxPx, maxPx).toDouble(),
      dv: dv.clamp(-maxPx, maxPx).toDouble(),
    );
  }
}

class _ResidualPoint {
  const _ResidualPoint(this.x, this.y, this.du, this.dv);
  final double x, y, du, dv; // x/y normalized, du/dv in registration pixels
}

/// Robust pairwise affine fit. Only an already-aligned, earlier neighbour
/// may provide correspondences. Large or inconsistent parallax is rejected,
/// rather than blindly forcing an affine model onto objects at different depths.
SphereResidualAffine _fitResidualAffine(
  List<_ResidualPoint> points,
  DecodedProjection projection,
) {
  if (points.length < 24) return SphereResidualAffine.identity;
  final us = <double>[for (final p in points) p.du]..sort();
  final vs = <double>[for (final p in points) p.dv]..sort();
  final medianU = us[us.length ~/ 2];
  final medianV = vs[vs.length ~/ 2];
  // At this stage the rotation should have resolved gross alignment. Accept
  // only spatially coherent residuals; close-object parallax can exceed this.
  final coherent = <_ResidualPoint>[
    for (final p in points)
      if ((p.du - medianU).abs() <= 6.0 &&
          (p.dv - medianV).abs() <= 6.0)
        p,
  ];
  if (coherent.length < 24 || coherent.length < points.length * 0.60) {
    return SphereResidualAffine.identity;
  }

  // Coordinates are normalized to prevent 4x decode reduction from changing
  // fitted rotation/shear. Regularize slope terms to avoid overfitting a
  // tiny cluster of ORB points on one nearby chair/door.
  final normal = List<double>.filled(9, 0);
  final rhsU = List<double>.filled(3, 0);
  final rhsV = List<double>.filled(3, 0);
  for (final p in coherent) {
    final a = <double>[1.0, p.x, p.y];
    for (var r = 0; r < 3; r++) {
      rhsU[r] += a[r] * p.du / projection.width;
      rhsV[r] += a[r] * p.dv / projection.height;
      for (var c = 0; c < 3; c++) {
        normal[r * 3 + c] += a[r] * a[c];
      }
    }
  }
  normal[0] += 0.01;
  normal[4] += 8.0;
  normal[8] += 8.0;
  final u = _solveAffine3(normal, rhsU);
  final v = _solveAffine3(normal, rhsV);
  if (u == null || v == null) return SphereResidualAffine.identity;
  final fitted = SphereResidualAffine(
    du0: u[0], duX: u[1], duY: u[2],
    dv0: v[0], dvX: v[1], dvY: v[2],
  );
  var before = 0.0;
  var after = 0.0;
  for (final p in coherent) {
    final targetDu = (u[0] + u[1] * p.x + u[2] * p.y) * projection.width;
    final targetDv = (v[0] + v[1] * p.x + v[2] * p.y) * projection.height;
    before += math.sqrt(p.du * p.du + p.dv * p.dv);
    after += math.sqrt(math.pow(p.du - targetDu, 2) +
        math.pow(p.dv - targetDv, 2));
  }
  // Discard insignificant or contradictory adjustments. A 35px clamp is an
  // emergency bound, NOT a licence to accept arbitrary projective distortion.
  if (before < 0.5 * coherent.length || after >= 0.85 * before) {
    return SphereResidualAffine.identity;
  }
  if ((u[0] * projection.width).abs() > 25 ||
      (v[0] * projection.height).abs() > 25 ||
      u[1].abs() > 0.018 || u[2].abs() > 0.018 ||
      v[1].abs() > 0.018 || v[2].abs() > 0.018) {
    return SphereResidualAffine.identity;
  }
  return fitted;
}

/// Minimal, pivoted Gaussian elimination for the two 3x3 affine fits.
List<double>? _solveAffine3(List<double> coefficients, List<double> rhs) {
  final a = List<double>.of(coefficients);
  final b = List<double>.of(rhs);
  for (var k = 0; k < 3; k++) {
    var pivot = k;
    for (var row = k + 1; row < 3; row++) {
      if (a[row * 3 + k].abs() > a[pivot * 3 + k].abs()) pivot = row;
    }
    if (a[pivot * 3 + k].abs() < 1e-10) return null;
    if (pivot != k) {
      for (var col = 0; col < 3; col++) {
        final temp = a[k * 3 + col];
        a[k * 3 + col] = a[pivot * 3 + col];
        a[pivot * 3 + col] = temp;
      }
      final temp = b[k];
      b[k] = b[pivot];
      b[pivot] = temp;
    }
    for (var row = k + 1; row < 3; row++) {
      final ratio = a[row * 3 + k] / a[k * 3 + k];
      for (var col = k; col < 3; col++) {
        a[row * 3 + col] -= ratio * a[k * 3 + col];
      }
      b[row] -= ratio * b[k];
    }
  }
  final solution = List<double>.filled(3, 0);
  for (var row = 2; row >= 0; row--) {
    var total = b[row];
    for (var col = row + 1; col < 3; col++) {
      total -= a[row * 3 + col] * solution[col];
    }
    solution[row] = total / a[row * 3 + row];
    if (!solution[row].isFinite) return null;
  }
  return solution;
}

/// What the registration produced.
///
/// [rotations] is index-aligned with the input list. A frame with no trustworthy
/// neighbour keeps its recorded quaternion, so this is always safe to project —
/// there is no "registration failed, give up" state, which matters because the
/// photographs cannot be retaken.
class SphereRegistrationOutcome {
  const SphereRegistrationOutcome({
    required this.rotations,
    required this.correctionDeg,
    required this.pairsConsidered,
    required this.acceptedEdges,
    required this.rejectedEdges,
    required this.featureTotal,
    required this.elapsed,
    required this.notes,
    this.meanResidualAfterPx = 0,
    this.maxResidualAfterPx = 0,
    this.residualSamples = 0,
    this.residualAffines = const <SphereResidualAffine>[],
  });

  final List<Quat> rotations;

  /// Conservative image-space residual corrections after ORB/RANSAC rotation.
  final List<SphereResidualAffine> residualAffines;

  /// How far each frame ended up rotated from its recorded orientation, degrees.
  final List<double> correctionDeg;

  final int pairsConsidered;
  final int acceptedEdges;
  final int rejectedEdges;
  final int featureTotal;
  final Duration elapsed;

  /// A short, human-readable sample of why edges were refused. Bounded on
  /// purpose: a station where every wall is blank would otherwise produce
  /// hundreds of identical strings.
  final List<String> notes;

  /// Mean reprojection error, in pixels, of the *accepted* edges after their
  /// rotation correction was applied.
  ///
  /// This is the number that says whether the alignment actually worked: a
  /// well-registered station sits around a pixel, and a value of several pixels
  /// means the photographs disagree about structure even where RANSAC found
  /// enough inliers to accept the pair. It is reported next to the coverage
  /// numbers because coverage can be perfect while the alignment is poor.
  final double meanResidualAfterPx;

  /// Worst accepted edge's reprojection error, in pixels.
  final double maxResidualAfterPx;

  /// How many accepted edges those figures are averaged over.
  final int residualSamples;

  /// The identity outcome — every frame keeps the quaternion the sensor
  /// recorded. Returned when registration is switched off, and used as the
  /// fallback when nothing could be read at all.
  static SphereRegistrationOutcome unrefined(
    List<SphereRegistrationFrame> frames, {
    String? note,
  }) => SphereRegistrationOutcome(
    rotations: <Quat>[for (final f in frames) f.rotation],
    correctionDeg: List<double>.filled(frames.length, 0),
    pairsConsidered: 0,
    acceptedEdges: 0,
    rejectedEdges: 0,
    featureTotal: 0,
    elapsed: Duration.zero,
    notes: <String>[?note],
  );
}

/// The reduced decode used for feature detection.
///
/// Feature detection does not need 12 megapixels — ORB finds the same corners in
/// a quarter-scale decode, and the decode itself is the expensive part. The final
/// compositing decodes at a different reduction (see the stitcher), so sharpness
/// is not decided here: this only decides *where* each frame points.
const int kSphereRegistrationDecodeReduction = cv.IMREAD_REDUCED_COLOR_4;

/// Features per frame. 2000 (raised from 1200) gives low-texture indoor walls
/// enough surviving matches after the ratio test for the rotation solve to
/// bite — the fallback when the feature-based Stitcher refuses a station.
/// 38 frames of descriptors stay under ~4 MB.
const int kSphereRegistrationFeatures = 2500;

/// Lowe's ratio. Above this the match is ambiguous and is dropped rather than
/// left for RANSAC to sort out — RANSAC is good at rejecting outliers, not at
/// rejecting matches that are wrong by a consistent amount.
const double kSphereRegistrationRatio = 0.75;

/// RANSAC reprojection tolerance, in registration pixels.
const double kSphereRegistrationRansacPx = 4.0;

/// Neighbours matched per frame. The layout's rings are 30–35° apart, so five
/// neighbours covers both rings plus the ring above and below without ever
/// matching a frame against the far side of the room.
const int kSphereRegistrationNeighboursPerFrame = 5;

/// Correspondences kept per pair. The estimate converges long before this; the
/// cap exists so one unusually textured pair cannot dominate the station's total
/// runtime.
const int kSphereRegistrationMaxCorrespondences = 320;

/// How many averaging sweeps run after the sequential pass.
const int kSphereRegistrationAveragingPasses = 2;

/// The correspondences one neighbour pair produced, cached so that refining a
/// frame does not require matching it again.
///
/// This is the single most important performance decision in the file. Matching
/// is the expensive half — a brute-force Hamming knn over ~1200 descriptors per
/// side — while the rotation solve is arithmetic over at most
/// [kSphereRegistrationMaxCorrespondences] points. Registration runs the solve
/// several times per pair (once sequentially, then once per averaging sweep), and
/// re-matching each time would multiply the station's cost by that count for
/// exactly the same answer.
class _PairMatches {
  const _PairMatches({required this.points, required this.featureMatches});

  /// Coordinates as `(first, second)` — the pair's lower index first.
  final List<SphereCorrespondence> points;

  /// How many unambiguous matches existed before RANSAC, for the inlier ratio.
  final int featureMatches;

  /// The same matches oriented for a solve that treats `second` as the frame
  /// being corrected.
  List<SphereCorrespondence> reversed() => <SphereCorrespondence>[
    for (final SphereCorrespondence c in points)
      SphereCorrespondence(
        frameU: c.neighbourU,
        frameV: c.neighbourV,
        neighbourU: c.frameU,
        neighbourV: c.frameV,
      ),
  ];
}

/// Refines every frame's orientation against the photographs that overlap it.
///
/// ## Order of work, and why
///
/// 1. **Decode once per frame, at quarter scale, and keep only descriptors.**
///    Descriptors are reused across every pairing that frame takes part in. The
///    incremental worker in `features/capture` re-decodes and re-detects the
///    candidate image for every attempt, which is the difference between 38
///    decodes and several hundred.
/// 2. **Match neighbours only, once per pair.** Pairs come from the recorded
///    quaternions, so the pair list is a property of the capture geometry rather
///    than of the pixels — which is what keeps a repeated texture on two
///    unrelated walls from ever being compared.
/// 3. **RANSAC, then a rotation solve.** `findHomography` is used purely as an
///    outlier filter: its inlier mask says which matches are geometrically
///    consistent. The rotation itself is solved in
///    [refineRotationFromCorrespondences] against the stitcher's own projection,
///    so no homography is decomposed and no camera convention can be inverted.
/// 4. **Sequential pass, then averaging.** See the note at step 3 in the body:
///    correcting both sides of a pair from their priors doubles the error it is
///    meant to remove.
///
/// A frame that fails at any step keeps its recorded quaternion. That is the
/// low-texture path, and it is the common one: a blank wall produces no corners,
/// so the sensor estimate is the best information available and is used as-is.
SphereRegistrationOutcome registerSphereFrames({
  required List<SphereRegistrationFrame> frames,
  required double verticalFovDeg,
  void Function(String stage)? onStage,
}) {
  if (frames.length < 2) {
    return SphereRegistrationOutcome.unrefined(
      frames,
      note: 'A single photograph has nothing to register against.',
    );
  }
  final stopwatch = Stopwatch()..start();

  // ── 1. One decode, one detection, per frame ──────────────────────────
  final descriptors = List<cv.Mat?>.filled(frames.length, null);
  final keypoints = List<Float32List?>.filled(frames.length, null);
  final projections = List<DecodedProjection?>.filled(frames.length, null);
  final usable = List<bool>.filled(frames.length, false);
  var featureTotal = 0;

  cv.ORB? orb;
  try {
    orb = cv.ORB.create(nFeatures: kSphereRegistrationFeatures);
    for (var i = 0; i < frames.length; i++) {
      final frame = frames[i];
      onStage?.call('Checking overlap: photograph ${i + 1}/${frames.length}…');
      if (!File(frame.imagePath).existsSync()) continue;
      cv.Mat? colour;
      cv.Mat? gray;
      try {
        colour = cv.imread(
          frame.imagePath,
          flags: kSphereRegistrationDecodeReduction,
        );
        if (colour.isEmpty) continue;
        gray = cv.cvtColor(colour, cv.COLOR_BGR2GRAY);
        // Intrinsics for exactly this decode, from the same transform the
        // projection uses — so a correspondence's pixels and its focal length
        // are always in the same coordinate system.
        final projection = decodedProjection(
          decodedWidth: gray.cols,
          decodedHeight: gray.rows,
          savedWidth: frame.savedWidth,
          savedHeight: frame.savedHeight,
          sourceWidth: frame.sourceWidth,
          sourceHeight: frame.sourceHeight,
          verticalFovDeg: verticalFovDeg,
          cropOffsetX: frame.cropOffsetX,
          cropOffsetY: frame.cropOffsetY,
        );
        if (projection == null) continue;
        projections[i] = projection;

        final (detected, description) = orb.detectAndCompute(
          gray,
          cv.Mat.empty(),
        );
        final detectedCount = detected.length;
        if (detectedCount < kSphereRegistrationMinInliers ||
            description.isEmpty) {
          detected.dispose();
          description.dispose();
          continue;
        }
        final points = Float32List(detectedCount * 2);
        for (var k = 0; k < detectedCount; k++) {
          points[k * 2] = detected[k].x;
          points[k * 2 + 1] = detected[k].y;
        }
        detected.dispose();
        descriptors[i] = description;
        keypoints[i] = points;
        featureTotal += detectedCount;
        usable[i] = true;
      } finally {
        gray?.dispose();
        colour?.dispose();
      }
    }

    // ── 2. Neighbour pairs, from the recorded orientations ─────────────
    final pairs = _neighbourPairs(frames);
    onStage?.call(
      'Matching ${pairs.length} overlapping pairs '
      '(${frames.length} photographs)…',
    );

    // ── 3a. Match each pair exactly once ──────────────────────────────
    final matches = List<_PairMatches?>.filled(pairs.length, null);
    cv.BFMatcher? matcher;
    try {
      matcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);
      for (var p = 0; p < pairs.length; p++) {
        final (i, j) = pairs[p];
        if (!usable[i] || !usable[j]) continue;
        matches[p] = _matchPair(
          first: i,
          second: j,
          descriptors: descriptors,
          keypoints: keypoints,
          matcher: matcher,
        );
        if (p % 8 == 0) {
          onStage?.call(
            'Matching overlaps: ${p + 1}/${pairs.length} pairs '
            '(${stopwatch.elapsed.inSeconds}s elapsed)…',
          );
        }
      }
    } finally {
      matcher?.dispose();
    }

    // ── 3b. Refine, then average ──────────────────────────────────────
    //
    // **Sequential first.** Frames are visited in capture order and each is
    // refined against neighbours that have *already* been refined. Refining both
    // sides of a pair from their priors looks symmetric and is not: the matches
    // measure the relative error *between* the two frames, so handing the whole
    // of it to each side in turn doubles it, in opposite directions, and the seam
    // ends up worse than it started. Anchoring each frame to an already-corrected
    // neighbour assigns that relative error once.
    //
    // **Then averaging.** Every frame is re-refined against all its now-refined
    // neighbours from a frozen snapshot, and the proposals are averaged before
    // anything is applied. That removes the drift the sequential pass accumulates
    // along the chain, and freezing the snapshot means no frame is corrected
    // twice from the same measurement.
    var accepted = 0;
    var rejected = 0;
    // Residuals of the edges that were accepted, so the caller can report how
    // well the alignment actually fits rather than only how many pairs passed.
    var residualSum = 0.0;
    var residualCount = 0;
    var residualMax = 0.0;

    void noteResidual(SphereEdgeRefinement refinement) {
      final value = refinement.residualAfterPx;
      if (!value.isFinite || value < 0) return;
      residualSum += value;
      residualCount++;
      if (value > residualMax) residualMax = value;
    }

    final notes = <String>[];
    final rotations = <Quat>[for (final f in frames) f.rotation];
    final settled = List<bool>.filled(frames.length, false);

    final neighbours = List<List<int>>.generate(frames.length, (_) => <int>[]);
    for (var p = 0; p < pairs.length; p++) {
      if (matches[p] == null) continue;
      neighbours[pairs[p].$1].add(p);
      neighbours[pairs[p].$2].add(p);
    }

    SphereEdgeRefinement refine(int subject, int pairIndex) {
      final cached = matches[pairIndex];
      if (cached == null) return SphereEdgeRefinement.none;
      final firstIsSubject = pairs[pairIndex].$1 == subject;
      final reference = firstIsSubject
          ? pairs[pairIndex].$2
          : pairs[pairIndex].$1;
      final subjectProjection = projections[subject];
      final referenceProjection = projections[reference];
      if (subjectProjection == null || referenceProjection == null) {
        return SphereEdgeRefinement.none;
      }
      return refineRotationFromCorrespondences(
        frameRotation: rotations[subject],
        neighbourRotation: rotations[reference],
        frameProjection: subjectProjection,
        neighbourProjection: referenceProjection,
        correspondences: firstIsSubject ? cached.points : cached.reversed(),
        featureMatches: cached.featureMatches,
      );
    }

    void tally(SphereEdgeRefinement refinement, int targetId) {
      if (refinement.accepted) {
        accepted++;
        noteResidual(refinement);
        return;
      }
      rejected++;
      if (notes.length < 6 && refinement.rejection != null) {
        notes.add('Frame $targetId: ${refinement.rejection}');
      }
    }

    // The anchor defines the sphere's origin and is never moved: correcting it
    // would rotate the entire panorama for no gain, since only relative
    // orientation affects the seams.
    if (frames.isNotEmpty) settled[0] = true;
    for (var i = 1; i < frames.length; i++) {
      if (!usable[i]) {
        settled[i] = true;
        continue;
      }
      final proposals = <SphereEdgeRefinement>[];
      for (final pairIndex in neighbours[i]) {
        final other = pairs[pairIndex].$1 == i
            ? pairs[pairIndex].$2
            : pairs[pairIndex].$1;
        if (!settled[other]) continue;
        final refinement = refine(i, pairIndex);
        tally(refinement, frames[i].targetId);
        proposals.add(refinement);
      }
      final correction = mergeSphereCorrections(proposals);
      if (correction != null) {
        rotations[i] = (correction * rotations[i]).normalized;
      }
      settled[i] = true;
      if (i % 6 == 0) {
        onStage?.call('Refining orientations: ${i + 1}/${frames.length}…');
      }
    }

    for (var pass = 0; pass < kSphereRegistrationAveragingPasses; pass++) {
      final snapshot = List<Quat>.of(rotations);
      final updates = List<Quat?>.filled(frames.length, null);
      for (var i = 1; i < frames.length; i++) {
        if (!usable[i]) continue;
        final proposals = <SphereEdgeRefinement>[];
        for (final pairIndex in neighbours[i]) {
          final refinement = refine(i, pairIndex);
          if (refinement.accepted) {
            accepted++;
            noteResidual(refinement);
          } else {
            rejected++;
          }
          proposals.add(refinement);
        }
        updates[i] = mergeSphereCorrections(proposals);
      }
      // Applied only after every frame has been measured, so the sweep is a
      // Jacobi step and not a half-updated mixture of old and new rotations.
      for (var i = 1; i < frames.length; i++) {
        final update = updates[i];
        if (update == null) continue;
        rotations[i] = (update * snapshot[i]).normalized;
      }
      onStage?.call(
        'Averaging orientations: sweep ${pass + 1}/'
        '$kSphereRegistrationAveragingPasses…',
      );
    }

    // SITEWISE_OBJECT_INTEGRITY_V1: residual affine alignment AFTER rotation.
    // Estimate a small warp from already-RANSAC-checked ORB correspondences.
    // Every frame is referenced against an earlier trusted neighbour, not
    // a continually changing composited image. Inconsistent close parallax
    // is deliberately left to the edge-avoiding seam, not warped aggressively.
    final residualAffines = List<SphereResidualAffine>.filled(
      frames.length, SphereResidualAffine.identity,
    );
    for (var i = 1; i < frames.length; i++) {
      if (!usable[i] || projections[i] == null) continue;
      var chosen = -1;
      var reference = -1;
      var largestInliers = 0;
      for (final p in neighbours[i]) {
        final other = pairs[p].$1 == i ? pairs[p].$2 : pairs[p].$1;
        final candidate = matches[p];
        if (other >= i || projections[other] == null || candidate == null ||
            candidate.points.length < 24) {
          continue;
        }
        if (candidate.points.length > largestInliers) {
          largestInliers = candidate.points.length;
          chosen = p;
          reference = other;
        }
      }
      if (chosen < 0) continue;
      final subjectProjection = projections[i]!;
      final neighbourProjection = projections[reference]!;
      final cached = matches[chosen]!;
      final subjectFirst = pairs[chosen].$1 == i;
      final correspondences = subjectFirst ? cached.points : cached.reversed();
      final observations = <_ResidualPoint>[];
      for (final c in correspondences) {
        // Include the earlier frame's accepted residual displacement when
        // constructing the reference world ray. A match still points to the
        // exact original image pixel, so compensate for the previous warp.
        final referenceShift = residualAffines[reference].shiftAt(
          u: c.neighbourU, v: c.neighbourV,
          width: neighbourProjection.width,
          height: neighbourProjection.height,
        );
        final world = rotations[reference].rotate(unprojectPixel(
          c.neighbourU - referenceShift.du,
          c.neighbourV - referenceShift.dv,
          neighbourProjection,
        ));
        final predicted = projectCameraRay(
          rotations[i].conjugate.rotate(world),
          subjectProjection,
        );
        if (predicted == null) continue;
        final du = c.frameU - predicted.u;
        final dv = c.frameV - predicted.v;
        if (!du.isFinite || !dv.isFinite || du.abs() > 40 || dv.abs() > 40) {
          continue;
        }
        observations.add(_ResidualPoint(
          2 * c.frameU / subjectProjection.width - 1,
          2 * c.frameV / subjectProjection.height - 1,
          du, dv,
        ));
      }
      residualAffines[i] = _fitResidualAffine(
        observations, subjectProjection,
      );
    }

    // ── 4. Report, keeping the prior wherever nothing was proven ───────
    final correctionDeg = List<double>.filled(frames.length, 0);
    var refinedFrames = 0;
    for (var i = 0; i < frames.length; i++) {
      correctionDeg[i] = sphereOrientationGapDeg(
        frames[i].rotation,
        rotations[i],
      );
      if (correctionDeg[i] > 0) refinedFrames++;
    }
    if (refinedFrames == 0) {
      notes.add(
        'No frame had a trustworthy overlap, so every photograph keeps its '
        'recorded orientation.',
      );
    }

    return SphereRegistrationOutcome(
      rotations: rotations,
      residualAffines: residualAffines,
      correctionDeg: correctionDeg,
      pairsConsidered: pairs.length,
      acceptedEdges: accepted,
      rejectedEdges: rejected,
      featureTotal: featureTotal,
      elapsed: stopwatch.elapsed,
      notes: notes,
      meanResidualAfterPx: residualCount == 0 ? 0 : residualSum / residualCount,
      maxResidualAfterPx: residualMax,
      residualSamples: residualCount,
    );
  } finally {
    orb?.dispose();
    for (final cv.Mat? d in descriptors) {
      d?.dispose();
    }
  }
}

/// The overlapping frame pairs, nearest first, capped per frame.
///
/// Built from the recorded quaternions rather than from the pixels, so the cost
/// of registration is decided before a single feature is computed. Pairs are
/// sorted by angular distance and taken greedily, which keeps every frame's five
/// closest neighbours and drops the rest.
List<(int, int)> _neighbourPairs(List<SphereRegistrationFrame> frames) {
  final candidates = <(int, int, double)>[];
  for (var i = 0; i < frames.length; i++) {
    for (var j = i + 1; j < frames.length; j++) {
      final gap = sphereOrientationGapDeg(
        frames[i].rotation,
        frames[j].rotation,
      );
      if (gap > kSphereRegistrationNeighbourDeg) continue;
      candidates.add((i, j, gap));
    }
  }
  candidates.sort((a, b) => a.$3.compareTo(b.$3));

  final perFrame = List<int>.filled(frames.length, 0);
  final pairs = <(int, int)>[];
  for (final (i, j, _) in candidates) {
    if (perFrame[i] >= kSphereRegistrationNeighboursPerFrame) continue;
    if (perFrame[j] >= kSphereRegistrationNeighboursPerFrame) continue;
    perFrame[i]++;
    perFrame[j]++;
    pairs.add((i, j));
  }
  return pairs;
}

/// One neighbour pair: knn match, ratio test, RANSAC, correspondences.
///
/// Every OpenCV object created here is released here. A station is 38 frames and
/// a few hundred pairs, and leaking a `Mat` per pair would exhaust a phone long
/// before the last frame.
_PairMatches? _matchPair({
  required int first,
  required int second,
  required List<cv.Mat?> descriptors,
  required List<Float32List?> keypoints,
  required cv.BFMatcher matcher,
}) {
  final firstDescriptors = descriptors[first];
  final secondDescriptors = descriptors[second];
  final firstPoints = keypoints[first];
  final secondPoints = keypoints[second];
  if (firstDescriptors == null ||
      secondDescriptors == null ||
      firstPoints == null ||
      secondPoints == null) {
    return null;
  }

  cv.VecPoint2f? sourcePoints;
  cv.VecPoint2f? destinationPoints;
  cv.Mat? sourceMat;
  cv.Mat? destinationMat;
  cv.Mat? homography;
  cv.Mat? mask;
  try {
    final knn = matcher.knnMatch(firstDescriptors, secondDescriptors, 2);
    final kept = <(int, int)>[];
    for (final row in knn) {
      if (row.length < 2) continue;
      final best = row[0];
      final runnerUp = row[1];
      if (best.distance < kSphereRegistrationRatio * runnerUp.distance) {
        kept.add((best.queryIdx, best.trainIdx));
      }
    }
    if (kept.length < kSphereRegistrationMinInliers) {
      // Still returned rather than dropped: "only 4 matches" is the diagnostic a
      // blank wall produces, and the caller reports it.
      return _PairMatches(
        points: const <SphereCorrespondence>[],
        featureMatches: kept.length,
      );
    }

    final srcList = <cv.Point2f>[];
    final dstList = <cv.Point2f>[];
    for (final (queryIndex, trainIndex) in kept) {
      srcList.add(
        cv.Point2f(
          firstPoints[queryIndex * 2],
          firstPoints[queryIndex * 2 + 1],
        ),
      );
      dstList.add(
        cv.Point2f(
          secondPoints[trainIndex * 2],
          secondPoints[trainIndex * 2 + 1],
        ),
      );
    }
    sourcePoints = cv.VecPoint2f.fromList(srcList);
    destinationPoints = cv.VecPoint2f.fromList(dstList);
    sourceMat = cv.Mat.fromVec(sourcePoints);
    destinationMat = cv.Mat.fromVec(destinationPoints);
    mask = cv.Mat.empty();
    // Only the inlier mask is used. The homography itself is discarded: the
    // rotation is solved against the projection, never decomposed from `H`.
    homography = cv.findHomography(
      sourceMat,
      destinationMat,
      method: cv.RANSAC,
      ransacReprojThreshold: kSphereRegistrationRansacPx,
      mask: mask,
    );
    if (homography.isEmpty) {
      return _PairMatches(
        points: const <SphereCorrespondence>[],
        featureMatches: kept.length,
      );
    }

    final points = <SphereCorrespondence>[];
    for (var i = 0; i < kept.length; i++) {
      if (mask.atU8(i) == 0) continue;
      if (points.length >= kSphereRegistrationMaxCorrespondences) break;
      points.add(
        SphereCorrespondence(
          frameU: srcList[i].x,
          frameV: srcList[i].y,
          neighbourU: dstList[i].x,
          neighbourV: dstList[i].y,
        ),
      );
    }
    return _PairMatches(points: points, featureMatches: kept.length);
  } catch (_) {
    return null;
  } finally {
    homography?.dispose();
    mask?.dispose();
    sourceMat?.dispose();
    destinationMat?.dispose();
    sourcePoints?.dispose();
    destinationPoints?.dispose();
  }
}

/// The largest correction applied to any frame, in degrees — a single number for
/// the coverage report and the progress log.
double maxCorrectionDeg(List<double> corrections) {
  var worst = 0.0;
  for (final c in corrections) {
    worst = math.max(worst, c);
  }
  return worst;
}
