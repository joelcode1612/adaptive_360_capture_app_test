// Incremental stitching verification models for the 26-target AR capture.
//
// Pure Dart — no Flutter, no OpenCV — so the record schema, the status
// transitions and the group bookkeeping are testable with the plain VM (see
// `tool/verify_incremental_stitch.dart`), and the service can be driven from
// tests with a fake worker.
//
// ## Why two statuses per image
//
// A photograph being *saved* and a photograph *fitting the panorama* are
// different facts. The capture pipeline proves the first; only a real feature
// match against already-captured neighbours can prove the second. The four
// stitch states are deliberately coarse:
//
// * [StitchStatus.pending] — not yet attempted: queued, or no overlapping
//   neighbour has been captured yet. Not a failure.
// * [StitchStatus.processing] — a worker is running for this image now.
// * [StitchStatus.pass] — a real registration against at least one captured
//   neighbour succeeded, with the measured metrics in the record. When the
//   merge attempt also succeeded, [ImageStitchRecord.stitchedOutputPath]
//   points at the produced intermediate image.
// * [StitchStatus.fail] — the attempted operation genuinely failed (decode,
//   quality, or too few geometrically consistent matches). A *pending* image
//   never becomes fail just because its neighbour has not been captured yet.
//
// A successful pairwise registration is reported as such and never claimed to
// guarantee the final 360° panorama; the final panorama has its own record.
library;

/// Per-image stitching status. See the library comment for the semantics.
enum StitchStatus {
  pending,
  processing,
  pass,
  fail;

  String get label => switch (this) {
    StitchStatus.pending => 'Pending',
    StitchStatus.processing => 'Processing',
    StitchStatus.pass => 'Pass',
    StitchStatus.fail => 'Fail',
  };

  static StitchStatus fromName(String? name) => StitchStatus.values
      .firstWhere((StitchStatus s) => s.name == name,
          orElse: () => StitchStatus.pending);
}

/// The final panorama's own status — independent of every per-image result.
enum FinalStitchStatus {
  pending,
  processing,
  pass,
  fail;

  String get label => switch (this) {
    FinalStitchStatus.pending => 'Not generated yet',
    FinalStitchStatus.processing => 'Generating…',
    FinalStitchStatus.pass => 'Generated',
    FinalStitchStatus.fail => 'Failed',
  };

  static FinalStitchStatus fromName(String? name) => FinalStitchStatus.values
      .firstWhere((FinalStitchStatus s) => s.name == name,
          orElse: () => FinalStitchStatus.pending);
}

/// The stitching verdict for one saved photograph.
class ImageStitchRecord {
  /// 1-based target id this record belongs to.
  final int targetId;

  /// `saved` — a record only exists for a photograph that was persisted and
  /// verified readable by the capture pipeline.
  final String captureStatus;

  final StitchStatus stitchStatus;

  /// Target ids of the neighbours this image was actually registered against
  /// (best first). Empty until a real attempt matched something.
  final List<int> matchedTargetIds;

  /// Good (ratio-test-passing) feature matches with the best candidate.
  final int? featureMatches;

  /// Geometrically consistent matches (RANSAC inliers) with the best
  /// candidate.
  final int? inliers;

  /// [inliers] / [featureMatches], when both are known.
  final double? inlierRatio;

  /// Mean reprojection error of the inlier correspondences, in pixels of the
  /// reduced work image.
  final double? registrationErrorPx;

  /// Fraction of the image area covered by the inlier correspondences' bbox —
  /// a lower bound on real overlap.
  final double? overlapFraction;

  /// Mean squared Laplacian of the work image — a blur proxy. Low means soft.
  final double? laplacianVariance;

  /// Mean grey level, 0–255.
  final double? brightness;

  /// The OpenCV [cv.Stitcher] status name from the merge attempt, when one
  /// ran, e.g. `OK` or `ERR_HOMOGRAPHY_EST_FAIL`.
  final String? stitcherStatus;

  /// Absolute path of the intermediate stitched image produced for this
  /// capture, when the merge succeeded.
  final String? stitchedOutputPath;

  /// Why [stitchStatus] is fail — decode, quality, or registration detail.
  final String? errorReason;

  /// Why no intermediate was produced even though registration passed.
  final String? mergeError;

  /// Identifies *which version* of the image the result describes: the
  /// capture timestamp plus the path. A retake produces a new token and
  /// invalidates every result that depended on the old version.
  final String imageToken;

  final DateTime updatedAt;

  /// How many worker attempts this target has had, including failures.
  final int attempts;

  const ImageStitchRecord({
    required this.targetId,
    this.captureStatus = 'saved',
    this.stitchStatus = StitchStatus.pending,
    this.matchedTargetIds = const <int>[],
    this.featureMatches,
    this.inliers,
    this.inlierRatio,
    this.registrationErrorPx,
    this.overlapFraction,
    this.laplacianVariance,
    this.brightness,
    this.stitcherStatus,
    this.stitchedOutputPath,
    this.errorReason,
    this.mergeError,
    required this.imageToken,
    required this.updatedAt,
    this.attempts = 0,
  });

  ImageStitchRecord copyWith({
    StitchStatus? stitchStatus,
    List<int>? matchedTargetIds,
    Object? featureMatches = _keep,
    Object? inliers = _keep,
    Object? inlierRatio = _keep,
    Object? registrationErrorPx = _keep,
    Object? overlapFraction = _keep,
    Object? laplacianVariance = _keep,
    Object? brightness = _keep,
    Object? stitcherStatus = _keep,
    Object? stitchedOutputPath = _keep,
    Object? errorReason = _keep,
    Object? mergeError = _keep,
    String? imageToken,
    DateTime? updatedAt,
    int? attempts,
  }) => ImageStitchRecord(
    targetId: targetId,
    captureStatus: captureStatus,
    stitchStatus: stitchStatus ?? this.stitchStatus,
    matchedTargetIds: matchedTargetIds ?? this.matchedTargetIds,
    featureMatches: _pick(featureMatches, this.featureMatches),
    inliers: _pick(inliers, this.inliers),
    inlierRatio: _pick(inlierRatio, this.inlierRatio),
    registrationErrorPx: _pick(registrationErrorPx, this.registrationErrorPx),
    overlapFraction: _pick(overlapFraction, this.overlapFraction),
    laplacianVariance: _pick(laplacianVariance, this.laplacianVariance),
    brightness: _pick(brightness, this.brightness),
    stitcherStatus: _pick(stitcherStatus, this.stitcherStatus),
    stitchedOutputPath: _pick(stitchedOutputPath, this.stitchedOutputPath),
    errorReason: _pick(errorReason, this.errorReason),
    mergeError: _pick(mergeError, this.mergeError),
    imageToken: imageToken ?? this.imageToken,
    updatedAt: updatedAt ?? this.updatedAt,
    attempts: attempts ?? this.attempts,
  );

  static const Object _keep = Object();

  /// Returns [requested] unless it is the `_keep` sentinel, then [current].
  static T? _pick<T>(Object? requested, T? current) =>
      identical(requested, _keep) ? current : requested as T?;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'target_id': targetId,
    'capture_status': captureStatus,
    'stitch_status': stitchStatus.name,
    'matched_target_ids': matchedTargetIds,
    if (featureMatches != null) 'feature_matches': featureMatches,
    if (inliers != null) 'inliers': inliers,
    if (inlierRatio != null) 'inlier_ratio': inlierRatio,
    if (registrationErrorPx != null)
      'registration_error_px': registrationErrorPx,
    if (overlapFraction != null) 'overlap_fraction': overlapFraction,
    if (laplacianVariance != null) 'laplacian_variance': laplacianVariance,
    if (brightness != null) 'brightness': brightness,
    if (stitcherStatus != null) 'stitcher_status': stitcherStatus,
    if (stitchedOutputPath != null)
      'stitched_output_path': stitchedOutputPath,
    if (errorReason != null) 'error_reason': errorReason,
    if (mergeError != null) 'merge_error': mergeError,
    'image_token': imageToken,
    'updated_at': updatedAt.toIso8601String(),
    'attempts': attempts,
  };

  static ImageStitchRecord fromJson(Map<String, dynamic> json) =>
      ImageStitchRecord(
        targetId: (json['target_id'] as num).toInt(),
        captureStatus: json['capture_status'] as String? ?? 'saved',
        stitchStatus: StitchStatus.fromName(json['stitch_status'] as String?),
        matchedTargetIds:
            ((json['matched_target_ids'] as List<dynamic>?) ?? const [])
                .map((dynamic e) => (e as num).toInt())
                .toList(growable: false),
        featureMatches: (json['feature_matches'] as num?)?.toInt(),
        inliers: (json['inliers'] as num?)?.toInt(),
        inlierRatio: (json['inlier_ratio'] as num?)?.toDouble(),
        registrationErrorPx: (json['registration_error_px'] as num?)
            ?.toDouble(),
        overlapFraction: (json['overlap_fraction'] as num?)?.toDouble(),
        laplacianVariance: (json['laplacian_variance'] as num?)?.toDouble(),
        brightness: (json['brightness'] as num?)?.toDouble(),
        stitcherStatus: json['stitcher_status'] as String?,
        stitchedOutputPath: json['stitched_output_path'] as String?,
        errorReason: json['error_reason'] as String?,
        mergeError: json['merge_error'] as String?,
        imageToken: json['image_token'] as String? ?? '',
        updatedAt:
            DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      );
}

/// One successfully produced intermediate stitch — the panorama as it stood
/// after the captures in [sourceTargetIds] had been merged.
class IntermediateStitch {
  final String path;

  /// The target ids whose images are inside this output, in merge order.
  final List<int> sourceTargetIds;
  final DateTime createdAt;

  const IntermediateStitch({
    required this.path,
    required this.sourceTargetIds,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'source_target_ids': sourceTargetIds,
    'created_at': createdAt.toIso8601String(),
  };

  static IntermediateStitch fromJson(Map<String, dynamic> json) =>
      IntermediateStitch(
        path: json['path'] as String,
        sourceTargetIds:
            ((json['source_target_ids'] as List<dynamic>?) ?? const <dynamic>[])
                .map((dynamic e) => (e as num).toInt())
                .toList(growable: false),
        createdAt:
            DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// The growing set of images known to stitch together, plus its latest output.
class StitchGroupState {
  /// The merged members, in the order they were merged.
  final List<int> targetIds;

  /// Absolute path of the most recent successful intermediate output that
  /// contains exactly these members. `null` until a merge succeeds.
  final String? outputPath;

  const StitchGroupState({
    this.targetIds = const <int>[],
    this.outputPath,
  });

  bool contains(int targetId) => targetIds.contains(targetId);

  /// Adds [targetId] (if not already a member) and refreshes the output path.
  /// Idempotent on purpose: a re-verified member updates the output instead of
  /// being appended twice.
  StitchGroupState addMember(int targetId, String outputPath) =>
      contains(targetId)
      ? StitchGroupState(targetIds: targetIds, outputPath: outputPath)
      : StitchGroupState(
          targetIds: <int>[...targetIds, targetId],
          outputPath: outputPath,
        );

  StitchGroupState dropMember(int targetId) => StitchGroupState(
    targetIds: targetIds.where((int id) => id != targetId).toList(),
    outputPath: null,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'target_ids': targetIds,
    if (outputPath != null) 'output_path': outputPath,
  };

  static StitchGroupState fromJson(Map<String, dynamic> json) =>
      StitchGroupState(
        targetIds:
            ((json['target_ids'] as List<dynamic>?) ?? const [])
                .map((dynamic e) => (e as num).toInt())
                .toList(growable: false),
        outputPath: json['output_path'] as String?,
      );
}

/// The final panorama result — never a substitute for per-image results.
class FinalPanoramaRecord {
  final FinalStitchStatus status;

  /// Absolute path of the final panorama, when [status] is pass.
  final String? panoramaPath;

  /// Why it failed, in words the review screen can show verbatim.
  final String? errorReason;

  /// On failure: the captured targets most likely responsible — every image
  /// whose own stitch record is a fail, plus merged-group dropouts.
  final List<int> failedTargetIds;

  final DateTime updatedAt;

  const FinalPanoramaRecord({
    this.status = FinalStitchStatus.pending,
    this.panoramaPath,
    this.errorReason,
    this.failedTargetIds = const <int>[],
    required this.updatedAt,
  });

  FinalPanoramaRecord copyWith({
    FinalStitchStatus? status,
    Object? panoramaPath = _keep,
    Object? errorReason = _keep,
    List<int>? failedTargetIds,
    DateTime? updatedAt,
  }) => FinalPanoramaRecord(
    status: status ?? this.status,
    panoramaPath: _pick(panoramaPath, this.panoramaPath),
    errorReason: _pick(errorReason, this.errorReason),
    failedTargetIds: failedTargetIds ?? this.failedTargetIds,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  static const Object _keep = Object();

  /// Returns [requested] unless it is the `_keep` sentinel, then [current].
  static T? _pick<T>(Object? requested, T? current) =>
      identical(requested, _keep) ? current : requested as T?;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'status': status.name,
    if (panoramaPath != null) 'panorama_path': panoramaPath,
    if (errorReason != null) 'error_reason': errorReason,
    'failed_target_ids': failedTargetIds,
    'updated_at': updatedAt.toIso8601String(),
  };

  static FinalPanoramaRecord fromJson(Map<String, dynamic> json) =>
      FinalPanoramaRecord(
        status: FinalStitchStatus.fromName(json['status'] as String?),
        panoramaPath: json['panorama_path'] as String?,
        errorReason: json['error_reason'] as String?,
        failedTargetIds:
            ((json['failed_target_ids'] as List<dynamic>?) ?? const [])
                .map((dynamic e) => (e as num).toInt())
                .toList(growable: false),
        updatedAt:
            DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// The whole persisted state for one station:
/// `<station>/stitch_results/stitching_results.json`.
class StitchResultsDocument {
  static const int version = 1;

  final String stationId;
  final Map<int, ImageStitchRecord> records;
  final StitchGroupState group;
  final List<IntermediateStitch> intermediates;
  final FinalPanoramaRecord finalPanorama;
  final DateTime updatedAt;

  StitchResultsDocument({
    required this.stationId,
    Map<int, ImageStitchRecord>? records,
    StitchGroupState? group,
    List<IntermediateStitch>? intermediates,
    FinalPanoramaRecord? finalPanorama,
    DateTime? updatedAt,
  }) : records = records ?? const <int, ImageStitchRecord>{},
       group = group ?? const StitchGroupState(),
       intermediates = intermediates ?? const <IntermediateStitch>[],
       finalPanorama =
           finalPanorama ??
           FinalPanoramaRecord(updatedAt: DateTime.fromMillisecondsSinceEpoch(0)),
       updatedAt = updatedAt ?? DateTime.now();

  ImageStitchRecord? recordFor(int targetId) => records[targetId];

  int get passCount => records.values
      .where((ImageStitchRecord r) => r.stitchStatus == StitchStatus.pass)
      .length;
  int get failCount => records.values
      .where((ImageStitchRecord r) => r.stitchStatus == StitchStatus.fail)
      .length;
  int get pendingCount => records.values
      .where((ImageStitchRecord r) => r.stitchStatus == StitchStatus.pending)
      .length;
  int get processingCount => records.values
      .where((ImageStitchRecord r) => r.stitchStatus == StitchStatus.processing)
      .length;

  /// The most recent output to show prominently: the final panorama when it
  /// exists, otherwise the newest intermediate.
  String? get latestPreviewPath =>
      finalPanorama.panoramaPath ??
      (intermediates.isEmpty ? null : intermediates.last.path);

  StitchResultsDocument withRecord(ImageStitchRecord record) {
    final next = Map<int, ImageStitchRecord>.of(records);
    next[record.targetId] = record;
    return StitchResultsDocument(
      stationId: stationId,
      records: next,
      group: group,
      intermediates: intermediates,
      finalPanorama: finalPanorama,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'station_id': stationId,
    'updated_at': updatedAt.toIso8601String(),
    'records': <String, dynamic>{
      for (final MapEntry<int, ImageStitchRecord> e in records.entries)
        '${e.key}': e.value.toJson(),
    },
    'group': group.toJson(),
    'intermediates': intermediates
        .map((IntermediateStitch i) => i.toJson())
        .toList(growable: false),
    'final': finalPanorama.toJson(),
  };

  static StitchResultsDocument fromJson(Map<String, dynamic> json) {
    final rawRecords = json['records'] as Map<String, dynamic>? ?? const {};
    return StitchResultsDocument(
      stationId: json['station_id'] as String? ?? '',
      records: <int, ImageStitchRecord>{
        for (final MapEntry<String, dynamic> e in rawRecords.entries)
          int.parse(e.key): ImageStitchRecord.fromJson(
            e.value as Map<String, dynamic>,
          ),
      },
      group: StitchGroupState.fromJson(
        json['group'] as Map<String, dynamic>? ?? const {},
      ),
      intermediates:
          ((json['intermediates'] as List<dynamic>?) ?? const [])
              .map(
                (dynamic e) =>
                    IntermediateStitch.fromJson(e as Map<String, dynamic>),
              )
              .toList(growable: false),
      finalPanorama: FinalPanoramaRecord.fromJson(
        json['final'] as Map<String, dynamic>? ?? const {},
      ),
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
