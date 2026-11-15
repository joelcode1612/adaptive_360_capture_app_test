import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/capture/domain/stitch/incremental_stitch_models.dart';

void main() {
  group('ImageStitchRecord', () {
    test('JSON round trip keeps every metric', () {
      final record = ImageStitchRecord(
        targetId: 2,
        stitchStatus: StitchStatus.pass,
        matchedTargetIds: const <int>[1],
        featureMatches: 340,
        inliers: 95,
        inlierRatio: 0.28,
        registrationErrorPx: 1.8,
        overlapFraction: 0.42,
        laplacianVariance: 410.2,
        brightness: 128.0,
        stitcherStatus: 'OK',
        stitchedOutputPath: '/station/stitched_outputs/stitch_002.jpg',
        imageToken: '1700000000:/station/frames/t02.jpg',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        attempts: 1,
      );

      final restored = ImageStitchRecord.fromJson(record.toJson());
      expect(restored.targetId, 2);
      expect(restored.stitchStatus, StitchStatus.pass);
      expect(restored.matchedTargetIds, <int>[1]);
      expect(restored.featureMatches, 340);
      expect(restored.inliers, 95);
      expect(restored.inlierRatio, closeTo(0.28, 1e-9));
      expect(restored.registrationErrorPx, closeTo(1.8, 1e-9));
      expect(restored.overlapFraction, closeTo(0.42, 1e-9));
      expect(restored.laplacianVariance, closeTo(410.2, 1e-9));
      expect(restored.brightness, 128.0);
      expect(restored.stitcherStatus, 'OK');
      expect(restored.stitchedOutputPath, '/station/stitched_outputs/stitch_002.jpg');
      expect(restored.imageToken, '1700000000:/station/frames/t02.jpg');
      expect(
        restored.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(restored.attempts, 1);
    });

    test('a failed record carries its reason through JSON', () {
      final record = ImageStitchRecord(
        targetId: 3,
        stitchStatus: StitchStatus.fail,
        errorReason: 'Registration failed against target 2: 8 inliers.',
        imageToken: 't3',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final restored = ImageStitchRecord.fromJson(record.toJson());
      expect(restored.stitchStatus, StitchStatus.fail);
      expect(restored.errorReason, contains('8 inliers'));
      expect(restored.featureMatches, isNull,
          reason: 'metrics stay absent when they were never measured');
    });

    test('copyWith clears nullable metrics with explicit nulls', () {
      final record = ImageStitchRecord(
        targetId: 1,
        stitchStatus: StitchStatus.fail,
        inliers: 4,
        errorReason: 'too few',
        imageToken: 'a',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ).copyWith(
        stitchStatus: StitchStatus.pending,
        inliers: null,
        errorReason: null,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(5),
      );
      expect(record.stitchStatus, StitchStatus.pending);
      expect(record.inliers, isNull);
      expect(record.errorReason, isNull);
      expect(record.updatedAt, DateTime.fromMillisecondsSinceEpoch(5));
    });
  });

  group('StitchGroupState', () {
    test('addMember appends and records the output path', () {
      const group = StitchGroupState();
      final g2 = group.addMember(1, '/out/stitch_001.jpg');
      final g3 = g2.addMember(2, '/out/stitch_002.jpg');
      expect(g3.targetIds, <int>[1, 2]);
      expect(g3.outputPath, '/out/stitch_002.jpg');
    });

    test('dropMember removes exactly one member and clears the output', () {
      const group = StitchGroupState(
        targetIds: <int>[1, 2, 3],
        outputPath: '/out/stitch_003.jpg',
      );
      final dropped = group.dropMember(2);
      expect(dropped.targetIds, <int>[1, 3]);
      expect(dropped.outputPath, isNull,
          reason: 'the old output no longer describes the group');
      expect(group.contains(2), isTrue, reason: 'the original is unchanged');
    });
  });

  group('StitchResultsDocument', () {
    test('JSON round trip preserves records, group and final status', () {
      final doc = StitchResultsDocument(
        stationId: 'st1',
        records: <int, ImageStitchRecord>{
          1: ImageStitchRecord(
            targetId: 1,
            stitchStatus: StitchStatus.pass,
            imageToken: 't1',
            updatedAt: DateTime.fromMillisecondsSinceEpoch(1),
          ),
          2: ImageStitchRecord(
            targetId: 2,
            stitchStatus: StitchStatus.fail,
            errorReason: 'decode failed',
            imageToken: 't2',
            updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
          ),
        },
        group: const StitchGroupState(
          targetIds: <int>[1],
          outputPath: '/out/stitch_001.jpg',
        ),
        intermediates: <IntermediateStitch>[
          IntermediateStitch(
            path: '/out/stitch_001.jpg',
            sourceTargetIds: const <int>[1, 2],
            createdAt: DateTime.fromMillisecondsSinceEpoch(3),
          ),
        ],
        finalPanorama: FinalPanoramaRecord(
          status: FinalStitchStatus.fail,
          errorReason: 'Stitching failed (ERR_NEED_MORE_IMGS).',
          failedTargetIds: const <int>[2],
          updatedAt: DateTime.fromMillisecondsSinceEpoch(4),
        ),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(5),
      );

      final restored = StitchResultsDocument.fromJson(doc.toJson());
      expect(restored.stationId, 'st1');
      expect(restored.records.length, 2);
      expect(restored.records[2]!.errorReason, 'decode failed');
      expect(restored.group.targetIds, <int>[1]);
      expect(restored.intermediates.single.sourceTargetIds, <int>[1, 2]);
      expect(restored.finalPanorama.status, FinalStitchStatus.fail);
      expect(restored.finalPanorama.failedTargetIds, <int>[2]);
    });

    test('counts classify every record exactly once', () {
      final doc = StitchResultsDocument(
        stationId: 'st1',
        records: <int, ImageStitchRecord>{
          for (final entry in <int, StitchStatus>{
            1: StitchStatus.pass,
            2: StitchStatus.pass,
            3: StitchStatus.fail,
            4: StitchStatus.pending,
            5: StitchStatus.processing,
          }.entries)
            entry.key: ImageStitchRecord(
              targetId: entry.key,
              stitchStatus: entry.value,
              imageToken: 't${entry.key}',
              updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
            ),
        },
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(doc.passCount, 2);
      expect(doc.failCount, 1);
      expect(doc.pendingCount, 1);
      expect(doc.processingCount, 1);
    });

    test('latestPreviewPath prefers the final panorama', () {
      final withFinal = StitchResultsDocument(
        stationId: 's',
        intermediates: <IntermediateStitch>[
          IntermediateStitch(
            path: '/out/intermediate.jpg',
            sourceTargetIds: const <int>[1],
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        ],
        finalPanorama: FinalPanoramaRecord(
          status: FinalStitchStatus.pass,
          panoramaPath: '/out/panorama.jpg',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(withFinal.latestPreviewPath, '/out/panorama.jpg');

      final withoutFinal = StitchResultsDocument(
        stationId: 's',
        intermediates: withFinal.intermediates,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(withoutFinal.latestPreviewPath, '/out/intermediate.jpg');
    });
  });
}
