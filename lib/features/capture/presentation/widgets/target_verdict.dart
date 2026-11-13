import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_target.dart';

/// The state of one target in the markerless 26-target capture flow.
///
/// Surface probes are not a readiness input. Every target is computed from the
/// calibrated station frame and shares the same world-space anchor.
enum TargetVerdict {
  /// A photograph was accepted and recorded.
  saved,

  /// A capture attempt failed and may be retried.
  failed,

  /// The AR world reference is unavailable or this target has no placement.
  referenceLost,

  /// Placed below the shared station anchor, but not selected.
  ready,

  /// The target currently being guided towards.
  active;

  bool get isActionable => this == ready || this == active;
}

/// The target's capture state, independent of any physical surface detection.
({TargetVerdict verdict, String? detail}) targetVerdict(
  CaptureTarget target, {
  required bool referenceAvailable,
}) {
  if (target.status.isDone) {
    final file = target.imagePath;
    return (
      verdict: TargetVerdict.saved,
      detail: file == null ? null : 'photo ${_basename(file)}',
    );
  }
  if (target.status == CaptureTargetStatus.failed) {
    return (
      verdict: TargetVerdict.failed,
      detail: target.message ?? 'Capture failed; re-aim and retry.',
    );
  }
  if (!referenceAvailable || !target.isAnchored) {
    return (
      verdict: TargetVerdict.referenceLost,
      detail: 'Waiting for a verified shared station reference.',
    );
  }
  final active = target.status == CaptureTargetStatus.active;
  return (
    verdict: active ? TargetVerdict.active : TargetVerdict.ready,
    detail: 'Computed from the station-local target geometry.',
  );
}

String _basename(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf('\\');
  final cut = slash > backslash ? slash : backslash;
  return cut < 0 ? path : path.substring(cut + 1);
}
