import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/data/sphere_frame_registration.dart';

void main() {
  test('residual affine is zero at image centre', () {
    const warp = SphereResidualAffine(du0: 0.02, dv0: -0.02);
    final p = warp.shiftAt(u: 500, v: 500, width: 1000, height: 1000);
    expect(p.du, 0);
    expect(p.dv, 0);
  });
  test('residual shift is bounded and periphery-only', () {
    const warp = SphereResidualAffine(du0: 0.5, dv0: -0.5);
    final p = warp.shiftAt(u: 900, v: 900, width: 1000, height: 1000);
    expect(p.du, 35);
    expect(p.dv, -35);
  });
  test('identity never moves photograph samples', () {
    final p = SphereResidualAffine.identity.shiftAt(
      u: 15, v: 44, width: 800, height: 1000,
    );
    expect(p.du, 0);
    expect(p.dv, 0);
  });
}
