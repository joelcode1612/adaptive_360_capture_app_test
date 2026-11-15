import 'dart:async';
import 'dart:io';

import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/stitch/incremental_stitch_models.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/stitch/stitch_neighbor_planner.dart';
import 'package:adaptive_360_capture_app/features/capture/data/stitch/incremental_stitch_store.dart';
import 'package:adaptive_360_capture_app/features/capture/data/stitch/stitch_job_models.dart';

/// Signature of the actual OpenCV work. The real implementation runs
/// [cv.Stitcher]/ORB in a background isolate (`incremental_stitch_worker.dart`);
/// tests inject fakes, which keeps this class runnable on the plain VM.
typedef StitchWorkerFn =
    Future<StitchWorkerOutcome> Function(StitchJobPacket packet);

/// Registration thresholds — the values a pair must meet for the new image to
/// count as [StitchStatus.pass].
const int kStitchMinInliers = 12;
const int kStitchMinGoodMatches = 20;
const double kStitchMaxMeanReprojPx = 8.0;

// The constructor parameters are deliberately named without the leading
// underscore so the public API reads `loadRecords:` rather than `_loadRecords:`,
// the same exception the capture controller documents for its own constructor.
// ignore_for_file: prefer_initializing_formals

/// Serialized, non-blocking stitching verification for one capture station.
///
/// ## Contract with the capture flow
///
/// The capture controller calls [onCaptureSaved] **after** the JPEG is on
/// disk and verified — stitching never begins before persistence succeeds,
/// and a stitching failure here never touches capture state: the photograph
/// stays saved, the target stays complete, and the user can keep capturing.
/// The service communicates with the UI through [onChanged] only.
///
/// ## Scheduling
///
/// Jobs run strictly one at a time ([_chain]) in submission order. Every
/// job runs in the worker's own isolate, so the camera preview is never
/// blocked. Duplicate submissions for a target that is queued or running are
/// dropped ([_queued]) — the "duplicate requests do not create duplicate
/// jobs" guarantee.
///
/// ## Result classes
///
/// * **pending** — queued, or no captured neighbour has expected overlap yet.
///   Never a failure. Every successful save re-queues pending images, so an
///   early image resolves as soon as a real neighbour exists.
/// * **pass** — a real registration measured enough geometrically consistent
///   matches ([kStitchMinInliers]) with low reprojection error
///   ([kStitchMaxMeanReprojPx]). When the merge also succeeded, the record
///   points at the produced intermediate image.
/// * **fail** — an attempted operation genuinely failed: decode, image
///   quality, or registration. Never auto-retried; the user decides.
class IncrementalStitchService {
  IncrementalStitchService({
    required this.stationId,
    required Future<String?> Function() resolveStationDir,
    required Future<List<CaptureRecord>> Function() loadRecords,
    StitchWorkerFn? worker,
    List<CaptureTargetSpec> Function()? specs,
    this.onChanged,
    DateTime Function()? clock,
  }) : _resolveStationDir = resolveStationDir,
       _loadRecords = loadRecords,
       _worker =
           worker ??
           ((StitchJobPacket packet) async =>
               // Without an injected worker there is nothing real to run; the
               // record stays pending instead of pretending success.
               StitchWorkerOutcome(
                 decodeOk: false,
                 decodeError: 'No stitching worker is configured.',
               )),
       _specs = specs ?? buildCaptureSphere,
       _clock = clock ?? DateTime.now;

  final String stationId;

  /// Resolves the station's on-disk directory, or `null` while it does not
  /// exist yet (a fresh station has no directory until the first capture).
  /// Resolution happens lazily on first use and is then cached, so the flow
  /// screen can create the service before any photograph exists.
  final Future<String?> Function() _resolveStationDir;
  final Future<List<CaptureRecord>> Function() _loadRecords;
  final StitchWorkerFn _worker;
  final List<CaptureTargetSpec> Function() _specs;
  final DateTime Function() _clock;

  /// Change notification. A plain mutable field on purpose: the capture flow
  /// screen owns it while capturing, and the review screen takes it over for
  /// the review phase — one listener at a time is the whole lifetime model.
  void Function()? onChanged;

  final StitchNeighborPlanner _planner = const StitchNeighborPlanner();

  IncrementalStitchStore? _store;

  StitchResultsDocument _document = StitchResultsDocument(
    stationId: '',
  );
  final Set<int> _queued = <int>{};
  Future<void> _chain = Future<void>.value();
  Future<void> _saveChain = Future<void>.value();
  bool _loaded = false;
  bool _disposed = false;

  /// The current state snapshot — safe to read from any build.
  StitchResultsDocument get document => _document;

  /// Whether at least one job is queued or running.
  bool get busy => _queued.isNotEmpty;

  /// Resolves when every job submitted **before this call** has finished,
  /// including the persistence writes. Tests and the harness await this
  /// instead of guessing with delays.
  Future<void> get idle => _chain;

  /// Loads persisted results and reconciles them with the photographs that
  /// actually exist now. Idempotent; called once before first use.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final store = await _storeOrNull();
    final persisted = store == null ? null : await store.load();
    var doc =
        persisted ??
        StitchResultsDocument(stationId: stationId);
    final records = await _loadRecordsSafe();
    final tokens = <int, String>{
      for (final CaptureRecord r in records) r.targetId: imageTokenOf(r),
    };

    final reconciled = <int, ImageStitchRecord>{};
    doc.records.forEach((int id, ImageStitchRecord record) {
      final token = tokens[id];
      if (token == null) {
        // The record describes a photograph that no longer exists — a
        // deleted or rolled-back station. Drop it.
        return;
      }
      final staleVersion = record.imageToken != token;
      final crashedJob = record.stitchStatus == StitchStatus.processing;
      reconciled[id] =
          (staleVersion || crashedJob)
              ? ImageStitchRecord(
                targetId: id,
                imageToken: token,
                updatedAt: _clock(),
              )
              : record;
    });
    // Records for captures made by an older app version (no document yet)
    // join as pending rather than being treated as verified.
    for (final entry in tokens.entries) {
      reconciled.putIfAbsent(
        entry.key,
        () => ImageStitchRecord(
          targetId: entry.key,
          imageToken: entry.value,
          updatedAt: _clock(),
        ),
      );
    }

    var group = doc.group;
    for (final int member in List<int>.of(group.targetIds)) {
      final record = reconciled[member];
      if (record == null || record.stitchStatus != StitchStatus.pass) {
        group = group.dropMember(member);
      }
    }
    final intermediates = doc.intermediates
        .where((IntermediateStitch i) => File(i.path).existsSync())
        .toList(growable: false);
    var finalPano = doc.finalPanorama;
    if (finalPano.status == FinalStitchStatus.processing) {
      finalPano = finalPano.copyWith(status: FinalStitchStatus.pending);
    }
    if (finalPano.panoramaPath != null &&
        !File(finalPano.panoramaPath!).existsSync()) {
      finalPano = finalPano.copyWith(
        status: FinalStitchStatus.pending,
        panoramaPath: null,
      );
    }

    _document = StitchResultsDocument(
      stationId: stationId,
      records: reconciled,
      group: group,
      intermediates: intermediates,
      finalPanorama: finalPano,
      updatedAt: _clock(),
    );
    await _save();
    _notify();
  }

  /// Called by the capture controller after a photograph is saved and
  /// verified. Enqueues verification for this image and re-queues pending
  /// ones so a new neighbour can resolve them.
  Future<void> onCaptureSaved(CaptureRecord record) async {
    await load();
    final token = imageTokenOf(record);
    final existing = _document.recordFor(record.targetId);
    final isNewVersion = existing == null || existing.imageToken != token;
    if (!isNewVersion) {
      // The same image version again — the duplicate signal a racing
      // completion event produces. A result in hand (pass, fail) or in
      // flight (processing, queued) is never re-run; only a pending one is
      // re-evaluated cheaply, because a neighbour may have arrived.
      final status = existing.stitchStatus;
      final settled = status == StitchStatus.pass ||
          status == StitchStatus.fail ||
          status == StitchStatus.processing ||
          _queued.contains(record.targetId);
      if (settled) {
        return;
      }
    }
    if (isNewVersion) {
      await _invalidateTarget(record.targetId, newToken: token);
    }
    if (!_document.records.containsKey(record.targetId)) {
      _document = _document.withRecord(
        ImageStitchRecord(
          targetId: record.targetId,
          imageToken: token,
          updatedAt: _clock(),
        ),
      );
      await _save();
      _notify();
    }
    _enqueue(record.targetId);
    // A new photograph can be the missing neighbour for earlier pending
    // images — re-queue them (cheap when they still have no candidates).
    for (final ImageStitchRecord r in _document.records.values) {
      if (r.targetId != record.targetId &&
          r.stitchStatus == StitchStatus.pending &&
          !_queued.contains(r.targetId)) {
        _enqueue(r.targetId);
      }
    }
  }

  /// User-requested retry: re-runs verification for one target regardless of
  /// its previous outcome.
  Future<void> retryTarget(int targetId) async {
    await load();
    final record = _document.recordFor(targetId);
    if (record == null) return;
    _document = _document.withRecord(
      record.copyWith(
        stitchStatus: StitchStatus.pending,
        errorReason: null,
        mergeError: null,
        updatedAt: _clock(),
      ),
    );
    await _save();
    _notify();
    _enqueue(targetId);
  }

  /// Retries every failed target, e.g. after a retake session.
  Future<void> retryAllFailed() async {
    await load();
    final failed = _document.records.values
        .where((ImageStitchRecord r) => r.stitchStatus == StitchStatus.fail)
        .map((ImageStitchRecord r) => r.targetId)
        .toList(growable: false);
    for (final int id in failed) {
      await retryTarget(id);
    }
  }

  /// Marks the final panorama run started (before the stitcher runs).
  Future<void> beginFinalPanorama() async {
    await load();
    _document = StitchResultsDocument(
      stationId: _document.stationId,
      records: _document.records,
      group: _document.group,
      intermediates: _document.intermediates,
      finalPanorama: _document.finalPanorama.copyWith(
        status: FinalStitchStatus.processing,
        errorReason: null,
        failedTargetIds: const <int>[],
        updatedAt: _clock(),
      ),
      updatedAt: _clock(),
    );
    await _save();
    _notify();
  }

  /// Records the final panorama outcome, with attribution of which captured
  /// images most likely caused a failure.
  Future<void> completeFinalPanorama({
    required bool success,
    String? panoramaPath,
    String? errorReason,
  }) async {
    await load();
    final failedTargets = success
        ? const <int>[]
        : _attribution();
    _document = StitchResultsDocument(
      stationId: _document.stationId,
      records: _document.records,
      group: _document.group,
      intermediates: _document.intermediates,
      finalPanorama: FinalPanoramaRecord(
        status: success ? FinalStitchStatus.pass : FinalStitchStatus.fail,
        panoramaPath: panoramaPath,
        errorReason: errorReason,
        failedTargetIds: failedTargets,
        updatedAt: _clock(),
      ),
      updatedAt: _clock(),
    );
    await _save();
    _notify();
  }

  /// The captured targets most likely responsible for a final-stitch failure:
  /// every image whose own verification failed, plus captured images that
  /// never made it into a merged group.
  List<int> _attribution() {
    final captured = _document.records.keys.toSet();
    final suspected = <int>{
      for (final ImageStitchRecord r in _document.records.values)
        if (r.stitchStatus == StitchStatus.fail) r.targetId,
      ...captured.difference(_document.group.targetIds.toSet()),
    };
    return suspected.toList(growable: false)..sort();
  }

  /// Releases listeners. In-flight work still finishes and persists its
  /// result — the JSON on disk stays authoritative.
  void dispose() {
    _disposed = true;
  }

  // ── internals ─────────────────────────────────────────────────────────────

  /// A stable identity of *which version* of an image a result describes.
  static String imageTokenOf(CaptureRecord record) =>
      '${record.capturedAt.millisecondsSinceEpoch}:${record.imagePath}';

  void _enqueue(int targetId) {
    if (_disposed || _queued.contains(targetId)) return;
    _queued.add(targetId);
    _chain = _chain.then((_) => _runJob(targetId)).whenComplete(() {
      _queued.remove(targetId);
    });
  }

  Future<void> _runJob(int targetId) async {
    if (_disposed) return;
    final records = await _loadRecordsSafe();
    CaptureRecord? record;
    for (final CaptureRecord r in records) {
      if (r.targetId == targetId) {
        record = r;
        break;
      }
    }
    if (record == null) {
      // The photograph disappeared (retake rollback): drop the record.
      final next = Map<int, ImageStitchRecord>.of(_document.records)
        ..remove(targetId);
      _document = StitchResultsDocument(
        stationId: _document.stationId,
        records: next,
        group: _document.group.contains(targetId)
            ? _document.group.dropMember(targetId)
            : _document.group,
        intermediates: _document.intermediates,
        finalPanorama: _document.finalPanorama,
        updatedAt: _clock(),
      );
      await _save();
      _notify();
      return;
    }
    final store = await _storeOrNull();
    if (store == null) return;
    final token = imageTokenOf(record);
    final current = _document.recordFor(targetId);
    if (current != null && current.imageToken != token) {
      // A retake landed while this job waited in the queue; the enqueued job
      // is stale. Drop it — the new version is already queued separately.
      return;
    }

    CaptureTargetSpec? spec;
    for (final CaptureTargetSpec s in _specs()) {
      if (s.targetId == targetId) {
        spec = s;
        break;
      }
    }
    if (spec == null) return;

    final capturedIds = records.map((CaptureRecord r) => r.targetId).toSet();
    final planned = _planner.plan(
      forTarget: spec,
      allSpecs: _specs(),
      capturedIds: capturedIds,
    );

    // Only candidates whose file is really on disk are attempted.
    final candidates = <StitchCandidatePacket>[];
    for (final PlannedNeighbor n in planned) {
      final path = records
          .firstWhere(
            (CaptureRecord r) => r.targetId == n.targetId,
          )
          .imagePath;
      if (File(path).existsSync()) {
        candidates.add(
          StitchCandidatePacket(targetId: n.targetId, imagePath: path),
        );
      }
    }

    if (candidates.isEmpty) {
      _document = _document.withRecord(
        (current ??
                ImageStitchRecord(
                  targetId: targetId,
                  imageToken: token,
                  updatedAt: _clock(),
                ))
            .copyWith(
          stitchStatus: StitchStatus.pending,
          matchedTargetIds: const <int>[],
          errorReason:
              'Waiting for an overlapping neighbour to be captured.',
          updatedAt: _clock(),
        ),
      );
      await _save();
      _notify();
      return;
    }

    _document = _document.withRecord(
      (current ??
              ImageStitchRecord(
                targetId: targetId,
                imageToken: token,
                updatedAt: _clock(),
              ))
          .copyWith(
        stitchStatus: StitchStatus.processing,
        errorReason: null,
        updatedAt: _clock(),
      ),
    );
    await _save();
    _notify();
    if (_disposed) return;

    final groupImages = <StitchCandidatePacket>[];
    for (final int member in _document.group.targetIds) {
      if (member == targetId) continue;
      final memberPath = _memberPath(records, member);
      if (memberPath != null && File(memberPath).existsSync()) {
        groupImages.add(
          StitchCandidatePacket(targetId: member, imagePath: memberPath),
        );
      }
    }

    final outputPath = await store.nextOutputPath();
    final packet = StitchJobPacket(
      imagePath: record.imagePath,
      targetId: targetId,
      outputsDir: store.outputsDir,
      candidates: candidates,
      groupImages: groupImages,
      nextOutputIndex: _outputIndexOf(outputPath),
    );

    StitchWorkerOutcome outcome;
    try {
      outcome = await _worker(packet);
    } catch (error) {
      outcome = StitchWorkerOutcome(
        decodeOk: false,
        decodeError: 'Stitching worker error: $error',
      );
    }
    // The job may have waited in the worker while the user retook this very
    // target. Its result describes pixels that no longer exist, so it is
    // discarded — the new version already has its own job queued.
    final after = _document.recordFor(targetId);
    if (after != null && after.imageToken != token) {
      return;
    }
    // Even when the host screen is disposed, the completed work is persisted
    // below: the JSON on disk stays authoritative.
    await _applyOutcome(targetId, token, outcome);
    await _save();
    _notify();
  }

  Future<void> _applyOutcome(
    int targetId,
    String token,
    StitchWorkerOutcome outcome,
  ) async {
    final current =
        _document.recordFor(targetId) ??
        ImageStitchRecord(
          targetId: targetId,
          imageToken: token,
          updatedAt: _clock(),
        );
    final now = _clock();

    if (!outcome.decodeOk) {
      _document = _document.withRecord(
        current.copyWith(
          stitchStatus: StitchStatus.fail,
          laplacianVariance: outcome.laplacianVariance,
          brightness: outcome.brightness,
          errorReason:
              'Image decoding failed'
              '${outcome.decodeError == null ? '' : ': ${outcome.decodeError}'}'
              '. Retake this target.',
          attempts: current.attempts + 1,
          updatedAt: now,
        ),
      );
      return;
    }
    if (outcome.qualityReason != null) {
      _document = _document.withRecord(
        current.copyWith(
          stitchStatus: StitchStatus.fail,
          laplacianVariance: outcome.laplacianVariance,
          brightness: outcome.brightness,
          errorReason: outcome.qualityReason,
          attempts: current.attempts + 1,
          updatedAt: now,
        ),
      );
      return;
    }

    final best = outcome.bestRegistered;
    if (best == null) {
      final detail = outcome.attempts.isEmpty
          ? 'No overlapping neighbour could be attempted.'
          : _registrationFailureText(outcome.attempts.first);
      _document = _document.withRecord(
        current.copyWith(
          stitchStatus: StitchStatus.fail,
          laplacianVariance: outcome.laplacianVariance,
          brightness: outcome.brightness,
          matchedTargetIds: outcome.attempts
              .map((StitchAttemptResult a) => a.candidateTargetId)
              .toList(growable: false),
          errorReason: detail,
          attempts: current.attempts + 1,
          updatedAt: now,
        ),
      );
      return;
    }

    // Registration passed — real evidence this photograph fits its
    // neighbours. Now attempt the merges.
    final groupMerge = outcome.groupMerge;
    final pairMerge = outcome.pairMerge;
    String? outputPath;
    String? stitcherStatus;
    String? mergeError;
    var group = _document.group;
    final intermediates = List<IntermediateStitch>.of(
      _document.intermediates,
    );

    if (groupMerge != null && groupMerge.ok) {
      outputPath = groupMerge.outputPath;
      stitcherStatus = groupMerge.stitcherStatus;
      group = group.addMember(targetId, outputPath!);
      intermediates.add(
        IntermediateStitch(
          path: outputPath,
          sourceTargetIds: groupMerge.sourceTargetIds,
          createdAt: now,
        ),
      );
    } else if (pairMerge != null && pairMerge.ok) {
      stitcherStatus = pairMerge.stitcherStatus;
      intermediates.add(
        IntermediateStitch(
          path: pairMerge.outputPath!,
          sourceTargetIds: pairMerge.sourceTargetIds,
          createdAt: now,
        ),
      );
      outputPath = pairMerge.outputPath;
      if (group.targetIds.isEmpty) {
        // The first successful pair *is* the seed of the merged group.
        for (final int id in pairMerge.sourceTargetIds) {
          if (id != targetId && !group.contains(id)) {
            group = StitchGroupState(targetIds: <int>[...group.targetIds, id]);
          }
        }
        group = group.addMember(targetId, pairMerge.outputPath!);
      } else {
        mergeError =
            'Registered with target ${best.candidateTargetId}, but the group '
            'merge failed (${groupMerge?.stitcherStatus ?? pairMerge.stitcherStatus}). '
            'The previous stitched output is unchanged.';
      }
    } else {
      final attempted =
          groupMerge?.stitcherStatus ?? pairMerge?.stitcherStatus;
      mergeError =
          'Registration verified, but the stitching merge did not produce an '
          'image'
          '${attempted == null ? '' : ' (stitcher status: $attempted)'}'
          '.';
    }

    _document = StitchResultsDocument(
      stationId: _document.stationId,
      records: Map<int, ImageStitchRecord>.of(_document.records),
      group: group,
      intermediates: intermediates,
      finalPanorama: _document.finalPanorama,
      updatedAt: now,
    );
    _document = _document.withRecord(
      current.copyWith(
        stitchStatus: StitchStatus.pass,
        matchedTargetIds: outcome.attempts
            .map((StitchAttemptResult a) => a.candidateTargetId)
            .toList(growable: false),
        featureMatches: best.featureMatches,
        inliers: best.inliers,
        inlierRatio: best.inlierRatio,
        registrationErrorPx: best.meanReprojPx,
        overlapFraction: best.overlapFraction,
        laplacianVariance: outcome.laplacianVariance,
        brightness: outcome.brightness,
        stitcherStatus: stitcherStatus ?? 'OK (registration only)',
        stitchedOutputPath: outputPath,
        errorReason: null,
        mergeError: mergeError,
        attempts: current.attempts + 1,
        updatedAt: now,
      ),
    );
  }

  String _registrationFailureText(StitchAttemptResult a) =>
      'Registration failed against target ${a.candidateTargetId}: '
      '${a.featureMatches} good matches, ${a.inliers} inliers '
      '(need ≥ $kStitchMinInliers inliers and ≤ $kStitchMaxMeanReprojPx px '
      'error). Retake this target or its neighbour with more overlap.';

  Future<List<CaptureRecord>> _loadRecordsSafe() async {
    try {
      return await _loadRecords();
    } catch (_) {
      return const <CaptureRecord>[];
    }
  }

  String? _memberPath(List<CaptureRecord> records, int targetId) {
    for (final CaptureRecord r in records) {
      if (r.targetId == targetId) return r.imagePath;
    }
    return null;
  }

  static int _outputIndexOf(String path) {
    final match = RegExp(r'stitch_(\d{3})\.jpg$').firstMatch(path);
    return match == null ? 1 : int.parse(match.group(1)!);
  }

  Future<void> _invalidateTarget(int targetId, {required String newToken}) async {
    final existing = _document.recordFor(targetId);
    if (existing != null) {
      // The old version's results are void, wherever they were used.
      final next = Map<int, ImageStitchRecord>.of(_document.records);
      next[targetId] = ImageStitchRecord(
        targetId: targetId,
        imageToken: newToken,
        updatedAt: _clock(),
      );
      next.forEach((int id, ImageStitchRecord r) {
        if (id != targetId &&
            r.matchedTargetIds.contains(targetId) &&
            r.stitchStatus == StitchStatus.pass) {
          // A pass that was proven against the replaced image is no longer
          // proven — back to pending for a fresh verification.
          next[id] = r.copyWith(
            stitchStatus: StitchStatus.pending,
            matchedTargetIds: const <int>[],
            featureMatches: null,
            inliers: null,
            inlierRatio: null,
            registrationErrorPx: null,
            overlapFraction: null,
            stitchedOutputPath: null,
            stitcherStatus: null,
            mergeError: null,
            errorReason: 'Neighbour target $targetId was retaken.',
            updatedAt: _clock(),
          );
        }
      });
      _document = StitchResultsDocument(
        stationId: _document.stationId,
        records: next,
        group: _document.group.contains(targetId)
            ? _document.group.dropMember(targetId)
            : _document.group,
        intermediates: _document.intermediates,
        finalPanorama: _document.finalPanorama.copyWith(
          status: FinalStitchStatus.pending,
          panoramaPath: null,
        ),
        updatedAt: _clock(),
      );
    }
  }

  /// Returns the store once the station directory exists, caching it. A fresh
  /// station has no directory until the first photograph is written, so early
  /// calls legitimately return `null`.
  Future<IncrementalStitchStore?> _storeOrNull() async {
    final cached = _store;
    if (cached != null) return cached;
    final dir = await _resolveStationDir();
    if (dir == null) return null;
    _store = IncrementalStitchStore(dir);
    return _store;
  }

  Future<void> _save() async {
    // All writes go through one chain, so a save triggered by onCaptureSaved
    // can never interleave with a save from a running job (Windows locks the
    // pending file while it is open).
    _saveChain = _saveChain.then((_) => _saveNow());
    await _saveChain;
  }

  Future<void> _saveNow() async {
    final store = await _storeOrNull();
    if (store == null) return;
    try {
      await store.save(_document);
    } catch (_) {
      // Persistence failure must not break capture; the next save retries.
    }
  }

  void _notify() {
    if (_disposed) return;
    onChanged?.call();
  }
}
