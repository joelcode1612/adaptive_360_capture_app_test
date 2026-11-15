// Verification harness for the 3:4 viewfinder and the middle-ring geometry
// (specification tests C and D) — pure Dart, runnable on the VM:
//
//   dart --packages=.dart_tool/sphere_verify_package_config.json \
//        tool/verify_sphere_viewfinder.dart
//
// Everything here exercises the production maths: [fitPortraitThreeFour] and
// [projectToViewport] from `sphere_math.dart` (the same functions
// `SphereProjection` draws with), [sphereTargetCameraDirection] for the
// sensor-to-screen chain, and [levelStartFrame] for the start-pose levelling.
library;

import 'dart:io' show exitCode, stdout;
import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_math.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

int _passed = 0;
int _failed = 0;
String _current = '';

void check(bool ok, String detail) {
  if (ok) {
    _passed++;
    stdout.writeln('  PASS  $_current — $detail');
  } else {
    _failed++;
    stdout.writeln('  FAIL  $_current — $detail');
  }
}

void scenario(String name, void Function() body) {
  _current = name;
  stdout.writeln('\n=== $name ===');
  try {
    body();
  } catch (e, st) {
    _failed++;
    stdout.writeln('  FAIL  $_current — threw $e\n$st');
  }
}

/// The 3:4 viewfinder at a 576 px width — the size the specification uses.
const double vfWidth = 576;
const double vfHeight = 768;

/// Focal length for that viewfinder at the documented 65° vertical FOV.
double get focal => (vfHeight / 2) / math.tan(65 * math.pi / 360);

/// A device pose pitched [degrees] down from level (about the start frame's X).
Quat pitchDown(double degrees) => Quat.axisAngle(-degrees, Vec3.unitX);

void main() {
  scenario('C. the viewfinder is always a portrait 3:4 box', () {
    final tall = fitPortraitThreeFour(
      availableWidth: 1080,
      availableHeight: 2340,
    );
    check(
      (tall.width - 1080).abs() < 1e-9 &&
          (tall.height - 1440).abs() < 1e-9,
      'tall phone (1080×2340 available) → ${tall.width}×${tall.height} '
      '(width-limited)',
    );
    final spec = fitPortraitThreeFour(
      availableWidth: 576,
      availableHeight: 1200,
    );
    check(
      (spec.width - 576).abs() < 1e-9 && (spec.height - 768).abs() < 1e-9,
      '576 available → 576×768, exactly the specification example',
    );
    final short = fitPortraitThreeFour(
      availableWidth: 800,
      availableHeight: 600,
    );
    check(
      (short.width - 450).abs() < 1e-9 && (short.height - 600).abs() < 1e-9,
      'short/wide screen (800×600 available) → 450×600 (height-limited)',
    );
    for (final (double w, double h) in const <(double, double)>[
      (1080, 2340),
      (720, 1600),
      (1440, 2560),
      (576, 1200),
    ]) {
      final box = fitPortraitThreeFour(availableWidth: w, availableHeight: h);
      final aspect = box.width / box.height;
      final fits = box.width <= w + 1e-9 && box.height <= h + 1e-9;
      check(
        (aspect - 0.75).abs() < 1e-9 && fits,
        '${w.toInt()}×${h.toInt()}: ${box.width.round()}×${box.height.round()} '
        'is 3:4 and fits inside the available area',
      );
    }
    final zero = fitPortraitThreeFour(availableWidth: 0, availableHeight: 0);
    check(zero.width == 0 && zero.height == 0, 'degenerate input → empty box');
  });

  scenario('C. the preview crop narrows the visible FOV correctly', () {
    // A 4:3 sensor frame in the 3:4 viewfinder: no vertical crop, the camera's
    // full 65° is visible.
    final fourThree = visibleVerticalFovDeg(
      cameraVerticalFovDeg: 65,
      frameAspect: 0.75,
      viewfinderAspect: 0.75,
    );
    check(
      (fourThree - 65).abs() < 1e-9,
      '4:3 preview in a 3:4 viewfinder keeps the full 65°',
    );
    // A 9:16 preview stream in the 3:4 box: width kept, top/bottom cropped,
    // so only 51.09° of the vertical field is on screen.
    final nineSixteen = visibleVerticalFovDeg(
      cameraVerticalFovDeg: 65,
      frameAspect: 9 / 16,
      viewfinderAspect: 0.75,
    );
    check(
      (nineSixteen - 51.0772).abs() < 0.001,
      '9:16 preview shows ${nineSixteen.toStringAsFixed(2)}° of the 65° '
      'vertical field (the centre 3:4 crop)',
    );
    // Wider than 3:4: sides cropped, full height kept.
    final wide = visibleVerticalFovDeg(
      cameraVerticalFovDeg: 65,
      frameAspect: 1.0,
      viewfinderAspect: 0.75,
    );
    check(
      (wide - 65).abs() < 1e-9,
      'a wider preview keeps the full vertical field',
    );
    // And the consequence for a tilted phone: at 15° down, the horizon marker
    // must sit at the *visible* focal length, not the full-frame one.
    final focalVisible = (vfHeight / 2) /
        math.tan(nineSixteen * math.pi / 360);
    final offsetVisible = focalVisible * math.tan(15 * math.pi / 180);
    final offsetFull = focal * math.tan(15 * math.pi / 180);
    check(
      (offsetVisible - 215.3).abs() < 1.0 && offsetVisible > offsetFull,
      '15° down puts the horizon ${offsetVisible.toStringAsFixed(0)} px above '
      'the reticle with a 9:16 preview, versus '
      '${offsetFull.toStringAsFixed(0)} px if the full 65° were (wrongly) '
      'mapped onto the cropped box',
    );
  });

  scenario('C. the reticle is the optical axis of the viewfinder', () {
    final center = projectToViewport(
      const Vec3(0, 0, -1),
      width: vfWidth,
      height: vfHeight,
      verticalFovDeg: 65,
    )!;
    check(
      (center.x - vfWidth / 2).abs() < 1e-9 &&
          (center.y - vfHeight / 2).abs() < 1e-9,
      'straight ahead → (${center.x}, ${center.y}) = viewfinder centre',
    );
    final behind = projectToViewport(
      const Vec3(0, 0, 1),
      width: vfWidth,
      height: vfHeight,
      verticalFovDeg: 65,
    );
    check(behind == null, 'a direction behind the camera does not project');
    // A target 10° to the right lands right of centre by focal·tan(10°).
    final right = projectToViewport(
      Vec3(math.sin(10 * math.pi / 180), 0, -math.cos(10 * math.pi / 180)),
      width: vfWidth,
      height: vfHeight,
      verticalFovDeg: 65,
    )!;
    check(
      (right.x - (vfWidth / 2 + focal * math.tan(10 * math.pi / 180))).abs() <
              0.5 &&
          (right.y - vfHeight / 2).abs() < 1e-6,
      'a 10°-right direction lands at x=${right.x.toStringAsFixed(1)} '
      '(expected ${(vfWidth / 2 + focal * math.tan(10 * math.pi / 180)).toStringAsFixed(1)}), '
      'same row as the reticle',
    );
  });

  scenario('D. a level camera puts the middle ring on the reticle', () {
    final target = buildSphereTargets().firstWhere(
      (SphereTargetSpec s) => s.targetId == 1,
    );
    final direction = sphereTargetCameraDirection(
      deviceToWorld: Quat.identity,
      startDeviceToWorld: Quat.identity,
      startDirection: target.direction,
    );
    final p = projectToViewport(
      direction,
      width: vfWidth,
      height: vfHeight,
      verticalFovDeg: 65,
    )!;
    check(
      (p.y - vfHeight / 2).abs() < 1e-6 && (p.x - vfWidth / 2).abs() < 1e-6,
      'target 1 (pitch 0°) is exactly on the reticle when level: '
      '(${p.x.toStringAsFixed(1)}, ${p.y.toStringAsFixed(1)})',
    );
  });

  scenario('D. tilting down 15° lifts the horizon above the reticle', () {
    final target = buildSphereTargets().firstWhere(
      (SphereTargetSpec s) => s.targetId == 1,
    );
    final direction = sphereTargetCameraDirection(
      deviceToWorld: pitchDown(15),
      startDeviceToWorld: Quat.identity,
      startDirection: target.direction,
    );
    final p = projectToViewport(
      direction,
      width: vfWidth,
      height: vfHeight,
      verticalFovDeg: 65,
    )!;
    final expected = vfHeight / 2 - focal * math.tan(15 * math.pi / 180);
    check(
      (p.y - expected).abs() < 0.5 && p.y < vfHeight / 2,
      'marker at y=${p.y.toStringAsFixed(1)} (expected '
      '${expected.toStringAsFixed(1)}), ${(vfHeight / 2 - p.y).toStringAsFixed(0)} px '
      'above the reticle — correct gravity geometry, not a rendering bug',
    );
    // And the same tilt downward moves it up on screen: larger tilt, higher.
    final steeper = projectToViewport(
      sphereTargetCameraDirection(
        deviceToWorld: pitchDown(30),
        startDeviceToWorld: Quat.identity,
        startDirection: target.direction,
      ),
      width: vfWidth,
      height: vfHeight,
      verticalFovDeg: 65,
    )!;
    check(
      steeper.y < p.y,
      '30° down puts it even higher (y=${steeper.y.toStringAsFixed(1)})',
    );
  });

  scenario('D. tilting up 15° lowers the horizon below the reticle', () {
    final target = buildSphereTargets().firstWhere(
      (SphereTargetSpec s) => s.targetId == 1,
    );
    final direction = sphereTargetCameraDirection(
      deviceToWorld: Quat.axisAngle(15, Vec3.unitX),
      startDeviceToWorld: Quat.identity,
      startDirection: target.direction,
    );
    final p = projectToViewport(
      direction,
      width: vfWidth,
      height: vfHeight,
      verticalFovDeg: 65,
    )!;
    final expected = vfHeight / 2 + focal * math.tan(15 * math.pi / 180);
    check(
      (p.y - expected).abs() < 0.5 && p.y > vfHeight / 2,
      'marker at y=${p.y.toStringAsFixed(1)} (expected '
      '${expected.toStringAsFixed(1)}) below the reticle',
    );
  });

  scenario('D. turning to a ring target keeps it on the reticle row', () {
    final targets = buildSphereTargets();
    var worstY = 0.0;
    var worstX = 0.0;
    for (final int id in const <int>[1, 4, 7, 10]) {
      final target = targets.firstWhere((SphereTargetSpec s) => s.targetId == id);
      // Turn the phone to face the target: a right turn is a negative yaw
      // rotation about the sphere's up axis.
      final device = Quat.axisAngle(-target.yawDeg, Vec3.unitY);
      final p = projectToViewport(
        sphereTargetCameraDirection(
          deviceToWorld: device,
          startDeviceToWorld: Quat.identity,
          startDirection: target.direction,
        ),
        width: vfWidth,
        height: vfHeight,
        verticalFovDeg: 65,
      )!;
      worstX = math.max(worstX, (p.x - vfWidth / 2).abs());
      worstY = math.max(worstY, (p.y - vfHeight / 2).abs());
    }
    check(
      worstX < 1e-6 && worstY < 1e-6,
      'yaw 0/90/180/270 targets all land on the reticle '
      '(worst |dx|=${worstX.toStringAsExponential(1)}, '
      '|dy|=${worstY.toStringAsExponential(1)})',
    );
  });

  scenario('D. starting tilted does not permanently tilt the sphere', () {
    // The phone is already 20° down when Start is pressed. The levelled
    // reference drops that pitch, so with the phone level again the middle
    // ring is back on the horizon.
    final tilted = pitchDown(20);
    final start = levelStartFrame(tilted);
    check(start != null, 'a 20°-down start still yields a valid reference');
    final level = projectToViewport(
      sphereTargetCameraDirection(
        deviceToWorld: start!,
        startDeviceToWorld: start,
        startDirection: const Vec3(0, 0, -1),
      ),
      width: vfWidth,
      height: vfHeight,
      verticalFovDeg: 65,
    )!;
    check(
      (level.y - vfHeight / 2).abs() < 1e-6,
      'with the phone level after a tilted start, the horizon target is on '
      'the reticle (y=${level.y.toStringAsFixed(1)})',
    );
    // And from that reference, a further 15° downward tilt behaves like any
    // other 15° tilt — the start pitch is not baked in.
    final down = projectToViewport(
      sphereTargetCameraDirection(
        deviceToWorld: (pitchDown(15) * start).normalized,
        startDeviceToWorld: start,
        startDirection: const Vec3(0, 0, -1),
      ),
      width: vfWidth,
      height: vfHeight,
      verticalFovDeg: 65,
    )!;
    final expected = vfHeight / 2 - focal * math.tan(15 * math.pi / 180);
    check(
      (down.y - expected).abs() < 0.5,
      '15° down from a tilted start gives the same '
      'y=${down.y.toStringAsFixed(1)} as a level start '
      '(expected ${expected.toStringAsFixed(1)})',
    );
  });

  scenario('D. a full 360° turn returns the target to its start position', () {
    final target = buildSphereTargets().firstWhere(
      (SphereTargetSpec s) => s.targetId == 1,
    );
    final startPoint = projectToViewport(
      sphereTargetCameraDirection(
        deviceToWorld: Quat.identity,
        startDeviceToWorld: Quat.identity,
        startDirection: target.direction,
      ),
      width: vfWidth,
      height: vfHeight,
      verticalFovDeg: 65,
    )!;
    final afterTurn = projectToViewport(
      sphereTargetCameraDirection(
        deviceToWorld: Quat.axisAngle(-360, Vec3.unitY),
        startDeviceToWorld: Quat.identity,
        startDirection: target.direction,
      ),
      width: vfWidth,
      height: vfHeight,
      verticalFovDeg: 65,
    )!;
    check(
      (afterTurn.x - startPoint.x).abs() < 1e-6 &&
          (afterTurn.y - startPoint.y).abs() < 1e-6,
      '360° returns to (${afterTurn.x.toStringAsFixed(1)}, '
      '${afterTurn.y.toStringAsFixed(1)})',
    );
  });

  stdout.writeln('\n===== $_passed passed, $_failed failed =====');
  if (_failed > 0) exitCode = 1;
}
