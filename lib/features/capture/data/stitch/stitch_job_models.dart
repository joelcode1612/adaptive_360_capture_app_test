// Job and result packets for the incremental stitching worker.
//
// These classes cross the isolate boundary between the stitch service (which
// owns the queue and the records) and the OpenCV worker (which does the
// matching). Everything in them is plain Dart data — no `Mat`, no native
// handle — because native objects are not sendable.
library;

/// One previously captured photograph the new image may match against.
class StitchCandidatePacket {
  final int targetId;
  final String imagePath;

  const StitchCandidatePacket({required this.targetId, required this.imagePath});
}

/// The work order for one saved photograph.
class StitchJobPacket {
  /// Absolute path of the newly saved JPEG.
  final String imagePath;

  /// 1-based target id of the new photograph.
  final int targetId;

  /// Directory intermediates are written to
  /// (`<station>/stitched_outputs`); created on demand by the worker.
  final String outputsDir;

  /// Candidate neighbours, nearest-first, already filtered to files that
  /// exist on disk.
  final List<StitchCandidatePacket> candidates;

  /// The images of the currently merged group, in merge order, so the worker
  /// can attempt to extend the intermediate panorama.
  final List<StitchCandidatePacket> groupImages;

  /// 1-based index for the next intermediate output name
  /// (`stitch_003.jpg` when this is 3).
  final int nextOutputIndex;

  const StitchJobPacket({
    required this.imagePath,
    required this.targetId,
    required this.outputsDir,
    required this.candidates,
    required this.groupImages,
    required this.nextOutputIndex,
  });
}

/// The measured result of matching the new image against one candidate.
class StitchAttemptResult {
  final int candidateTargetId;

  /// Good matches after the Lowe ratio test.
  final int featureMatches;

  /// RANSAC inliers — the geometrically consistent correspondences.
  final int inliers;

  /// [inliers] / [featureMatches].
  final double inlierRatio;

  /// Mean |H·p − q| over inliers, in work-image pixels.
  final double meanReprojPx;

  /// Inlier bbox area / image area — a lower bound on real overlap.
  final double overlapFraction;

  /// Whether the pair met the registration thresholds.
  final bool registered;

  const StitchAttemptResult({
    required this.candidateTargetId,
    required this.featureMatches,
    required this.inliers,
    required this.inlierRatio,
    required this.meanReprojPx,
    required this.overlapFraction,
    required this.registered,
  });
}

/// The result of one [cv.Stitcher] merge attempt.
class StitchMergeResult {
  final bool ok;

  /// `stitch_003.jpg`-style absolute path when [ok].
  final String? outputPath;

  /// The stitcher's own status name (`OK`, `ERR_NEED_MORE_IMGS`, …).
  final String? stitcherStatus;

  final String? error;

  /// Target ids whose images went into this attempt, in input order.
  final List<int> sourceTargetIds;

  const StitchMergeResult({
    required this.ok,
    this.outputPath,
    this.stitcherStatus,
    this.error,
    required this.sourceTargetIds,
  });
}

/// Everything the worker measured for one job.
class StitchWorkerOutcome {
  /// `false` when the JPEG could not be decoded at all.
  final bool decodeOk;
  final String? decodeError;

  /// Mean squared Laplacian of the work image (blur proxy) and mean grey.
  final double? laplacianVariance;
  final double? brightness;

  /// Non-null when the image itself is unusable (too blurry/dark/bright).
  final String? qualityReason;

  /// One entry per candidate actually attempted, best-first.
  final List<StitchAttemptResult> attempts;

  /// The group merge attempt, when one ran (registration had to pass first).
  final StitchMergeResult? groupMerge;

  /// The pairwise fallback merge attempt, when the group merge did not run
  /// or did not succeed.
  final StitchMergeResult? pairMerge;

  const StitchWorkerOutcome({
    required this.decodeOk,
    this.decodeError,
    this.laplacianVariance,
    this.brightness,
    this.qualityReason,
    this.attempts = const <StitchAttemptResult>[],
    this.groupMerge,
    this.pairMerge,
  });

  /// The best candidate that registered, or `null`.
  StitchAttemptResult? get bestRegistered {
    for (final a in attempts) {
      if (a.registered) return a;
    }
    return null;
  }
}
