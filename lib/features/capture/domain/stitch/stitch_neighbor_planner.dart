import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Chooses which already-captured photographs a new capture should be matched
/// against, from the station's target geometry alone.
///
/// The rule is the same one [StitchValidator] uses for its pre-stitch
/// readiness check — two rectilinear frames share content when the angular
/// distance between their centres is smaller than the reach of the first
/// frustum toward the second plus the reach of the second toward the first,
/// with a 0.9 margin — so "expected visual overlap" here means the same thing
/// it means everywhere else in the app. Both horizontal (ring) and vertical
/// (ring↔pole) overlap come out of the same bearing-aware extent function;
/// a yaw-only test would wrongly reject the zenith.
///
/// The planner only *predicts*. Whether two photographs really share features
/// is decided by the worker's feature matching — a textureless wall defeats
/// this plan exactly as the validator's documentation says it can.
class PlannedNeighbor {
  final int targetId;

  /// Great-circle angle to the new target, in degrees.
  final double angleDeg;

  /// The combined frustum reach that qualified this pair, in degrees —
  /// `0.9 × (extent(new→other) + extent(other→new))`.
  final double qualifiedBelowDeg;

  const PlannedNeighbor({
    required this.targetId,
    required this.angleDeg,
    required this.qualifiedBelowDeg,
  });
}

class StitchNeighborPlanner {
  /// Portrait display FOV defaults, matching
  /// [ArCameraIntrinsics.fallbackDisplayFov] — the same provisional pair the
  /// guidance projects with before real intrinsics arrive.
  final double hfovDeg;
  final double vfovDeg;

  /// Candidates are sorted nearest-first and cut at this count, so one job
  /// never matches against the whole station.
  final int maxCandidates;

  /// Margin applied to the combined frustum reach, mirroring
  /// [StitchValidator.maxNeighbourFractionOfFov].
  final double overlapFactor;

  const StitchNeighborPlanner({
    this.hfovDeg = 53.7,
    this.vfovDeg = 68.0,
    this.maxCandidates = 3,
    this.overlapFactor = 0.9,
  });

  /// Previously captured targets with expected visual overlap for
  /// [forTarget], nearest first.
  ///
  /// [capturedIds] is authoritative — a planned neighbour whose photograph
  /// does not exist is never returned, so the worker only ever receives files
  /// that were saved.
  List<PlannedNeighbor> plan({
    required CaptureTargetSpec forTarget,
    required List<CaptureTargetSpec> allSpecs,
    required Set<int> capturedIds,
  }) {
    final result = <PlannedNeighbor>[];
    for (final spec in allSpecs) {
      if (spec.targetId == forTarget.targetId) continue;
      if (!capturedIds.contains(spec.targetId)) continue;
      final angle = _geodesicDeg(forTarget, spec);
      final reach =
          overlapFactor *
          (_halfExtentDeg(forTarget, spec) + _halfExtentDeg(spec, forTarget));
      if (angle <= reach) {
        result.add(
          PlannedNeighbor(
            targetId: spec.targetId,
            angleDeg: angle,
            qualifiedBelowDeg: reach,
          ),
        );
      }
    }
    result.sort(
      (PlannedNeighbor a, PlannedNeighbor b) =>
          a.angleDeg.compareTo(b.angleDeg),
    );
    if (result.length > maxCandidates) {
      return result.sublist(0, maxCandidates);
    }
    return result;
  }

  /// Great-circle angle between two target directions, in degrees.
  ///
  /// `direction` is a unit vector in station-local coordinates, so the dot
  /// product is the cosine directly — no yaw wrap-around to handle, and the
  /// poles are correct by construction.
  static double _geodesicDeg(CaptureTargetSpec a, CaptureTargetSpec b) {
    final d = a.direction.x * b.direction.x +
        a.direction.y * b.direction.y +
        a.direction.z * b.direction.z;
    final c = d.clamp(-1.0, 1.0);
    return math.acos(c) * 180 / math.pi;
  }

  /// How far off-axis the centre of [to] can sit and still fall inside
  /// [from]'s rectilinear frustum, in degrees.
  ///
  /// A frustum is a rectangle in tangent space — half-width
  /// `tan(hfov/2)`, half-height `tan(vfov/2)` — and a ray leaving the centre
  /// at bearing θ meets whichever edge it reaches first, so the reach is
  /// `min(halfW/|cos θ|, halfH/|sin θ|)`.
  double _halfExtentDeg(CaptureTargetSpec from, CaptureTargetSpec to) {
    final basis = _orthonormalBasis(from.direction);
    final d = to.direction;
    final right = d.x * basis.$1.x + d.y * basis.$1.y + d.z * basis.$1.z;
    final up = d.x * basis.$2.x + d.y * basis.$2.y + d.z * basis.$2.z;
    final bearing = math.atan2(up, right);
    final halfW = math.tan(hfovDeg * math.pi / 360);
    final halfH = math.tan(vfovDeg * math.pi / 360);
    final c = math.cos(bearing).abs();
    final s = math.sin(bearing).abs();
    final r = math.min(
      c < 1e-12 ? double.infinity : halfW / c,
      s < 1e-12 ? double.infinity : halfH / s,
    );
    return math.atan(r) * 180 / math.pi;
  }

  /// Screen-right and screen-up unit vectors for a target direction, with the
  /// world reference chosen so both are always defined — including at the
  /// poles, where a fixed up axis would collapse.
  static (Vec3, Vec3) _orthonormalBasis(Vec3 forward) {
    // A reference not parallel to `forward`: world up unless the target is a
    // pole, in which case world forward.
    final ref = forward.z.abs() > 0.99 ? const Vec3(0, 0, -1) : const Vec3(0, 1, 0);
    // right = normalize(cross(ref, forward)) — sign does not matter for a
    // magnitude-only extent, but the basis must stay orthogonal.
    var rx = ref.y * forward.z - ref.z * forward.y;
    var ry = ref.z * forward.x - ref.x * forward.z;
    var rz = ref.x * forward.y - ref.y * forward.x;
    final rl = math.sqrt(rx * rx + ry * ry + rz * rz);
    if (rl < 1e-9) {
      rx = 1;
      ry = 0;
      rz = 0;
    } else {
      rx /= rl;
      ry /= rl;
      rz /= rl;
    }
    // up = cross(forward, right)
    final ux = forward.y * rz - forward.z * ry;
    final uy = forward.z * rx - forward.x * rz;
    final uz = forward.x * ry - forward.y * rx;
    return (Vec3(rx, ry, rz), Vec3(ux, uy, uz));
  }
}
