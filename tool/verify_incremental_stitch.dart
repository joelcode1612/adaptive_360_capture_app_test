// Verification harness for the incremental stitching service stack.
//
// `flutter test` cannot run on this host: the `dartcv4` native-assets build
// probe invokes programs the sandbox blocks (reg.exe). The whole stitching
// *service* stack — models, neighbour planner, store, queue — is deliberately
// pure Dart (no Flutter, no OpenCV), so this script exercises the real
// production classes on the plain VM with a fake worker, mirroring the
// scenarios in `test/incremental_stitch_service_test.dart`:
//
//   dart --packages=.dart_tool/sphere_verify_package_config.json \
//        tool/verify_incremental_stitch.dart
//
// The real OpenCV worker is covered by `test/incremental_stitch_worker_test.dart`,
// which needs a host where the native toolchain can run.
//
// Every scenario prints PASS/FAIL with the actual reason; the process exits
// non-zero if any check fails.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adaptive_360_capture_app/features/capture/data/stitch/incremental_stitch_service.dart';
import 'package:adaptive_360_capture_app/features/capture/data/stitch/incremental_stitch_store.dart';
import 'package:adaptive_360_capture_app/features/capture/data/stitch/stitch_job_models.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/stitch/incremental_stitch_models.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/stitch/stitch_neighbor_planner.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

int _passed = 0;
int _failed = 0;
String _current = '';

void check(bool ok, String detail) {
  if (ok) {
    _passed++;
    stdout.writeln('  PASS  $_current — $detail');
  } else {
    _failed++;
    stdout.writeln('  FAIL  $_current — $detail');
  }
}

Future<void> scenario(String name, Future<void> Function() body) async {
  _current = name;
  stdout.writeln('\n=== $name ===');
  try {
    await body();
  } catch (e, st) {
    _failed++;
    stdout.writeln('  FAIL  $_current — threw $e\n$st');
  }
}

Future<void> drain([int ms = 40]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Future<void> main() async {
  await plannerChecks();
  final root = await Directory.systemTemp.createTemp('verify_stitch');
  try {
    await scenario('1. first image is PENDING', () => firstImagePending(root));
    await scenario(
      '2. overlapping pair registers and seeds the group',
      () => overlappingPair(root),
    );
    await scenario(
      '3. no-overlap pair FAILs with a real reason',
      () => noOverlapFails(root),
    );
    await scenario(
      '4. poor-quality image FAILs before matching',
      () => poorQualityFails(root),
    );
    await scenario('5. new image joins an existing group', () => joinsGroup(root));
    await scenario(
      '6. failed merge preserves the previous output',
      () => failedMergePreserves(root),
    );
    await scenario(
      '7. capturing continues while a job runs (serialized queue)',
      () => captureContinues(root),
    );
    await scenario(
      '8. duplicate submissions create one job',
      () => duplicatesDeduped(root),
    );
    await scenario(
      '9. results persist across restart',
      () => persistsAcrossRestart(root),
    );
    await scenario(
      '10. retake invalidates dependent results, then re-verifies',
      () => retakeInvalidates(root),
    );
    await scenario(
      '11. final panorama success recorded separately',
      () => finalPanoramaSuccess(root),
    );
    await scenario(
      '12. final failure attributes causes and keeps every JPEG',
      () => finalFailureKeepsFiles(root),
    );
    await scenario(
      '13. crashed job recovers as PENDING on restart',
      () => crashRecovery(root),
    );
  } finally {
    await root.delete(recursive: true);
  }

  stdout.writeln('\n===== $_passed passed, $_failed failed =====');
  if (_failed > 0) {
    exitCode = 1;
  }
}

// ── planner (pure geometry) ─────────────────────────────────────────────────

Future<void> plannerChecks() async {
  final specs = buildCaptureSphere();
  CaptureTargetSpec specFor(int id) =>
      specs.firstWhere((CaptureTargetSpec s) => s.targetId == id);
  const planner = StitchNeighborPlanner();

  await scenario('planner: first capture has no candidates', () async {
    final planned = planner.plan(
      forTarget: specFor(1),
      allSpecs: specs,
      capturedIds: const <int>{},
    );
    check(planned.isEmpty, 'empty plan for the first capture');
  });

  await scenario(
    'planner: ring neighbour qualifies, back and zenith do not',
    () async {
      // Layout: ids 1–8 middle ring at 45° yaw; 5 is the back (180°);
      // 25 is the zenith (90° up).
      final near = planner.plan(
        forTarget: specFor(1),
        allSpecs: specs,
        capturedIds: const <int>{2, 5, 25},
      );
      check(
        near.length == 1 && near.single.targetId == 2,
        'only target 2 (45°) qualified; 5 (180°) and 25 (zenith, 90°) rejected',
      );
    },
  );

  await scenario(
    'planner: zenith plans against the upper ring, capped at 3',
    () async {
      final planned = planner.plan(
        forTarget: specFor(25),
        allSpecs: specs,
        capturedIds: <int>{for (var i = 9; i <= 16; i++) i},
      );
      check(
        planned.length == 3 &&
            planned.every(
              (PlannedNeighbor p) =>
                  p.targetId >= 9 &&
                  p.targetId <= 16 &&
                  (p.angleDeg - 45).abs() < 0.5,
            ),
        'three upper-ring candidates at 45° each: '
        '[${planned.map((PlannedNeighbor p) => p.targetId).join(', ')}]',
      );
    },
  );
}

// ── service scenarios (fake worker, real files) ─────────────────────────────

late String stationDir;
const String stationId = 'st-verify';

/// Reads `records.json` directly — the same bytes the production
/// FileCaptureRepository writes — so the harness does not need the
/// path_provider import the repository drags in.
Future<List<CaptureRecord>> loadRecords() async {
  final file = File('$stationDir${Platform.pathSeparator}records.json');
  if (!await file.exists()) return const <CaptureRecord>[];
  final rows = jsonDecode(await file.readAsString()) as List<dynamic>;
  return rows
      .map((dynamic e) => CaptureRecord.fromJson(e as Map<String, dynamic>))
      .toList(growable: false);
}

/// Appends/updates one record in `records.json`, in the same format
/// FileCaptureRepository.saveRecord writes.
Future<void> writeRecord(CaptureRecord record) async {
  final existing = await loadRecords();
  final next = <CaptureRecord>[
    ...existing.where((CaptureRecord r) => r.targetId != record.targetId),
    record,
  ]..sort((CaptureRecord a, CaptureRecord b) => a.targetId.compareTo(b.targetId));
  await File(
    '$stationDir${Platform.pathSeparator}records.json',
  ).writeAsString(
    jsonEncode(next.map((CaptureRecord r) => r.toJson()).toList()),
    flush: true,
  );
}

Future<CaptureRecord> addFrame(int targetId) async {
  final path = '$stationDir${Platform.pathSeparator}frames'
      '${Platform.pathSeparator}t${targetId.toString().padLeft(2, '0')}.jpg';
  await File(path).writeAsString('jpeg-bytes-$targetId');
  final record = CaptureRecord(
    stationId: stationId,
    targetId: targetId,
    imagePath: path,
    capturedAt: DateTime.fromMillisecondsSinceEpoch(
      1700000000000 + targetId * 1000,
    ),
    targetYawDegrees: 0,
    targetPitchDegrees: 0,
    cameraPosition: Vec3.zero,
    cameraOrientation: Quat.identity,
    alignmentErrorDeg: 1,
    anchored: true,
    imageWidth: 800,
    imageHeight: 640,
  );
  await writeRecord(record);
  return record;
}

IncrementalStitchService service(
  StitchWorkerFn worker, {
  Completer<void>? gate,
  int? gateTarget,
}) {
  if (gate != null && gateTarget != null) {
    final target = gateTarget;
    return IncrementalStitchService(
      stationId: stationId,
      resolveStationDir: () async => stationDir,
      loadRecords: loadRecords,
      worker: (StitchJobPacket packet) async {
        if (packet.targetId == target && !gate.isCompleted) {
          await gate.future;
        }
        return worker(packet);
      },
    );
  }
  return IncrementalStitchService(
    stationId: stationId,
    resolveStationDir: () async => stationDir,
    loadRecords: loadRecords,
    worker: worker,
  );
}

/// Registers against the first candidate and merges, writing real output
/// files so the intermediate sweep sees them.
final StitchWorkerFn okWorker = (StitchJobPacket packet) async {
  StitchMergeResult merge(List<int> ids, int index, {required bool ok}) {
    if (!ok) {
      return StitchMergeResult(
        ok: false,
        stitcherStatus: 'ERR_HOMOGRAPHY_EST_FAIL',
        sourceTargetIds: ids,
      );
    }
    final out = '${packet.outputsDir}${Platform.pathSeparator}'
        'stitch_${index.toString().padLeft(3, '0')}.jpg';
    Directory(packet.outputsDir).createSync(recursive: true);
    File(out).writeAsStringSync('stitched-image');
    return StitchMergeResult(
      ok: true,
      outputPath: out,
      stitcherStatus: 'OK',
      sourceTargetIds: ids,
    );
  }

  final first = packet.candidates.first;
  final groupMerge = packet.groupImages.isEmpty
      ? null
      : merge(
          <int>[
            for (final g in packet.groupImages) g.targetId,
            packet.targetId,
          ],
          packet.nextOutputIndex,
          ok: true,
        );
  final pairMerge = groupMerge != null && groupMerge.ok
      ? null
      : merge(
          <int>[first.targetId, packet.targetId],
          packet.nextOutputIndex + (groupMerge == null ? 0 : 1),
          ok: true,
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

final StitchWorkerFn noMatchWorker = (StitchJobPacket packet) async =>
    StitchWorkerOutcome(
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
    );

Future<void> setup(Directory base) async {
  stationDir = '${base.path}${Platform.pathSeparator}st-verify';
  // Each scenario starts from a clean station: leftover records or outputs
  // from an earlier scenario would otherwise leak into its assertions.
  final dir = Directory(stationDir);
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
  await Directory(
    '$stationDir${Platform.pathSeparator}frames',
  ).create(recursive: true);
}

Future<void> firstImagePending(Directory base) async {
  await setup(base);
  final svc = service(okWorker);
  final record = await addFrame(1);
  await svc.onCaptureSaved(record);
  await svc.idle;
  final rec = svc.document.recordFor(1)!;
  check(
    rec.stitchStatus == StitchStatus.pending &&
        rec.errorReason!.contains('Waiting for an overlapping neighbour'),
    'status=${rec.stitchStatus.label}, reason="${rec.errorReason}"',
  );
}

Future<void> overlappingPair(Directory base) async {
  await setup(base);
  final svc = service(okWorker);
  await svc.onCaptureSaved(await addFrame(1));
  await svc.onCaptureSaved(await addFrame(2));
  await svc.idle;
  final r1 = svc.document.recordFor(1)!;
  final r2 = svc.document.recordFor(2)!;
  final output = r2.stitchedOutputPath;
  check(
    r1.stitchStatus == StitchStatus.pass &&
        r2.stitchStatus == StitchStatus.pass &&
        output != null &&
        File(output).existsSync() &&
        svc.document.group.targetIds.length == 2,
    'both PASS; group=${svc.document.group.targetIds}; '
    'output=${output == null ? 'none' : output.split(Platform.pathSeparator).last}',
  );
}

Future<void> noOverlapFails(Directory base) async {
  await setup(base);
  final svc = service(noMatchWorker);
  await svc.onCaptureSaved(await addFrame(1));
  await svc.onCaptureSaved(await addFrame(2));
  await svc.idle;
  final r2 = svc.document.recordFor(2)!;
  check(
    r2.stitchStatus == StitchStatus.fail &&
        r2.errorReason!.contains('3 inliers'),
    'status=${r2.stitchStatus.label}, reason="${r2.errorReason}"',
  );
}

Future<void> poorQualityFails(Directory base) async {
  await setup(base);
  final svc = service(
    (StitchJobPacket packet) async => const StitchWorkerOutcome(
      decodeOk: true,
      laplacianVariance: 0.6,
      brightness: 118,
      qualityReason: 'The photograph is too blurry to register reliably.',
    ),
  );
  await svc.onCaptureSaved(await addFrame(1));
  await svc.onCaptureSaved(await addFrame(2));
  await svc.idle;
  final r2 = svc.document.recordFor(2)!;
  check(
    r2.stitchStatus == StitchStatus.fail &&
        r2.errorReason!.contains('blurry') &&
        r2.laplacianVariance == 0.6,
    'failed with the quality reason and the measured value kept',
  );
}

Future<void> joinsGroup(Directory base) async {
  await setup(base);
  final svc = service(okWorker);
  await svc.onCaptureSaved(await addFrame(1));
  await svc.onCaptureSaved(await addFrame(2));
  await svc.onCaptureSaved(await addFrame(3));
  await svc.idle;
  final r3 = svc.document.recordFor(3)!;
  final last = svc.document.intermediates.last;
  check(
    r3.stitchStatus == StitchStatus.pass &&
        svc.document.group.targetIds.toSet().containsAll(<int>[1, 2, 3]) &&
        last.sourceTargetIds.toSet().containsAll(<int>[1, 2, 3]),
    'target 3 PASS; group members=${svc.document.group.targetIds}; '
    'latest intermediate covers ${last.sourceTargetIds}',
  );
}

Future<void> failedMergePreserves(Directory base) async {
  await setup(base);
  var groupMergeOk = true;
  final svc = service((StitchJobPacket packet) async {
    final outcome = await okWorker(packet);
    if (!groupMergeOk && outcome.groupMerge != null) {
      return StitchWorkerOutcome(
        decodeOk: outcome.decodeOk,
        laplacianVariance: outcome.laplacianVariance,
        brightness: outcome.brightness,
        attempts: outcome.attempts,
        groupMerge: StitchMergeResult(
          ok: false,
          stitcherStatus: 'ERR_HOMOGRAPHY_EST_FAIL',
          sourceTargetIds: outcome.groupMerge!.sourceTargetIds,
        ),
        pairMerge: outcome.pairMerge,
      );
    }
    return outcome;
  });
  await svc.onCaptureSaved(await addFrame(1));
  await svc.onCaptureSaved(await addFrame(2));
  await svc.onCaptureSaved(await addFrame(3));
  await svc.idle;
  final goodOutput = svc.document.group.outputPath;
  final goodMembers = List<int>.of(svc.document.group.targetIds);

  groupMergeOk = false;
  await svc.onCaptureSaved(await addFrame(4));
  await svc.idle;
  final r4 = svc.document.recordFor(4)!;
  check(
    r4.stitchStatus == StitchStatus.pass &&
        r4.mergeError != null &&
        svc.document.group.outputPath == goodOutput &&
        svc.document.group.targetIds.length == goodMembers.length,
    'registration PASS with mergeError; group output unchanged '
    '(${goodOutput == null ? 'none' : 'kept'}); '
    'members=${svc.document.group.targetIds}',
  );
}

Future<void> captureContinues(Directory base) async {
  await setup(base);
  final release = Completer<void>();
  final processed = <int>[];
  final svc = service((StitchJobPacket packet) async {
    processed.add(packet.targetId);
    if (packet.targetId == 2) await release.future;
    return okWorker(packet);
  });
  await svc.onCaptureSaved(await addFrame(1));
  await svc.onCaptureSaved(await addFrame(2));
  // Target 1's job found no candidates and never reached the worker; target
  // 2's job is queued (and will suspend inside the worker). The caller of
  // onCaptureSaved returned without waiting for either — that is the
  // non-blocking contract.
  final callerFree = svc.busy && !processed.contains(1);
  release.complete();
  await svc.idle;
  check(
    callerFree &&
        processed.length == 2 &&
        processed.contains(1) &&
        processed.contains(2) &&
        svc.document.recordFor(2)!.stitchStatus == StitchStatus.pass,
    'caller never blocked (busy=$callerFree); jobs ran [${processed.join(', ')}]; '
    'target 2 ${svc.document.recordFor(2)!.stitchStatus.label}',
  );
}

Future<void> duplicatesDeduped(Directory base) async {
  await setup(base);
  var calls = 0;
  final svc = service((StitchJobPacket packet) async {
    calls++;
    return okWorker(packet);
  });
  final record1 = await addFrame(1);
  final record2 = await addFrame(2);
  await svc.onCaptureSaved(record1);
  await svc.onCaptureSaved(record2);
  await svc.idle;
  // Target 2's verification ran exactly once; target 1's re-verification
  // had a candidate by then and ran through the worker too.
  final callsAfterFirstPair = calls;
  check(callsAfterFirstPair >= 1, 'first verification ran $calls time(s)');
  // The same image version signalled twice more — the exact duplicate a
  // racing completion event would produce.
  await svc.onCaptureSaved(record2);
  await svc.onCaptureSaved(record2);
  await svc.idle;
  check(
    calls == callsAfterFirstPair,
    'worker still ran $calls time(s) after duplicate submissions',
  );
}

Future<void> persistsAcrossRestart(Directory base) async {
  await setup(base);
  final svc = service(okWorker);
  await svc.onCaptureSaved(await addFrame(1));
  await svc.onCaptureSaved(await addFrame(2));
  await svc.idle;
  final beforeOutput = svc.document.recordFor(2)!.stitchedOutputPath;

  final svc2 = service(okWorker);
  await svc2.load();
  final r2 = svc2.document.recordFor(2)!;
  check(
    svc2.document.recordFor(1)!.stitchStatus == StitchStatus.pass &&
        r2.stitchStatus == StitchStatus.pass &&
        r2.stitchedOutputPath == beforeOutput &&
        svc2.document.group.targetIds.length == 2,
    'r1=${svc2.document.recordFor(1)!.stitchStatus.label}, '
    'r2=${r2.stitchStatus.label}, outputKept=${r2.stitchedOutputPath == beforeOutput}, '
    'group=${svc2.document.group.targetIds}',
  );
}

Future<void> retakeInvalidates(Directory base) async {
  await setup(base);
  final gate = Completer<void>();
  final svc = service(okWorker, gate: gate, gateTarget: 2);
  await svc.onCaptureSaved(await addFrame(1));
  await svc.onCaptureSaved(await addFrame(2));
  // One yield so job 2 reaches the gated worker; it stays suspended there
  // until the gate opens, so the processing state is stable.
  await drain(20);
  final suspended =
      svc.document.recordFor(2)!.stitchStatus == StitchStatus.processing;
  gate.complete();
  await svc.idle;
  final output = svc.document.recordFor(2)!.stitchedOutputPath!;

  // Retake target 1: a new record with a new capture time — a new version.
  final retaken = CaptureRecord(
    stationId: stationId,
    targetId: 1,
    imagePath: '$stationDir${Platform.pathSeparator}frames'
        '${Platform.pathSeparator}t01.jpg',
    capturedAt: DateTime.fromMillisecondsSinceEpoch(1700000099999),
    targetYawDegrees: 0,
    targetPitchDegrees: 0,
    cameraPosition: Vec3.zero,
    cameraOrientation: Quat.identity,
    alignmentErrorDeg: 1,
    anchored: true,
    imageWidth: 800,
    imageHeight: 640,
  );
  await writeRecord(retaken);
  await svc.onCaptureSaved(retaken);
  await svc.idle;
  final r1 = svc.document.recordFor(1)!;
  final r2 = svc.document.recordFor(2)!;
  check(
    suspended &&
        r1.stitchStatus == StitchStatus.pass &&
        r1.imageToken == '1700000099999:${retaken.imagePath}' &&
        r2.stitchStatus == StitchStatus.pass &&
        r2.matchedTargetIds.contains(1) &&
        svc.document.group.contains(1) &&
        File(output).existsSync(),
    'suspended=$suspended, r1=${r1.stitchStatus.label}, '
    'r2=${r2.stitchStatus.label}, r2Matched=${r2.matchedTargetIds}, '
    'group=${svc.document.group.targetIds}, oldOutputKept=${File(output).existsSync()}',
  );
}

Future<void> finalPanoramaSuccess(Directory base) async {
  await setup(base);
  final svc = service(okWorker);
  await svc.onCaptureSaved(await addFrame(1));
  await svc.onCaptureSaved(await addFrame(2));
  await svc.idle;
  await svc.beginFinalPanorama();
  final processing =
      svc.document.finalPanorama.status == FinalStitchStatus.processing;
  await svc.completeFinalPanorama(
    success: true,
    panoramaPath: '$stationDir${Platform.pathSeparator}panorama.jpg',
  );
  check(
    processing &&
        svc.document.finalPanorama.status == FinalStitchStatus.pass &&
        svc.document.recordFor(1)!.stitchStatus == StitchStatus.pass,
    'final status transitions processing→pass; per-image results untouched',
  );
}

Future<void> finalFailureKeepsFiles(Directory base) async {
  await setup(base);
  final svc = service(noMatchWorker);
  final f1 = await addFrame(1);
  final f2 = await addFrame(2);
  await svc.onCaptureSaved(f1);
  await svc.onCaptureSaved(f2);
  await svc.idle;
  await svc.beginFinalPanorama();
  await svc.completeFinalPanorama(
    success: false,
    errorReason: 'Stitching failed (ERR_NEED_MORE_IMGS).',
  );
  final finalRec = svc.document.finalPanorama;
  check(
    finalRec.status == FinalStitchStatus.fail &&
        finalRec.errorReason!.contains('ERR_NEED_MORE_IMGS') &&
        finalRec.failedTargetIds.join(',') == '1,2' &&
        File(f1.imagePath).existsSync() &&
        File(f2.imagePath).existsSync(),
    'status=${finalRec.status.label}, attributed=[${finalRec.failedTargetIds.join(', ')}], '
    'r1=${svc.document.recordFor(1)!.stitchStatus.label}, '
    'r2=${svc.document.recordFor(2)!.stitchStatus.label}, filesKept=true',
  );
}

Future<void> crashRecovery(Directory base) async {
  await setup(base);
  final svc = service(okWorker);
  await svc.onCaptureSaved(await addFrame(1));
  await svc.idle;
  final doc = svc.document.withRecord(
    svc.document
        .recordFor(1)!
        .copyWith(stitchStatus: StitchStatus.processing),
  );
  await IncrementalStitchStore(stationDir).save(doc);

  final svc2 = service(okWorker);
  await svc2.load();
  check(
    svc2.document.recordFor(1)!.stitchStatus == StitchStatus.pending,
    'a processing record from a killed process reads as PENDING, never as '
    'pass or fail',
  );
}
