import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'package:adaptive_360_capture_app/features/sphere_capture/data/opencv_native_probe.dart';

/// On-device proof that the packaged `libdartcv.so` exports what the panorama
/// pipeline calls.
///
/// ## Why this exists as a device test
///
/// The 38-target panorama failed at the first `cv.cvtColor` with
/// `undefined symbol: cv_cvtColor`, while the app compiled, installed and ran.
/// That is the signature of a *module* compiled out of the native library:
/// `dartcv4`'s build hook replaces its default module set with
/// `hooks.user_defines.dartcv4.include_modules`, so listing `imgcodecs` and
/// `stitching` without `imgproc` silently removes `cvtColor`, `laplacian` and
/// `resize`.
///
/// Nothing on the host can catch that — the symbol only exists in the ARM
/// library that ships in the APK. These tests run against that library, on the
/// device, through the same bindings the stitcher uses.
///
/// Run with:
///   `flutter test integration_test/opencv_native_smoke_test.dart -d <device>`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every required OpenCV module resolves in the shipped library', (
    WidgetTester tester,
  ) async {
    final capabilities = OpenCvNativeProbe.run();
    OpenCvNativeProbe.log(capabilities);
    final missing = OpenCvNativeProbe.missingModules(capabilities);
    expect(
      missing,
      isEmpty,
      reason:
          OpenCvNativeProbe.failureMessage(capabilities) ??
          'Native capability probe reported a gap.',
    );
    // Every module the pipeline depends on must have been probed, not skipped.
    expect(
      capabilities.map((OpenCvCapability c) => c.module).toSet(),
      OpenCvNativeProbe.requiredModules.toSet(),
    );
  });

  testWidgets('imgproc: cvtColor produces a single-channel grey frame', (
    WidgetTester tester,
  ) async {
    // If `imgproc` is missing this throws "Couldn't resolve native function
    // 'cv_cvtColor'", which is exactly the failure this test pins down.
    final src = cv.Mat.fromScalar(
      16,
      16,
      cv.MatType.CV_8UC3,
      cv.Scalar(10, 20, 30),
    );
    final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
    try {
      expect(gray.rows, 16);
      expect(gray.cols, 16);
      expect(gray.channels, 1, reason: 'BGR→grey must collapse to one channel');
      expect(gray.isEmpty, isFalse);
    } finally {
      gray.dispose();
      src.dispose();
    }
  });

  testWidgets('imgproc: resize and laplacian resolve and run', (
    WidgetTester tester,
  ) async {
    final src = cv.Mat.zeros(32, 32, cv.MatType.CV_8UC1);
    final small = cv.resize(src, (16, 16));
    final lap = cv.laplacian(small, cv.MatType.CV_32F);
    try {
      expect(small.cols, 16);
      expect(small.rows, 16);
      expect(lap.isEmpty, isFalse);
    } finally {
      lap.dispose();
      small.dispose();
      src.dispose();
    }
  });

  testWidgets('imgcodecs: a JPEG encodes and decodes back to the same size', (
    WidgetTester tester,
  ) async {
    final src = cv.Mat.fromScalar(
      24,
      32,
      cv.MatType.CV_8UC3,
      cv.Scalar(120, 130, 140),
    );
    try {
      final (encoded, bytes) = cv.imencode('.jpg', src);
      expect(encoded, isTrue);
      expect(bytes, isNotEmpty);

      final decoded = cv.imdecode(bytes, cv.IMREAD_COLOR);
      try {
        expect(decoded.cols, 32);
        expect(decoded.rows, 24);
        expect(decoded.channels, 3);
      } finally {
        decoded.dispose();
      }
    } finally {
      src.dispose();
    }
  });

  testWidgets('features2d: ORB creates and detects', (
    WidgetTester tester,
  ) async {
    final orb = cv.ORB.create(nFeatures: 100);
    final src = cv.Mat.zeros(64, 64, cv.MatType.CV_8UC1);
    try {
      // Zeros hold no corners; the assertion is that the native call returns
      // rather than failing to resolve cv_ORB_create / cv_ORB_detect.
      final keypoints = orb.detect(src);
      expect(keypoints.length, 0);
    } finally {
      src.dispose();
      orb.dispose();
    }
  });

  testWidgets('stitching: Stitcher initialises in PANORAMA mode', (
    WidgetTester tester,
  ) async {
    // The panorama engine itself. Creating it touches cv_Stitcher_create, which
    // is the symbol that must survive for a 2:1 panorama to be attempted at all.
    final stitcher = cv.Stitcher.create(mode: cv.StitcherMode.PANORAMA);
    stitcher.dispose();
  });

  testWidgets('calib3d: findHomography resolves', (WidgetTester tester) async {
    final src = cv.VecPoint2f.fromList(<cv.Point2f>[
      cv.Point2f(0, 0),
      cv.Point2f(10, 0),
      cv.Point2f(10, 10),
      cv.Point2f(0, 10),
    ]);
    final dst = cv.VecPoint2f.fromList(<cv.Point2f>[
      cv.Point2f(1, 1),
      cv.Point2f(21, 1),
      cv.Point2f(21, 21),
      cv.Point2f(1, 21),
    ]);
    final h = cv.findHomography(cv.Mat.fromVec(src), cv.Mat.fromVec(dst));
    try {
      expect(h.isEmpty, isFalse, reason: 'four exact correspondences must fit');
    } finally {
      h.dispose();
    }
  });
}
