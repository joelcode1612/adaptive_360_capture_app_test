import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:adaptive_360_capture_app/features/capture/data/stitch/incremental_stitch_worker.dart';
import 'package:adaptive_360_capture_app/features/capture/data/stitch/stitch_job_models.dart';

/// On-device end-to-end verification of the real OpenCV stitching worker.
///
/// The host machine cannot run `flutter test` (its native-assets build probe
/// is sandbox-blocked), so the real ORB → ratio-test → RANSAC → Stitcher
/// pipeline is verified here, on ARM, with synthetic JPEGs whose overlap is
/// exactly controlled: random noise is maximally textured, so an overlapping
/// crop must register and a disjoint crop must not.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  late Directory workDir;

  /// Renders a `width×640` random scene, crops [x0 … x0+800), optionally
  /// blurs it, encodes it as a real JPEG and returns the file path.
  Future<String> writeCrop({
    required int sceneWidth,
    required int x0,
    required String name,
    int blur = 0,
  }) async {
    final scene = cv.Mat.zeros(640, sceneWidth, cv.MatType.CV_8UC3);
    cv.randu(scene, cv.Scalar(0, 0, 0, 0), cv.Scalar(255, 255, 255, 255));
    cv.Mat? blurred;
    cv.Mat view = scene.colRange(x0, x0 + 800);
    if (blur > 0) {
      blurred = cv.gaussianBlur(view, (31, 31), 0);
      view = blurred;
    }
    final (ok, bytes) = cv.imencode('.jpg', view);
    scene.dispose();
    blurred?.dispose();
    expect(ok, isTrue);
    final file = File(p.join(workDir.path, name));
    await file.writeAsBytes(Uint8List.fromList(bytes));
    return file.path;
  }

  setUp(() async {
    final base = await getTemporaryDirectory();
    workDir = Directory(p.join(base.path, 'stitch_device_test'));
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
    workDir.createSync(recursive: true);
  });

  tearDown(() async {
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  });

  testWidgets('overlapping crops register and stitch on device',
      (WidgetTester tester) async {
    final a = await writeCrop(
      sceneWidth: 2000,
      x0: 0,
      name: 'pair_a.jpg',
    );
    final b = await writeCrop(
      sceneWidth: 2000,
      x0: 500,
      name: 'pair_b.jpg',
    );

    final outcome = await runIncrementalStitchJob(
      StitchJobPacket(
        imagePath: b,
        targetId: 2,
        outputsDir: workDir.path,
        candidates: <StitchCandidatePacket>[
          StitchCandidatePacket(targetId: 1, imagePath: a),
        ],
        groupImages: const <StitchCandidatePacket>[],
        nextOutputIndex: 1,
      ),
    );

    expect(outcome.decodeOk, isTrue, reason: outcome.decodeError);
    expect(outcome.qualityReason, isNull);
    final attempt = outcome.attempts.single;
    expect(attempt.registered, isTrue,
        reason:
            'matches=${attempt.featureMatches} inliers=${attempt.inliers} '
            'reproj=${attempt.meanReprojPx.toStringAsFixed(2)}px');
    expect(attempt.inliers, greaterThanOrEqualTo(12));
    expect(attempt.meanReprojPx, lessThanOrEqualTo(8.0));
    final pairMerge = outcome.pairMerge!;
    expect(pairMerge.ok, isTrue, reason: pairMerge.error);
    expect(File(pairMerge.outputPath!).existsSync(), isTrue);
    expect(File(pairMerge.outputPath!).lengthSync(), greaterThan(5000));
  });

  testWidgets('disjoint crops fail registration on device',
      (WidgetTester tester) async {
    final a = await writeCrop(
      sceneWidth: 2400,
      x0: 0,
      name: 'disjoint_a.jpg',
    );
    final b = await writeCrop(
      sceneWidth: 2400,
      x0: 1600,
      name: 'disjoint_b.jpg',
    );

    final outcome = await runIncrementalStitchJob(
      StitchJobPacket(
        imagePath: b,
        targetId: 2,
        outputsDir: workDir.path,
        candidates: <StitchCandidatePacket>[
          StitchCandidatePacket(targetId: 1, imagePath: a),
        ],
        groupImages: const <StitchCandidatePacket>[],
        nextOutputIndex: 1,
      ),
    );

    expect(outcome.decodeOk, isTrue);
    expect(outcome.qualityReason, isNull, reason: 'the crop is sharp');
    expect(outcome.bestRegistered, isNull,
        reason: 'disjoint noise regions share no real correspondences');
  });

  testWidgets('a blurred capture fails the quality gate on device',
      (WidgetTester tester) async {
    final a = await writeCrop(
      sceneWidth: 2000,
      x0: 0,
      name: 'blur_a.jpg',
      blur: 31,
    );
    final b = await writeCrop(
      sceneWidth: 2000,
      x0: 500,
      name: 'blur_b.jpg',
      blur: 31,
    );

    final outcome = await runIncrementalStitchJob(
      StitchJobPacket(
        imagePath: b,
        targetId: 2,
        outputsDir: workDir.path,
        candidates: <StitchCandidatePacket>[
          StitchCandidatePacket(targetId: 1, imagePath: a),
        ],
        groupImages: const <StitchCandidatePacket>[],
        nextOutputIndex: 1,
      ),
    );

    expect(outcome.decodeOk, isTrue);
    expect(outcome.qualityReason, isNotNull);
    expect(outcome.laplacianVariance, lessThan(30));
    expect(outcome.attempts, isEmpty,
        reason: 'no matching is attempted on an unusable image');
  });

  testWidgets('a new capture merges into an existing group on device',
      (WidgetTester tester) async {
    final group = <StitchCandidatePacket>[];
    for (var i = 0; i < 3; i++) {
      group.add(
        StitchCandidatePacket(
          targetId: i + 1,
          imagePath: await writeCrop(
            sceneWidth: 2600,
            x0: 350 * i,
            name: 'group_${i + 1}.jpg',
          ),
        ),
      );
    }
    final next = await writeCrop(
      sceneWidth: 2600,
      x0: 1050,
      name: 'group_4.jpg',
    );

    final outcome = await runIncrementalStitchJob(
      StitchJobPacket(
        imagePath: next,
        targetId: 4,
        outputsDir: workDir.path,
        candidates: <StitchCandidatePacket>[group.last],
        groupImages: group,
        nextOutputIndex: 4,
      ),
    );

    expect(outcome.decodeOk, isTrue);
    expect(outcome.bestRegistered, isNotNull);
    final groupMerge = outcome.groupMerge!;
    expect(groupMerge.ok, isTrue, reason: groupMerge.error);
    expect(groupMerge.sourceTargetIds, <int>[1, 2, 3, 4]);
    final output = File(groupMerge.outputPath!);
    expect(output.existsSync(), isTrue);
    expect(output.lengthSync(), greaterThan(5000));
  });
}
