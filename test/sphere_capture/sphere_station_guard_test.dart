import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_station_guard.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

void main() {
  test('a valid first pose establishes a fixed position', () {
    final guard = SphereStationGuard();
    guard.update(position: const Vec3(1, 2, 3), tracking: true);
    expect(guard.canCapture, true);
    guard.update(position: const Vec3(1.05, 2, 3), tracking: true);
    expect(guard.canCapture, true);
  });

  test('translation away from the station blocks capture', () {
    final guard = SphereStationGuard(maxDisplacementM: 0.12);
    guard.update(position: const Vec3(0, 0, 0), tracking: true);
    guard.update(position: const Vec3(0, 0, 0.2), tracking: true);
    expect(guard.canCapture, false);
    expect(guard.displacementM, closeTo(0.2, 0.001));
    guard.update(position: const Vec3(0, 0, 0.03), tracking: true);
    expect(guard.canCapture, true);
  });

  test('lost tracking never reuses a stale pose', () {
    final guard = SphereStationGuard();
    guard.update(position: const Vec3(0, 1, 0), tracking: true);
    guard.update(position: const Vec3(0, 1, 0), tracking: false);
    expect(guard.canCapture, false);
    expect(guard.message, contains('tracking'));
  });
}
