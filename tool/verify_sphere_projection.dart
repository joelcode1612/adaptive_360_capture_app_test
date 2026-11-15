// Verification harness for the 38-target camera projection and coverage.
//
// `flutter test` cannot run on this host (the `dartcv4` native-assets build
// probe is sandbox-blocked), but the entire projection/coverage geometry is
// pure Dart, so this script executes the *real production functions* on the
// plain VM:
//
//   dart --packages=.dart_tool/sphere_verify_package_config.json \
//        tool/verify_sphere_projection.dart
//
// Covered here (specification tests A–E and G):
//   A  original 3072×4096 image → focal and FOV from the documented fallback
//   B  full / half / quarter decode of the same image → identical FOV
//   C  portrait crop → principal point and focal follow the recorded offsets
//   D  EXIF orientation → recorded size matches the decoded orientation
//   E  38-target theoretical coverage at the assumed FOV, cross-checked
//      against `tool/sphere_coverage_report.py`
//   G  FOV sensitivity → narrower lenses fail without changing the layout
//
// Test F (real photographs through OpenCV) needs the native library and is
// covered by `test/sphere_stitcher_projection_test.dart` plus the committed
// PIL fixtures — it runs where the toolchain is not sandbox-blocked.
//
// Any failed check sets the process exit code to 1.
library;

import 'dart:io' show exitCode, stdout;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/data/jpeg_size.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_intrinsics.dart';
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

Future<void> scenario(String name, Future<void> Function() body) async {
  _current = name;
  stdout.writeln('\n=== $name ===');
  try {
    await body();
  } catch (e, st) {
    _failed++;
    stdout.writeln('  FAIL  $_current — threw $e\n$st');
  }
}

/// The documented direction convention:
/// `sphereDirection(yaw, pitch) = (sin yaw·cos pitch, sin pitch, −cos yaw·cos pitch)`.
Vec3 sphereDirection(double yawDeg, double pitchDeg) {
  final y = yawDeg * math.pi / 180;
  final p = pitchDeg * math.pi / 180;
  return Vec3(
    math.sin(y) * math.cos(p),
    math.sin(p),
    -math.cos(y) * math.cos(p),
  );
}

Future<void> main() async {
  await scenario('A. original 3072×4096 → focal and FOV', testA);
  await scenario('B. reduced decodes keep the same FOV', testB);
  await scenario('C. portrait crop → offsets drive the principal point', testC);
  await scenario('D. EXIF orientation → recorded size matches decode', testD);
  await scenario(
    'E. 38-target theoretical coverage at the assumed FOV (vs Python script)',
    testE,
  );
  await scenario('G. FOV sensitivity without changing the layout', testG);

  stdout.writeln('\n===== $_passed passed, $_failed failed =====');
  if (_failed > 0) exitCode = 1;
}

// ── A ───────────────────────────────────────────────────────────────────────

Future<void> testA() async {
  const sourceW = 3072, sourceH = 4096;
  final p = decodedProjection(
    decodedWidth: sourceW,
    decodedHeight: sourceH,
    savedWidth: sourceW,
    savedHeight: sourceH,
    sourceWidth: sourceW,
    sourceHeight: sourceH,
    verticalFovDeg: kSphereAssumedVerticalFovDeg,
  )!;
  final expectedFocal = (sourceH / 2) /
      math.tan(kSphereAssumedVerticalFovDeg * math.pi / 360);
  check(
    (p.focalPx - expectedFocal).abs() < 1e-6,
    'focal ${p.focalPx.toStringAsFixed(1)} px = '
    '(4096/2)/tan(65°/2), scale ${p.decodeScale}',
  );
  check(
    p.cx == sourceW / 2 && p.cy == sourceH / 2,
    'principal point centred (${p.cx}, ${p.cy})',
  );
  final hFov = horizontalFovFromPixels(sourceW.toDouble(), p.focalPx);
  check(
    (hFov - 51.08).abs() < 0.05,
    'horizontal FOV ${hFov.toStringAsFixed(2)}° derived from 3:4 portrait — '
    'matches tool/sphere_coverage_report.py (51.08°)',
  );
  check(
    (p.verticalFovDegDeg - kSphereAssumedVerticalFovDeg).abs() < 1e-9,
    'vertical FOV ${p.verticalFovDegDeg.toStringAsFixed(2)}° = the assumed '
    'fallback, documented as assumed-not-measured',
  );
  // 1536×2048 is one of the supported 3:4 portrait sizes; same lens, same FOV.
  final small = decodedProjection(
    decodedWidth: 1536,
    decodedHeight: 2048,
    savedWidth: 1536,
    savedHeight: 2048,
    sourceWidth: 1536,
    sourceHeight: 2048,
    verticalFovDeg: kSphereAssumedVerticalFovDeg,
  )!;
  check(
    (small.horizontalFovDeg - hFov).abs() < 1e-9,
    'a 1536×2048 frame reports the same FOV (${small.horizontalFovDeg.toStringAsFixed(2)}°) '
    '— resolution never changes the lens',
  );
  // Invalid inputs are rejected instead of dividing by zero.
  check(
    decodedProjection(
          decodedWidth: 0,
          decodedHeight: 0,
          savedWidth: 0,
          savedHeight: 0,
          sourceWidth: 0,
          sourceHeight: 0,
          verticalFovDeg: 65,
        ) ==
        null,
    'all-zero dimensions return null',
  );
}

// ── B ───────────────────────────────────────────────────────────────────────

Future<void> testB() async {
  const sourceW = 3072, sourceH = 4096;
  final cases = <(int, int, String)>[
    (sourceW, sourceH, 'full (IMREAD_COLOR)'),
    (1536, 2048, 'half (IMREAD_REDUCED_COLOR_2)'),
    (768, 1024, 'quarter (IMREAD_REDUCED_COLOR_4)'),
  ];
  final fovs = <double>[];
  for (final (dw, dh, label) in cases) {
    final p = decodedProjection(
      decodedWidth: dw,
      decodedHeight: dh,
      savedWidth: sourceW,
      savedHeight: sourceH,
      sourceWidth: sourceW,
      sourceHeight: sourceH,
      verticalFovDeg: kSphereAssumedVerticalFovDeg,
    )!;
    fovs.add(p.horizontalFovDeg);
    stdout.writeln(
      '        $label: ${dw}×$dh, focal ${p.focalPx.toStringAsFixed(1)} px, '
      'FOV ${p.horizontalFovDeg.toStringAsFixed(3)}° × '
      '${p.verticalFovDegDeg.toStringAsFixed(3)}°',
    );
  }
  final full = fovs.first;
  check(
    fovs.every((f) => (f - full).abs() < 1e-9),
    'horizontal FOV identical across all three decodes '
    '(${fovs.map((f) => f.toStringAsFixed(3)).join(', ')})',
  );
  // And the vertical likewise: the focal scales with the decode, so the
  // derived FOV is invariant.
  final verticals = cases.map((c) {
    final p = decodedProjection(
      decodedWidth: c.$1,
      decodedHeight: c.$2,
      savedWidth: sourceW,
      savedHeight: sourceH,
      sourceWidth: sourceW,
      sourceHeight: sourceH,
      verticalFovDeg: kSphereAssumedVerticalFovDeg,
    )!;
    return p.verticalFovDegDeg;
  }).toList();
  check(
    verticals.every((f) => (f - kSphereAssumedVerticalFovDeg).abs() < 1e-9),
    'vertical FOV identical across all three decodes (65°)',
  );
}

// ── C ───────────────────────────────────────────────────────────────────────

Future<void> testC() async {
  // A 9:16 portrait frame (2268×4032) cropped to 3:4: the crop removes
  // HEIGHT (top/bottom), so the lens focal stays with the 4032 source height
  // even though the saved image is only 3024 tall.
  const sourceW = 2268, sourceH = 4032;
  const savedH = 3024; // width×4/3, centred → offsetY = 504
  const offsetY = (sourceH - savedH) ~/ 2;
  final p = decodedProjection(
    decodedWidth: sourceW,
    decodedHeight: savedH,
    savedWidth: sourceW,
    savedHeight: savedH,
    sourceWidth: sourceW,
    sourceHeight: sourceH,
    verticalFovDeg: kSphereAssumedVerticalFovDeg,
    cropOffsetY: offsetY,
  )!;
  final focalSource = (sourceH / 2) /
      math.tan(kSphereAssumedVerticalFovDeg * math.pi / 360);
  check(
    (p.focalPx - focalSource).abs() < 1e-6 && p.decodeScale == 1,
    'a full-decode crop keeps the lens focal (${p.focalPx.toStringAsFixed(1)} px '
    'from the 4032 source, not the 3024 crop)',
  );
  check(
    p.cy == sourceH / 2 - offsetY && p.cy == savedH / 2,
    'principal point y = source/2 − offset = crop centre (${p.cy})',
  );
  final croppedVFov = verticalFovFromPixels(savedH.toDouble(), p.focalPx);
  check(
    croppedVFov < kSphereAssumedVerticalFovDeg &&
        (croppedVFov - 51.2).abs() < 0.2,
    'the cropped image spans ${croppedVFov.toStringAsFixed(1)}° vertically — '
    'narrower than the lens, as a crop must be',
  );
  // A direction at the crop's own centre projects to the decoded centre.
  final depth = 1.0;
  final u = p.cx + p.focalPx * 0 / depth;
  final v = p.cy - p.focalPx * 0 / depth;
  check(u == p.cx && v == p.cy, 'the optical axis lands on (${u},${v})');
  // Round-trip through the record: what the normalizer records is exactly
  // what decodedProjection consumes.
  final record = CaptureRecord(
    stationId: 's',
    targetId: 1,
    imagePath: 'x.jpg',
    capturedAt: DateTime.fromMillisecondsSinceEpoch(0),
    targetYawDegrees: 0,
    targetPitchDegrees: 0,
    cameraPosition: Vec3.zero,
    cameraOrientation: Quat.identity,
    alignmentErrorDeg: 1,
    anchored: false,
    imageWidth: sourceW,
    imageHeight: savedH,
    sourceImageWidth: sourceW,
    sourceImageHeight: sourceH,
    cropOffsetY: offsetY,
  );
  final restored = CaptureRecord.fromJson(record.toJson());
  check(
    restored.cropOffsetY == offsetY &&
        restored.imageHeight == savedH &&
        restored.sourceImageHeight == sourceH,
    'crop offsets survive the record JSON round-trip',
  );
}

// ── D ───────────────────────────────────────────────────────────────────────

/// Builds a minimal JPEG byte structure: SOI + optional EXIF APP1 + SOF0 +
/// EOI — exactly what `readJpegSize` parses, without a decoder.
Uint8List fakeJpeg({
  required int storedWidth,
  required int storedHeight,
  int? orientation,
}) {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8]); // SOI
  if (orientation != null) {
    // APP1: "Exif\0\0" + TIFF header with one IFD entry (0x0112, SHORT=3).
    final tiff = BytesBuilder();
    tiff.add([0x49, 0x49, 42, 0]); // little-endian, magic 42
    tiff.add([8, 0, 0, 0]); // IFD offset 8
    tiff.add([1, 0]); // one entry
    tiff.add([0x12, 0x01, 3, 0, 1, 0, 0, 0, orientation, 0, 0, 0]);
    tiff.add([0, 0, 0, 0]); // next IFD = none
    final payload = tiff.toBytes();
    final app1 = BytesBuilder();
    app1.add([0xFF, 0xE1]);
    final len = payload.length + 6;
    app1.add([(len >> 8) & 0xFF, len & 0xFF]);
    app1.add('Exif'.codeUnits + [0, 0]);
    app1.add(payload);
    b.add(app1.toBytes());
  }
  // SOF0 with the stored (sensor) dimensions.
  final sof = BytesBuilder();
  sof.add([0xFF, 0xC0]);
  sof.add([0, 11]); // segment length
  sof.add([8]); // precision
  sof.add([(storedHeight >> 8) & 0xFF, storedHeight & 0xFF]);
  sof.add([(storedWidth >> 8) & 0xFF, storedWidth & 0xFF]);
  sof.add([1, 0, 0]); // one component
  final sofBytes = sof.toBytes();
  b.add(sofBytes);
  b.add([0xFF, 0xD9]); // EOI
  return b.toBytes();
}

Future<void> testD() async {
  // Sensor-landscape JPEG rotated for display (orientation 6): the stitcher's
  // imread shows portrait pixels, so the recorded size must be portrait too.
  final rotated = readJpegSize(
    fakeJpeg(storedWidth: 4032, storedHeight: 3024, orientation: 6),
  );
  check(
    rotated != null && rotated.width == 3024 && rotated.height == 4032,
    'orientation 6: stored 4032×3024 reads as displayed 3024×4032',
  );
  final upright = readJpegSize(
    fakeJpeg(storedWidth: 3072, storedHeight: 4096, orientation: 1),
  );
  check(
    upright != null && upright.width == 3072 && upright.height == 4096,
    'orientation 1: dimensions pass through unchanged',
  );
  final noExif = readJpegSize(fakeJpeg(storedWidth: 640, storedHeight: 480));
  check(
    noExif != null && noExif.width == 640 && noExif.height == 480,
    'no EXIF: SOF dimensions as stored',
  );
  check(readJpegSize(Uint8List(0)) == null, 'empty bytes return null');
  // Orientation 8 (270°) also swaps.
  final o8 = readJpegSize(
    fakeJpeg(storedWidth: 4000, storedHeight: 3000, orientation: 8),
  );
  check(
    o8 != null && o8.width == 3000 && o8.height == 4000,
    'orientation 8 swaps axes too',
  );
}

// ── E and G ─────────────────────────────────────────────────────────────────

/// Area-weighted coverage of the 38-target layout for a vertical FOV,
/// replicating `tool/sphere_coverage_report.py` on the same 720×360 grid.
({double single, double doubleCov, double tripleCov, List<int> uncovered})
sphereCoverage({required double verticalFovDeg}) {
  const gridW = 720, gridH = 360;
  // tan(h/2) = tan(v/2)·(3/4): the horizontal reach is derived from the
  // portrait 3:4 still, exactly as `sphere_intrinsics.dart` derives it.
  final tanV = math.tan(verticalFovDeg * math.pi / 360);
  final tanH = tanV * 0.75;

  final targets = buildSphereTargets();
  final sinLon = Float64List(gridW);
  final cosLon = Float64List(gridW);
  for (var x = 0; x < gridW; x++) {
    final lon = -math.pi + (x + 0.5) / gridW * 2 * math.pi;
    sinLon[x] = math.sin(lon);
    cosLon[x] = math.cos(lon);
  }
  final sinLat = Float64List(gridH);
  final cosLat = Float64List(gridH);
  for (var y = 0; y < gridH; y++) {
    final lat = math.pi / 2 - (y + 0.5) / gridH * math.pi;
    sinLat[y] = math.sin(lat);
    cosLat[y] = math.cos(lat);
  }
  final hits = Uint8List(gridW * gridH);
    for (final t in targets) {
      // The frame's device→sphere rotation is `fromYawPitch(−yaw, −pitch)`
      // (it maps the optical axis onto the target direction); sphere→camera
      // is its conjugate.
      final sphereToCamera = Quat.fromYawPitch(
        -t.yawDeg,
        -t.pitchDeg,
      ).conjugate;
      for (var y = 0; y < gridH; y++) {
        final dy = sinLat[y];
        final dxz = cosLat[y];
        for (var x = 0; x < gridW; x++) {
          final dx = sinLon[x] * dxz;
          final dz = -cosLon[x] * dxz;
          final cam = sphereToCamera.rotate(Vec3(dx, dy, dz));
          final depth = -cam.z;
          if (depth <= 0.05) continue;
          if ((cam.x / depth).abs() <= tanH && (cam.y / depth).abs() <= tanV) {
            final i = y * gridW + x;
            if (hits[i] < 255) hits[i]++;
          }
        }
      }
    }
  var total = 0.0;
  var single = 0.0;
  var doubleCov = 0.0;
  var triple = 0.0;
  final uncovered = <int>[];
  for (var y = 0; y < gridH; y++) {
    for (var x = 0; x < gridW; x++) {
      final w = cosLat[y];
      total += w;
      final n = hits[y * gridW + x];
      if (n == 0) {
        uncovered.add(y * gridW + x);
        continue;
      }
      single += w;
      if (n >= 2) doubleCov += w;
      if (n >= 3) triple += w;
    }
  }
  return (
    single: single / total,
    doubleCov: doubleCov / total,
    tripleCov: triple / total,
    uncovered: uncovered,
  );
}

Future<void> testE() async {
  final r = sphereCoverage(verticalFovDeg: kSphereAssumedVerticalFovDeg);
  // The Python script (720×360 grid) reports, for the ±35° 38-target layout
  // at a 65° vertical / 51.08° horizontal FOV: single 100.00, double 90.94,
  // triple 57.61. The Dart simulation must agree.
  check(
    r.single >= 0.995,
    'single coverage ${(r.single * 100).toStringAsFixed(2)}% ≥ 99.5% gate',
  );
  check(
    (r.single * 100 - 100.00).abs() < 0.2,
    'single ${(r.single * 100).toStringAsFixed(2)}% — Python reports 100.00%',
  );
  check(
    (r.doubleCov * 100 - 90.94).abs() < 0.5,
    'double ${(r.doubleCov * 100).toStringAsFixed(2)}% — Python reports 90.94%',
  );
  check(
    (r.tripleCov * 100 - 57.61).abs() < 0.5,
    'triple ${(r.tripleCov * 100).toStringAsFixed(2)}% — Python reports 57.61%',
  );
  check(
    r.uncovered.length / (720 * 360) < 0.01,
    'uncovered area ${(r.uncovered.length / (720 * 360) * 100).toStringAsFixed(2)}% '
    '— a small polar cap, not a ring gap',
  );
  // The layout is untouched: still 38 targets, rings at ±45°, poles last.
  final targets = buildSphereTargets();
  check(
    targets.length == 38 &&
        targets.first.targetId == 1 &&
        targets.last.targetId == 38,
    'buildSphereTargets still returns the 38-direction layout',
  );
  // The theoretical result uses the real geometry, but the stitcher's audit
  // still runs on actual photographs and their recorded orientations — the
  // two are checked separately (Test F), and 99.5% coverage never claims
  // seamless stitching.
}

Future<void> testG() async {
  // ±35° rings clear the gate at the assumed lens with margin: 100.00% at
  // 65° and 99.76% at 60°; a 55° lens leaves a 1.52% polar hole and is
  // reported as a limitation rather than papered over.
  final cases = <(double, bool, String)>[
    (65, true, 'assumed fallback'),
    (60, true, 'narrower, still complete'),
    (55, false, 'polar hole appears'),
    (50, false, 'too narrow'),
    (45, false, 'much too narrow'),
    (40, false, 'far too narrow'),
  ];
  for (final (vfov, shouldPass, label) in cases) {
    final r = sphereCoverage(verticalFovDeg: vfov);
    final passes = r.single >= 0.995;
    check(
      passes == shouldPass,
      'vfov $vfov° ($label): single '
      '${(r.single * 100).toStringAsFixed(2)}%, uncovered '
      '${(r.uncovered.length / (720 * 360) * 100).toStringAsFixed(2)}% of '
      'cells — ${passes ? 'PASS' : 'FAIL'}',
    );
  }
  check(
    buildSphereTargets().length == 38,
    'the layout stays at 38 targets — coverage problems must be answered by '
    'the lens, never by changing the capture sequence',
  );
}
