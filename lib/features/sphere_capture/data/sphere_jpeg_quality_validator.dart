import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/quality/decision_rules.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/quality/image_analysis.dart';

/// Checks the *saved JPEG*, not merely the preview. A valid low-detail wall
/// produces a warning, while a blurry textured photograph requests a retake.
/// This lives outside the controller so injected fakes remain native-free.
class SphereJpegQualityValidator {
  const SphereJpegQualityValidator();

  /// Camera/device-specific; calibrate against actual sharp and blurred photos.
  static const double minSharpness = double.fromEnvironment(
    'sphere_min_laplacian_variance', defaultValue: 25,
  );

  Future<QualityDecision> validate(Uint8List jpeg) async {
    cv.Mat? gray;
    try {
      gray = cv.imdecode(jpeg, cv.IMREAD_REDUCED_GRAYSCALE_4);
      if (gray.isEmpty || gray.cols < 8 || gray.rows < 8) {
        return const QualityDecision(
          ok: false,
          code: QualityRejection.camera,
          message: 'The photograph could not be decoded. Retake this target.',
        );
      }
      final count = gray.cols * gray.rows;
      final pixels = gray.data;
      if (pixels.length < count) {
        return const QualityDecision(
          ok: false,
          code: QualityRejection.camera,
          message: 'The photograph is incomplete. Retake this target.',
        );
      }
      final values = Float64List(count);
      for (var i = 0; i < count; i++) {
        values[i] = pixels[i].toDouble();
      }
      final stats = analyzeGray(values, gray.cols, gray.rows);
      // More tolerant than the provisional virtual-tour defaults because this
      // analysis runs at quarter decode and includes flat walls and ceilings.
      return decideQuality(
        stats,
        const QualityThresholds(
          darkMean: 36,
          brightMean: 229,
          saturatedShare: 0.32,
          sharpness: minSharpness,
          texture: 0.025,
        ),
      );
    } catch (error) {
      return QualityDecision(
        ok: false,
        code: QualityRejection.camera,
        message: 'Unable to check the photograph: $error. Retake this target.',
      );
    } finally {
      gray?.dispose();
    }
  }
}
