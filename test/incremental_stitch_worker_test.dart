import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/data/stitch/incremental_stitch_worker.dart';
import 'package:adaptive_360_capture_app/features/capture/data/stitch/stitch_job_models.dart';

/// Real OpenCV tests for the incremental stitching worker.
///
/// These exercise the actual native pipeline — ORB detection, ratio-test
/// matching, RANSAC homography and [cv.Stitcher] — against committed JPEG
/// fixtures whose overlap relationships are exactly known (see
/// `tool/generate_stitch_fixtures.py`). They require the opencv_dart native
/// build, so they only run where the toolchain can compile it.
void main() {
  late Directory outputs;

  String fixture(String name) =>
      p.join(Directory.current.path, 'test', 'fixtures', 'stitch', name);

  setUp(() async {
    outputs = await Directory.systemTemp.createTemp('stitch_worker_test');
  });

  tearDown(() async {
    if (await outputs.exists()) {
      await outputs.delete(recursive: true);
    }
  });

  StitchJobPacket packet({
    required String imagePath,
    required int targetId,
    required List<StitchCandidatePacket> candidates,
    List<StitchCandidatePacket> groupImages = const <StitchCandidatePacket>[],
    int nextOutputIndex = 1,
  }) => StitchJobPacket(
    imagePath: imagePath,
    targetId: targetId,
    outputsDir: outputs.path,
    candidates: candidates,
    groupImages: groupImages,
    nextOutputIndex: nextOutputIndex,
  );

  test('two overlapping photographs register and stitch (real ORB + Stitcher)',
      () async {
    final outcome = await runIncrementalStitchJob(
      packet(
        imagePath: fixture('pair_b.jpg'),
        targetId: 2,
        candidates: <StitchCandidatePacket>[
          StitchCandidatePacket(targetId: 1, imagePath: fixture('pair_a.jpg')),
        ],
      ),
    );

    expect(outcome.decodeOk, isTrue, reason: outcome.decodeError);
    expect(outcome.qualityReason, isNull);
    expect(outcome.laplacianVariance, greaterThan(30));
    final attempt = outcome.attempts.single;
    expect(attempt.candidateTargetId, 1);
    expect(attempt.featureMatches, greaterThanOrEqualTo(20),
        reason: 'the fixtures share a 300 px textured band');
    expect(attempt.registered, isTrue,
        reason:
            'matches=${attempt.featureMatches} inliers=${attempt.inliers} '
            'reproj=${attempt.meanReprojPx}');
    expect(attempt.inliers, greaterThanOrEqualTo(12));
    expect(attempt.meanReprojPx, lessThanOrEqualTo(8.0));
    expect(attempt.overlapFraction, greaterThan(0.05));

    // The pairwise merge produced a real, non-trivial JPEG.
    final pairMerge = outcome.pairMerge;
    expect(pairMerge, isNotNull);
    expect(pairMerge!.ok, isTrue, reason: pairMerge.error);
    expect(pairMerge.stitcherStatus, 'OK');
    final output = File(pairMerge.outputPath!);
    expect(output.existsSync(), isTrue);
    expect(output.lengthSync(), greaterThan(10000));
  });

  test('two disjoint photographs fail registration with measured numbers',
      () async {
    final outcome = await runIncrementalStitchJob(
      packet(
        imagePath: fixture('no_overlap_b.jpg'),
        targetId: 2,
        candidates: <StitchCandidatePacket>[
          StitchCandidatePacket(
            targetId: 1,
            imagePath: fixture('no_overlap_a.jpg'),
          ),
        ],
      ),
    );

    expect(outcome.decodeOk, isTrue);
    expect(outcome.qualityReason, isNull, reason: 'the image is sharp');
    expect(outcome.bestRegistered, isNull,
        reason: 'disjoint scene regions share no features');
    expect(outcome.attempts.single.registered, isFalse);
    expect(outcome.groupMerge, isNull, reason: 'no merge without registration');
    expect(outcome.pairMerge, isNull);
  });

  test('a blurred photograph fails the quality gate before matching',
      () async {
    final outcome = await runIncrementalStitchJob(
      packet(
        imagePath: fixture('blur_b.jpg'),
        targetId: 2,
        candidates: <StitchCandidatePacket>[
          StitchCandidatePacket(targetId: 1, imagePath: fixture('blur_a.jpg')),
        ],
      ),
    );

    expect(outcome.decodeOk, isTrue);
    expect(outcome.qualityReason, isNotNull);
    expect(outcome.qualityReason, contains('blurry'));
    expect(outcome.laplacianVariance, lessThan(30));
    expect(outcome.attempts, isEmpty,
        reason: 'no matching was attempted on an unusable image');
  });

  test('a new image merges into an existing stitched group', () async {
    final outcome = await runIncrementalStitchJob(
      packet(
        imagePath: fixture('strip_4.jpg'),
        targetId: 4,
        candidates: <StitchCandidatePacket>[
          StitchCandidatePacket(
            targetId: 3,
            imagePath: fixture('strip_3.jpg'),
          ),
        ],
        groupImages: <StitchCandidatePacket>[
          StitchCandidatePacket(targetId: 1, imagePath: fixture('strip_1.jpg')),
          StitchCandidatePacket(targetId: 2, imagePath: fixture('strip_2.jpg')),
          StitchCandidatePacket(targetId: 3, imagePath: fixture('strip_3.jpg')),
        ],
        nextOutputIndex: 4,
      ),
    );

    expect(outcome.decodeOk, isTrue);
    final attempt = outcome.attempts.single;
    expect(attempt.registered, isTrue,
        reason:
            'matches=${attempt.featureMatches} inliers=${attempt.inliers}');
    final groupMerge = outcome.groupMerge!;
    expect(groupMerge.ok, isTrue, reason: groupMerge.error ?? 'status unknown');
    expect(groupMerge.sourceTargetIds, <int>[1, 2, 3, 4]);
    expect(groupMerge.stitcherStatus, 'OK');
    final output = File(groupMerge.outputPath!);
    expect(output.existsSync(), isTrue);
    expect(output.lengthSync(), greaterThan(10000),
        reason: 'the group output is a real image, not a placeholder');
  });

  test('a missing file fails decoding with a clear reason', () async {
    final outcome = await runIncrementalStitchJob(
      packet(
        imagePath: p.join(outputs.path, 'missing.jpg'),
        targetId: 9,
        candidates: const <StitchCandidatePacket>[],
      ),
    );
    expect(outcome.decodeOk, isFalse);
    expect(outcome.decodeError, contains('missing'));
  });
}
