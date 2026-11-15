import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/capture/data/stitch/incremental_stitch_service.dart';
import 'package:adaptive_360_capture_app/features/capture/data/stitch/incremental_stitch_store.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/data/stitch/stitch_job_models.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/stitch/incremental_stitch_models.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// State-machine tests for the incremental stitch service.
///
/// These use a **fake worker** on real files in a real temp directory: the
/// queue, dedupe, persistence, invalidation and classification logic are
/// exercised exactly as they run in production. The *OpenCV* side of the
/// worker is verified separately with real image fixtures in
/// `incremental_stitch_worker_test.dart`.
void main() {
  late Directory temp;
  late FileCaptureRepository repository;
  late String stationDir;
  const stationId = 'st-test';

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('stitch_svc_test');
    stationDir = p.join(temp.path, 'st-test');
    await Directory(p.join(stationDir, 'frames')).create(recursive: true);
    repository = FileCaptureRepository(temp.path);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<CaptureRecord> addFrame(
    int targetId, {
    String content = 'jpeg-bytes',
  }) async {
    final path = p.join(stationDir, 'frames', 't${targetId.toString().padLeft(2, '0')}.jpg');
    await File(path).writeAsString(content);
    final record = CaptureRecord(
      stationId: stationId,
      targetId: targetId,
      imagePath: path,
      capturedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000 + targetId * 1000),
      targetYawDegrees: 0,
      targetPitchDegrees: 0,
      cameraPosition: Vec3.zero,
      cameraOrientation: Quat.identity,
      alignmentErrorDeg: 1.0,
      anchored: true,
      imageWidth: 800,
      imageHeight: 640,
    );
    await repository.saveRecord(record);
    return record;
  }

  IncrementalStitchService service({
    StitchWorkerFn? worker,
    void Function()? onChanged,
  }) => IncrementalStitchService(
    stationId: stationId,
    resolveStationDir: () async => stationDir,
    loadRecords: () => repository.loadRecords(stationId),
    worker: worker,
    onChanged: onChanged,
  );

  /// A worker that "registers" the new image against its first candidate and
  /// reports the given merge outcomes, writing the output file so the
  /// intermediate survives the service's existence sweep.
  StitchWorkerFn okWorker({
    bool groupMergeOk = true,
    bool pairMergeOk = true,
  }) =>
      (StitchJobPacket packet) async {
        StitchMergeResult merge(
          List<int> ids,
          int outputIndex, {
          required bool ok,
          String? status,
        }) {
          if (!ok) {
            return StitchMergeResult(
              ok: false,
              stitcherStatus: status ?? 'ERR_HOMOGRAPHY_EST_FAIL',
              sourceTargetIds: ids,
            );
          }
          final outPath = p.join(
            packet.outputsDir,
            'stitch_${outputIndex.toString().padLeft(3, '0')}.jpg',
          );
          Directory(packet.outputsDir).createSync(recursive: true);
          File(outPath).writeAsStringSync('stitched-image');
          return StitchMergeResult(
            ok: true,
            outputPath: outPath,
            stitcherStatus: 'OK',
            sourceTargetIds: ids,
          );
        }

        final first = packet.candidates.first;
        final groupMerge = packet.groupImages.isEmpty
            ? null
            : merge(
                <int>[for (final g in packet.groupImages) g.targetId, packet.targetId],
                packet.nextOutputIndex,
                ok: groupMergeOk,
              );
        final pairMerge = groupMerge != null && groupMerge.ok
            ? null
            : merge(
                <int>[first.targetId, packet.targetId],
                packet.nextOutputIndex + (groupMerge == null ? 0 : 1),
                ok: pairMergeOk,
              );
        return StitchWorkerOutcome(
          decodeOk: true,
          laplacianVariance: 900,
          brightness: 120,
          attempts: <StitchAttemptResult>[
            StitchAttemptResult(
              candidateTargetId: first.targetId,
              featureMatches: 250,
              inliers: 88,
              inlierRatio: 0.35,
              meanReprojPx: 1.7,
              overlapFraction: 0.4,
              registered: true,
            ),
          ],
          groupMerge: groupMerge,
          pairMerge: pairMerge,
        );
      };

  test('scenario 1: the first saved image is PENDING, not FAIL', () async {
    final svc = service(worker: okWorker());
    final record = await addFrame(1);
    await svc.onCaptureSaved(record);
    await svc.idle;

    final rec = svc.document.recordFor(1)!;
    expect(rec.stitchStatus, StitchStatus.pending);
    expect(rec.errorReason, contains('Waiting for an overlapping neighbour'));
    expect(rec.stitchedOutputPath, isNull);
  });

  test('scenario 2: an overlapping pair registers, stitches and seeds the group',
      () async {
    final svc = service(worker: okWorker());
    await svc.onCaptureSaved(await addFrame(1));
    await svc.onCaptureSaved(await addFrame(2));
    await svc.idle;

    final r1 = svc.document.recordFor(1)!;
    final r2 = svc.document.recordFor(2)!;
    expect(r1.stitchStatus, StitchStatus.pass, reason: r1.errorReason);
    expect(r2.stitchStatus, StitchStatus.pass, reason: r2.errorReason);
    // The first pair merge ran through the pairwise fallback (empty group),
    // seeded the group and produced a real output file.
    expect(svc.document.group.targetIds, containsAll(<int>[1, 2]));
    expect(r2.stitchedOutputPath, isNotNull);
    expect(File(r2.stitchedOutputPath!).existsSync(), isTrue);
    expect(r2.inliers, 88);
    expect(r2.matchedTargetIds, isNotEmpty);
    expect(svc.document.intermediates, isNotEmpty);
  });

  test('scenario 3: two images with no useful overlap FAIL with a real reason',
      () async {
    final svc = service(
      worker: (StitchJobPacket packet) async => StitchWorkerOutcome(
        decodeOk: true,
        attempts: <StitchAttemptResult>[
          StitchAttemptResult(
            candidateTargetId: packet.candidates.first.targetId,
            featureMatches: 26,
            inliers: 3,
            inlierRatio: 0.11,
            meanReprojPx: 6.2,
            overlapFraction: 0.02,
            registered: false,
          ),
        ],
      ),
    );
    await svc.onCaptureSaved(await addFrame(1));
    await svc.onCaptureSaved(await addFrame(2));
    await svc.idle;

    final r2 = svc.document.recordFor(2)!;
    expect(r2.stitchStatus, StitchStatus.fail);
    expect(r2.errorReason, contains('3 inliers'));
    expect(svc.document.group.targetIds, isEmpty);
  });

  test('scenario 4: a poor-quality image FAILs before matching', () async {
    final svc = service(
      worker: (StitchJobPacket packet) async => const StitchWorkerOutcome(
        decodeOk: true,
        laplacianVariance: 0.6,
        brightness: 118,
        qualityReason:
            'The photograph is too blurry to register reliably (detail level '
            '0.6, needs ≥ 30). Retake it holding the phone steadier.',
      ),
    );
    await svc.onCaptureSaved(await addFrame(1));
    await svc.onCaptureSaved(await addFrame(2));
    await svc.idle;

    final r2 = svc.document.recordFor(2)!;
    expect(r2.stitchStatus, StitchStatus.fail);
    expect(r2.errorReason, contains('too blurry'));
    expect(r2.laplacianVariance, 0.6,
        reason: 'the measured value is recorded, not invented');
  });

  test('scenario 5: a new image joins an existing stitched group', () async {
    final svc = service(worker: okWorker());
    await svc.onCaptureSaved(await addFrame(1));
    await svc.onCaptureSaved(await addFrame(2));
    final outputsBefore = svc.document.intermediates.length;

    await svc.onCaptureSaved(await addFrame(3));
    await svc.idle;
    final r3 = svc.document.recordFor(3)!;
    expect(r3.stitchStatus, StitchStatus.pass, reason: r3.errorReason);
    expect(svc.document.group.targetIds, <int>[1, 2, 3]);
    expect(svc.document.intermediates.length, outputsBefore + 1);
    // The group merge contains every member, new image last.
    expect(
      svc.document.intermediates.last.sourceTargetIds,
      <int>[1, 2, 3],
    );
  });

  test('scenario 6: a failed merge keeps the previous stitched output intact',
      () async {
    var mergeSucceeds = true;
    final svc = service(
      worker: (StitchJobPacket packet) async {
        final base = await okWorker(groupMergeOk: mergeSucceeds)(packet);
        return base;
      },
    );
    await svc.onCaptureSaved(await addFrame(1));
    await svc.onCaptureSaved(await addFrame(2));
    await svc.onCaptureSaved(await addFrame(3));
    await svc.idle;
    final goodOutput = svc.document.group.outputPath!;
    final goodMembers = List<int>.of(svc.document.group.targetIds);

    mergeSucceeds = false;
    await svc.onCaptureSaved(await addFrame(4));
    await svc.idle;

    final r4 = svc.document.recordFor(4)!;
    expect(r4.stitchStatus, StitchStatus.pass,
        reason: 'registration still succeeded — real evidence, honestly '
            'reported alongside the merge failure');
    expect(r4.mergeError, isNotNull);
    expect(svc.document.group.outputPath, goodOutput,
        reason: 'the previous successful output is preserved');
    expect(svc.document.group.targetIds, goodMembers,
        reason: 'the failed image did not join the group');
    expect(svc.document.intermediates.length, 4,
        reason: 'no new group output, but the pairwise fallback produced one '
            'so the gallery keeps showing development');
  });

  test('scenario 7: capturing continues while a stitching job runs', () async {
    // Target 2's job suspends inside the worker. The caller of
    // onCaptureSaved must already have returned — that is the whole
    // non-blocking contract.
    final release = Completer<void>();
    final processed = <int>[];
    final svc = service(
      worker: (StitchJobPacket packet) async {
        processed.add(packet.targetId);
        if (packet.targetId == 2) await release.future;
        return (await okWorker()(packet));
      },
    );
    await svc.onCaptureSaved(await addFrame(1));
    await svc.onCaptureSaved(await addFrame(2));

    // Target 1's job found no candidates and never reached the worker; the
    // caller is free while target 2's job is queued or in flight.
    expect(svc.busy, isTrue);
    expect(processed.contains(1), isFalse,
        reason: 'the re-verification of target 1 must not jump the queue');

    release.complete();
    await svc.idle;
    expect(processed.length, 2);
    expect(processed, containsAll(<int>[1, 2]));
    expect(svc.document.recordFor(2)!.stitchStatus, StitchStatus.pass);
    expect(svc.busy, isFalse);
  });

  test('scenario 8: duplicate submissions create exactly one job', () async {
    var calls = 0;
    final svc = service(
      worker: (StitchJobPacket packet) async {
        calls++;
        return (await okWorker()(packet));
      },
    );
    final record1 = await addFrame(1);
    final record2 = await addFrame(2);
    await svc.onCaptureSaved(record1);
    await svc.onCaptureSaved(record2);
    await svc.idle;
    final callsAfterFirstPair = calls;
    expect(callsAfterFirstPair, greaterThanOrEqualTo(1));

    // The same image version again — the exact duplicate the controller
    // could emit if a completion signal raced.
    await svc.onCaptureSaved(record2);
    await svc.onCaptureSaved(record2);
    await svc.idle;

    expect(calls, callsAfterFirstPair,
        reason: 'a settled result is never re-run by a duplicate signal');
  });

  test('scenario 9: results persist across an app restart', () async {
    final svc = service(worker: okWorker());
    await svc.onCaptureSaved(await addFrame(1));
    await svc.onCaptureSaved(await addFrame(2));
    await svc.idle;
    final before = svc.document;

    // A brand-new service instance — the process was "restarted".
    final svc2 = service(worker: okWorker());
    await svc2.load();

    expect(svc2.document.recordFor(1)!.stitchStatus, StitchStatus.pass);
    expect(svc2.document.recordFor(2)!.stitchStatus, StitchStatus.pass);
    expect(svc2.document.group.targetIds, before.group.targetIds);
    expect(svc2.document.intermediates.length, before.intermediates.length);
    expect(
      svc2.document.recordFor(2)!.stitchedOutputPath,
      before.recordFor(2)!.stitchedOutputPath,
      reason: 'the output path survives so the review screen can show it',
    );
  });

  test('scenario 10: retaking an image invalidates dependent results',
      () async {
    // A one-shot gate suspends the second job so the invalidation state is
    // observable before any re-verification completes.
    final gate = Completer<void>();
    final svc = service(
      worker: (StitchJobPacket packet) async {
        if (packet.targetId == 2 && !gate.isCompleted) {
          await gate.future;
        }
        return (await okWorker()(packet));
      },
    );
    await svc.onCaptureSaved(await addFrame(1));
    await svc.onCaptureSaved(await addFrame(2));
    // One yield so job 2 reaches the gated worker; it stays suspended there
    // until the gate opens.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(svc.document.recordFor(2)!.stitchStatus, StitchStatus.processing);

    gate.complete();
    await svc.idle;
    expect(svc.document.group.targetIds, containsAll(<int>[1, 2]));
    final output = svc.document.recordFor(2)!.stitchedOutputPath!;

    // Retake target 1: the controller writes a new JPEG and emits a new
    // record with a different capture time — a new image version.
    final retaken = CaptureRecord(
      stationId: stationId,
      targetId: 1,
      imagePath: p.join(stationDir, 'frames', 't01.jpg'),
      capturedAt: DateTime.fromMillisecondsSinceEpoch(1700000099999),
      targetYawDegrees: 0,
      targetPitchDegrees: 0,
      cameraPosition: Vec3.zero,
      cameraOrientation: Quat.identity,
      alignmentErrorDeg: 1.0,
      anchored: true,
      imageWidth: 800,
      imageHeight: 640,
    );
    await repository.saveRecord(retaken);
    await svc.onCaptureSaved(retaken);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    final r1 = svc.document.recordFor(1)!;
    final r2 = svc.document.recordFor(2)!;
    // Both were invalidated by the retake and then re-verified against the
    // new version by the automatic re-queue.
    expect(r1.stitchStatus, StitchStatus.pass,
        reason: 're-verified against the retaken pixels');
    expect(r1.imageToken, '1700000099999:${retaken.imagePath}');
    expect(r2.stitchStatus, StitchStatus.pass);
    expect(r2.matchedTargetIds, contains(1),
        reason: 'the fresh pass is proven against the new version');
    // The group contains both members again, and the old output file was
    // never deleted — history stays.
    expect(svc.document.group.contains(1), isTrue);
    expect(File(output).existsSync(), isTrue);
  });

  test('scenario 11: final panorama success is recorded separately', () async {
    final svc = service(worker: okWorker());
    await svc.onCaptureSaved(await addFrame(1));
    await svc.onCaptureSaved(await addFrame(2));
    await svc.idle;

    await svc.beginFinalPanorama();
    expect(svc.document.finalPanorama.status, FinalStitchStatus.processing);

    await svc.completeFinalPanorama(
      success: true,
      panoramaPath: p.join(stationDir, 'panorama.jpg'),
    );
    expect(svc.document.finalPanorama.status, FinalStitchStatus.pass);
    expect(svc.document.finalPanorama.panoramaPath, isNotNull);
    // Per-image results are independent of the final result.
    expect(svc.document.recordFor(1)!.stitchStatus, StitchStatus.pass);
  });

  test('scenario 12: a failed final stitch attributes causes and keeps files',
      () async {
    final svc = service(
      worker: (StitchJobPacket packet) async => StitchWorkerOutcome(
        decodeOk: true,
        attempts: <StitchAttemptResult>[
          StitchAttemptResult(
            candidateTargetId: packet.candidates.first.targetId,
            featureMatches: 5,
            inliers: 1,
            inlierRatio: 0.04,
            meanReprojPx: 9.0,
            overlapFraction: 0.01,
            registered: false,
          ),
        ],
      ),
    );
    final frame1 = await addFrame(1);
    final frame2 = await addFrame(2);
    await svc.onCaptureSaved(frame1);
    await svc.onCaptureSaved(frame2);
    await svc.idle;

    await svc.beginFinalPanorama();
    await svc.completeFinalPanorama(
      success: false,
      errorReason: 'Stitching failed (ERR_NEED_MORE_IMGS).',
    );
    final finalRec = svc.document.finalPanorama;
    expect(finalRec.status, FinalStitchStatus.fail);
    expect(finalRec.errorReason, contains('ERR_NEED_MORE_IMGS'));
    expect(finalRec.failedTargetIds, <int>[1, 2],
        reason: 'both images failed verification and neither is in a group');

    // Nothing on disk was touched.
    expect(File(frame1.imagePath).existsSync(), isTrue);
    expect(File(frame2.imagePath).existsSync(), isTrue);
  });

  test('a crash mid-job is recovered as PENDING on the next start', () async {
    final svc = service(worker: okWorker());
    await svc.onCaptureSaved(await addFrame(1));
    await svc.idle;
    // Simulate a crash while processing: write a processing record directly.
    final doc = svc.document.withRecord(
      svc.document.recordFor(1)!.copyWith(stitchStatus: StitchStatus.processing),
    );
    await IncrementalStitchStore(stationDir).save(doc);

    final svc2 = service(worker: okWorker());
    await svc2.load();
    expect(svc2.document.recordFor(1)!.stitchStatus, StitchStatus.pending,
        reason: 'processing is not a result — a crashed job must not read '
            'as pass or fail');
  });

  test('PENDING images are re-verified when a new neighbour arrives',
      () async {
    final svc = service(worker: okWorker());
    await svc.onCaptureSaved(await addFrame(1));
    await svc.idle;
    expect(svc.document.recordFor(1)!.stitchStatus, StitchStatus.pending);

    await svc.onCaptureSaved(await addFrame(2));
    await svc.idle;
    // The planner does not expect targets 1 and 3 (or 1 and 2's other side)
    // to overlap target 1 with only one neighbour — after target 2 arrives,
    // target 1 now has a real candidate and resolves.
    expect(svc.document.recordFor(1)!.stitchStatus, StitchStatus.pass);
  });
}
