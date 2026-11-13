/// Boundary for panorama generation.
///
/// Ported from the FYP `shared_logic` service so the standalone app owns the
/// contract locally, without carrying any of the SiteWise tour entities the
/// original package mixes it with. Implementations (the on-device OpenCV
/// stitcher, and the fake the tests inject) report honest high-level stages —
/// never faked percentages — and must never mutate the source photographs.
abstract class PanoramaStitcher {
  Future<StitchResult> stitchFrames(
    List<String> imagePaths, {
    void Function(String stage)? onStage,
  });
}

class StitchResult {
  final bool success;

  /// Absolute path of the generated panorama, `null` on failure.
  final String? panoramaPath;

  /// The sentence the user reads: what happened, or what to do next.
  final String message;

  const StitchResult({
    required this.success,
    this.panoramaPath,
    required this.message,
  });

  const StitchResult.failure(this.message)
    : success = false,
      panoramaPath = null;
}
