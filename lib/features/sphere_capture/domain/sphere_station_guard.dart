import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Conservative 6DoF station-position gate. Rotation alone cannot measure
/// translation, so it must only be enabled when the camera supplies AR poses.
/// Distances are 3D metres and include movement up/down, not just walking.
class SphereStationGuard {
  SphereStationGuard({this.maxDisplacementM = 0.12});

  final double maxDisplacementM;
  Vec3? _origin;
  bool _tracking = false;
  double? _distance;

  bool get hasOrigin => _origin != null;
  bool get tracking => _tracking;
  double? get displacementM => _distance;
  bool get canCapture =>
      _tracking && _origin != null && _distance != null &&
      _distance! <= maxDisplacementM;

  void update({required Vec3 position, required bool tracking}) {
    _tracking = tracking;
    if (!tracking) {
      _distance = null;
      return;
    }
    _origin ??= position;
    final from = _origin!;
    final dx = position.x - from.x;
    final dy = position.y - from.y;
    final dz = position.z - from.z;
    _distance = math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  void reset() {
    _origin = null;
    _tracking = false;
    _distance = null;
  }

  String? get message {
    if (_origin == null) return 'AR is finding the capture station. Hold still.';
    if (!_tracking) return 'AR tracking was lost. Point at a detailed part of the room.';
    if (!canCapture) {
      return 'The camera moved ${(_distance! * 100).round()} cm from the '
          'capture station. Return to the same spot before the next photo.';
    }
    return null;
  }
}
