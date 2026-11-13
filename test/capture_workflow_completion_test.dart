import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panorama_viewer/panorama_viewer.dart';
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/application/panorama_generation_service.dart';
import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';
import 'package:adaptive_360_capture_app/features/capture/presentation/screens/ar_capture_flow_screen.dart';
import 'package:adaptive_360_capture_app/features/capture/presentation/screens/ar_capture_screen.dart';
import 'package:adaptive_360_capture_app/features/capture/presentation/screens/capture_review_screen.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

// End-to-end verification for the NEW 26-target completion workflow: capture
// completes → records validated → stitcher handed the ordered paths →
// panorama stored → review/preview → retry/retake. The workflow's *capture*
// half is pinned by the existing suites and is not re-tested here: channel
// startup and pose parsing (ar_capture_integration_test.dart), anchor
// placement and rollback (capture_calibration_transaction_test.dart,
// capture_progress_test.dart), 26-target geometry and alignment
// (target_scale_test.dart, alignment_test.dart), hold progress, shutter
// eligibility and duplicate prevention (capture_state_gates_test.dart,
// capture_persistence_test.dart). The stitcher itself is always faked here —
// a mocked stitch proves the wiring, never OpenCV's own reliability, which
// only a real device run can speak to (NOT TESTED in this workspace).

/// A stitcher that records every hand-off and answers from a script.
/// Its default success mimics the real OpenCV stitcher's one layout
/// contract: the panorama is written beside the station metadata.
class _RecordingStitcher implements PanoramaStitcher {
  final List<List<String>> calls = <List<String>>[];

  /// Blocks [stitchFrames] until resolved — the once-only test needs a
  /// cycle that is genuinely in flight, not one that finished first.
  Completer<void>? gate;

  StitchResult? scriptResult;

  /// Invoked after [gate] releases, before the scripted result is answered.
  void Function(List<String> paths)? onStitch;

  @override
  Future<StitchResult> stitchFrames(
    List<String> imagePaths, {
    void Function(String stage)? onStage,
  }) async {
    calls.add(List<String>.of(imagePaths));
    if (gate != null) await gate!.future;
    onStitch?.call(imagePaths);
    final scripted = scriptResult;
    if (scripted != null) return scripted;
    final outPath = p.join(
      p.dirname(p.dirname(imagePaths.first)),
      'panorama.jpg',
    );
    await File(outPath).writeAsBytes(const [1, 2, 3, 4]);
    return StitchResult(
      success: true,
      panoramaPath: outPath,
      message: 'Panorama generated successfully.',
    );
  }
}

void main() {
  late Directory root;
  late FileCaptureRepository repository;
  const stationId = 's1';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('capture_workflow');
    repository = FileCaptureRepository(root.path);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  CaptureRecord record(int targetId, String imagePath) => CaptureRecord(
    stationId: stationId,
    targetId: targetId,
    imagePath: imagePath,
    capturedAt: DateTime.utc(2026, 1, 1, 12, targetId),
    targetYawDegrees: 0,
    targetPitchDegrees: 45,
    cameraPosition: Vec3.zero,
    cameraOrientation: Quat.identity,
    alignmentErrorDeg: 0.4,
    anchored: true,
    imageWidth: 1920,
    imageHeight: 1080,
  );

  /// Writes the frame file the record claims, so the set is complete.
  Future<String> writeFrame(int targetId) async {
    final path = await repository.framePath(stationId, targetId);
    await File(path).create(recursive: true);
    await File(path).writeAsBytes(List<int>.filled(64, targetId));
    return path;
  }

  Future<List<CaptureRecord>> completeSet() async {
    final records = <CaptureRecord>[];
    for (var id = 1; id <= 26; id++) {
      records.add(record(id, await writeFrame(id)));
    }
    return records;
  }

  Future<void> saveAll(List<CaptureRecord> records) async {
    for (final CaptureRecord r in records) {
      await repository.saveRecord(r);
    }
  }

  String stationDirectory() => p.join(root.path, stationId);

  Future<ui.Image> solidImage() async {
    final recorder = ui.PictureRecorder();
    Canvas(
      recorder,
    ).drawRect(const Rect.fromLTWH(0, 0, 4, 2), Paint()..color = Colors.black);
    return recorder.endRecording().toImage(4, 2);
  }

  group('PanoramaGenerationService', () {
    test('the stitcher receives the 26 saved paths in capture order', () async {
      final records = await completeSet();
      final stitcher = _RecordingStitcher();

      final result = await PanoramaGenerationService(
        stitcher,
      ).generate(records: records, total: 26);

      expect(result.success, isTrue, reason: result.message);
      expect(stitcher.calls, hasLength(1));
      final ordered = stitcher.calls.single;
      expect(ordered, hasLength(26));
      for (var i = 0; i < 26; i++) {
        expect(
          p.basename(ordered[i]),
          't${(i + 1).toString().padLeft(2, '0')}.jpg',
          reason: 'target ${i + 1} must be stitched at position ${i + 1}',
        );
      }
    });

    test(
      'an incomplete set is rejected with the missing targets named',
      () async {
        final records = <CaptureRecord>[];
        for (var id = 1; id <= 24; id++) {
          records.add(record(id, await writeFrame(id)));
        }
        final stitcher = _RecordingStitcher();

        final result = await PanoramaGenerationService(
          stitcher,
        ).generate(records: records, total: 26);

        expect(result.success, isFalse);
        expect(result.message, contains('24/26'));
        expect(result.message, contains('Missing targets: 25, 26'));
        expect(stitcher.calls, isEmpty);
      },
    );

    test('a duplicate record is rejected', () async {
      final path = await writeFrame(5);
      final stitcher = _RecordingStitcher();

      final result = await PanoramaGenerationService(
        stitcher,
      ).generate(records: [record(5, path), record(5, path)], total: 26);

      expect(result.success, isFalse);
      expect(result.message, contains('Duplicate capture record for target 5'));
      expect(stitcher.calls, isEmpty);
    });

    test('a record outside the target range is rejected', () async {
      final path = await writeFrame(1);
      final stitcher = _RecordingStitcher();

      final result = await PanoramaGenerationService(
        stitcher,
      ).generate(records: [record(27, path)], total: 26);

      expect(result.success, isFalse);
      expect(result.message, contains('outside the 1–26 target range'));
      expect(stitcher.calls, isEmpty);
    });

    test('a missing JPEG names the target and the file', () async {
      final records = await completeSet();
      await File(records[8].imagePath).delete();
      final stitcher = _RecordingStitcher();

      final result = await PanoramaGenerationService(
        stitcher,
      ).generate(records: records, total: 26);

      expect(result.success, isFalse);
      expect(result.message, contains('target 9'));
      expect(result.message, contains(records[8].imagePath));
      expect(stitcher.calls, isEmpty);
    });

    test('two records sharing one image file are rejected', () async {
      final paths = <int, String>{};
      for (var id = 1; id <= 26; id++) {
        paths[id] = await writeFrame(id);
      }
      final records = <CaptureRecord>[];
      for (var id = 1; id <= 26; id++) {
        records.add(record(id, id == 4 ? paths[3]! : paths[id]!));
      }
      final stitcher = _RecordingStitcher();

      final result = await PanoramaGenerationService(
        stitcher,
      ).generate(records: records, total: 26);

      expect(result.success, isFalse);
      expect(result.message, contains('one image file'));
      expect(stitcher.calls, isEmpty);
    });

    test(
      'a failed stitch preserves every source JPEG and stores no path',
      () async {
        final records = await completeSet();
        await saveAll(records);
        final stitcher = _RecordingStitcher()
          ..scriptResult = const StitchResult.failure(
            'Stitching failed (NEED_MORE_OVERLAP). Keep the frames and retry.',
          );

        final result = await PanoramaGenerationService(
          stitcher,
        ).generate(records: records, total: 26);

        expect(result.success, isFalse);
        expect(result.message, contains('Stitching failed'));
        for (final CaptureRecord r in records) {
          expect(
            await File(r.imagePath).exists(),
            isTrue,
            reason: 'target ${r.targetId} must survive a failed stitch',
          );
        }
        expect(
          await File(p.join(stationDirectory(), 'panorama.json')).exists(),
          isFalse,
        );
      },
    );

    test(
      'a generated panorama has its output path recorded beside it',
      () async {
        final records = await completeSet();
        final stitcher = _RecordingStitcher();

        final result = await PanoramaGenerationService(
          stitcher,
        ).generate(records: records, total: 26);

        expect(result.success, isTrue, reason: result.message);
        expect(await File(result.panoramaPath!).exists(), isTrue);
        final meta =
            jsonDecode(
                  await File(
                    p.join(stationDirectory(), 'panorama.json'),
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        expect(meta['panoramaPath'], result.panoramaPath);
        expect(meta['frameCount'], 26);
        expect(meta['stationId'], stationId);
      },
    );

    test('a success without a panorama path is treated as failure', () async {
      final records = await completeSet();
      final stitcher = _RecordingStitcher()
        ..scriptResult = const StitchResult(
          success: true,
          panoramaPath: null,
          message: 'ok',
        );

      final result = await PanoramaGenerationService(
        stitcher,
      ).generate(records: records, total: 26);

      expect(result.success, isFalse);
    });
  });

  group('StitchHandoff', () {
    test(
      'a second completion signal while running does not stitch twice',
      () async {
        final records = await completeSet();
        await saveAll(records);
        final stitcher = _RecordingStitcher()..gate = Completer<void>();
        var started = 0;
        var succeeded = 0;
        final handoff = StitchHandoff(
          service: PanoramaGenerationService(stitcher),
          total: 26,
          loadRecords: () => repository.loadRecords(stationId),
          onStarted: () => started++,
          onStage: (_) {},
          onSuccess: () => succeeded++,
          onFailure: (_) => fail('the first completion must succeed'),
        );

        final first = handoff.complete();
        // The second signal arrives while the first cycle is in flight —
        // exactly what a double-fired completion event looks like.
        await handoff.complete();
        stitcher.gate!.complete();
        await first;

        expect(stitcher.calls, hasLength(1));
        expect(started, 1);
        expect(succeeded, 1);
        expect(handoff.running, isFalse);
      },
    );

    test('after a failure a retry runs again against fresh records', () async {
      final records = await completeSet();
      await saveAll(records);
      final stitcher = _RecordingStitcher()
        ..scriptResult = const StitchResult.failure('Stitching failed.');
      final failures = <String>[];
      var succeeded = 0;
      var loads = 0;
      final handoff = StitchHandoff(
        service: PanoramaGenerationService(stitcher),
        total: 26,
        loadRecords: () {
          loads++;
          return repository.loadRecords(stationId);
        },
        onStarted: () {},
        onStage: (_) {},
        onSuccess: () => succeeded++,
        onFailure: failures.add,
      );

      await handoff.complete();
      expect(failures, ['Stitching failed.']);
      expect(handoff.running, isFalse, reason: 'a failure must allow a retry');

      stitcher.scriptResult = null;
      await handoff.complete();
      expect(succeeded, 1);
      expect(loads, 2, reason: 'each retry re-reads what is on disk now');
      expect(stitcher.calls, hasLength(2));
    });
  });

  group('CaptureReviewScreen', () {
    testWidgets('the gallery lists every target and names the missing ones', (
      tester,
    ) async {
      for (var id = 1; id <= 24; id++) {
        final path = await writeFrame(id);
        await repository.saveRecord(record(id, path));
      }

      await tester.pumpWidget(
        MaterialApp(
          home: CaptureReviewScreen(
            repository: repository,
            stationId: stationId,
            stitcher: _RecordingStitcher(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Photographs (24/26)'), findsOneWidget);
      expect(find.textContaining('Missing targets: 25, 26'), findsOneWidget);
      // The gallery is built from the target specification, not from the
      // records, so the missing targets still have cells — with a warning.
      expect(find.text('1 · Horizontal 1'), findsOneWidget);
      expect(find.text('25 · Zenith'), findsOneWidget);
      expect(find.text('26 · Nadir'), findsOneWidget);
      expect(find.byIcon(Icons.image_not_supported_outlined), findsNWidgets(2));
    });

    testWidgets('a stored panorama opens in the 360 viewer', (tester) async {
      final records = await completeSet();
      await saveAll(records);
      final image = await solidImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final panoramaPath = p.join(stationDirectory(), 'panorama.jpg');
      await File(panoramaPath).writeAsBytes(png!.buffer.asUint8List());
      await File(p.join(stationDirectory(), 'panorama.json')).writeAsString(
        jsonEncode(<String, Object?>{
          'stationId': stationId,
          'panoramaPath': panoramaPath,
          'frameCount': 26,
          'generatedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          'message': 'Panorama generated successfully.',
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CaptureReviewScreen(
            repository: repository,
            stationId: stationId,
            stitcher: _RecordingStitcher(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('All 26 photographs saved.'), findsOneWidget);
      expect(find.byType(PanoramaViewer), findsOneWidget);
    });

    testWidgets('retry stitching reports failure and preserves photographs', (
      tester,
    ) async {
      for (var id = 1; id <= 24; id++) {
        final path = await writeFrame(id);
        await repository.saveRecord(record(id, path));
      }
      final stitcher = _RecordingStitcher();

      await tester.pumpWidget(
        MaterialApp(
          home: CaptureReviewScreen(
            repository: repository,
            stationId: stationId,
            stitcher: stitcher,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retry stitching'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Only 24/26'), findsOneWidget);
      expect(find.byType(PanoramaViewer), findsNothing);
      for (var id = 1; id <= 24; id++) {
        final path = await repository.framePath(stationId, id);
        expect(
          await File(path).exists(),
          isTrue,
          reason: 'a rejected stitch must not touch target $id',
        );
      }
    });

    testWidgets('a successful retry shows the panorama without recapturing', (
      tester,
    ) async {
      final records = await completeSet();
      await saveAll(records);
      final stitcher = _RecordingStitcher()
        ..scriptResult = const StitchResult.failure('Stitching failed.');

      await tester.pumpWidget(
        MaterialApp(
          home: CaptureReviewScreen(
            repository: repository,
            stationId: stationId,
            stitcher: stitcher,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry stitching'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Stitching failed'), findsOneWidget);

      // Second attempt: the default script writes the real panorama file and
      // reports success, exactly as a retake-free retry would on device.
      stitcher.scriptResult = null;
      await tester.tap(find.text('Retry stitching'));
      await tester.pumpAndSettle();

      expect(find.byType(PanoramaViewer), findsOneWidget);
      expect(find.text('Regenerate panorama'), findsOneWidget);
      for (final CaptureRecord r in records) {
        expect(await File(r.imagePath).exists(), isTrue);
      }
    });

    testWidgets('retake reopens the capture screen for the same station', (
      tester,
    ) async {
      final records = await completeSet();
      await saveAll(records);

      await tester.pumpWidget(
        MaterialApp(
          home: CaptureReviewScreen(
            repository: repository,
            stationId: stationId,
            stitcher: _RecordingStitcher(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retake photographs'));
      // The capture screen boots against unmocked platform channels and lands
      // on its own error UI — pumping fixed amounts, because its probing UI
      // may animate without ever settling in a test environment.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(ArCaptureFlowScreen), findsOneWidget);
      expect(find.byType(CaptureModuleScreen), findsOneWidget);
      // The review screen is replaced, not stacked — nothing to pop back to.
      expect(find.byType(CaptureReviewScreen), findsNothing);
    });
  });
}
