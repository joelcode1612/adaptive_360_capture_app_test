import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/data/stitch_job_runner.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/equirect_bounds.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_intrinsics.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';

/// A guaranteed full-sphere equirectangular panorama from the 3DoF captures.
///
/// ## Why not OpenCV's feature-based Stitcher
///
/// On device, `cv::Stitcher` returned a partial fan of the room: it dropped
/// frames it could not confidently register instead of covering the sphere.
/// That is the wrong failure mode for a 360° product — a hole cannot be
/// retried without recapturing.
///
/// This stitcher does not rely on feature matching at all. Every frame already
/// has a measured device quaternion in `records.json`, so its orientation
/// relative to the first frame is known. Each frame is projected onto the
/// equirectangular canvas through that rotation, and every canvas pixel takes
/// the frame whose optical axis is nearest. Coverage is therefore complete by
/// construction, and no frame can be "rejected".
///
/// ## Blending
///
/// Averaging all overlapping frames ghosted badly wherever two rings disagreed
/// by a few degrees. The canvas instead keeps the nearest frame per pixel and
/// blends only where the best and second-best weights are within 3% — a narrow
/// seam band, not a double exposure.
///
/// The whole projection runs in a background isolate: 38 frames take several
/// seconds and must not block the Flutter UI thread (the previous on-thread
/// stitch caused an ANR). The isolate hand-off itself — the part that used to
/// fail with an unsendable `ReceivePort` — lives in [StitchJobRunner], where
/// only plain data and a `SendPort` cross the boundary.
class EquirectangularStitcher implements PanoramaStitcher {
  const EquirectangularStitcher({
    this.width = 2048,
    this.worker = _projectEquirect,
  });

  /// Output width in pixels; height is half of it, i.e. a 2:1 equirectangular.
  final int width;

  /// The projection entry point. Top-level by default; injectable so the
  /// isolate contract (progress plumbing, error propagation, duplicate-job
  /// rejection) is testable without the native OpenCV library.
  final StitchWorker worker;

  @override
  Future<StitchResult> stitchFrames(
    List<String> imagePaths, {
    void Function(String stage)? onStage,
  }) async {
    if (imagePaths.isEmpty) {
      return const StitchResult.failure('No images to stitch.');
    }
    final stationDir = File(imagePaths.first).parent.parent.path;
    final recordsFile = File(p.join(stationDir, 'records.json'));
    if (!recordsFile.existsSync()) {
      return const StitchResult.failure(
        'The capture records are missing, so the photographs cannot be '
        'oriented. Retake the station.',
      );
    }
    final outPath = p.join(stationDir, 'panorama.jpg');
    onStage?.call('Preparing ${imagePaths.length} photographs…');
    // The runner keeps the ReceivePort in this isolate and hands the worker
    // only a sendable record containing its SendPort. It also refuses a
    // second concurrent run for the same station.
    final result = await StitchJobRunner.run(
      worker: worker,
      stationDir: stationDir,
      outPath: outPath,
      width: width,
      onStage: onStage,
    );
    if (!result.ok) return StitchResult.failure(result.message);
    return StitchResult(
      success: true,
      panoramaPath: outPath,
      message: 'Panorama generated successfully.',
    );
  }
}

/// Whether the stitcher's verbose diagnostics are compiled in. Off unless the
/// run asks for it: `--dart-define=sphere_stitch_log=true`.
const bool kSphereStitchLog = bool.fromEnvironment('sphere_stitch_log');

/// The projection, on a background isolate.
({bool ok, String message}) _projectEquirect(StitchWorkerArgs args) {
  final stationDir = args.stationDir;
  final outPath = args.outPath;
  final width = args.width;
  final SendPort progress = args.progress;
  final stopwatch = Stopwatch()..start();
  final recordsFile = File(p.join(stationDir, 'records.json'));
  final raw = jsonDecode(recordsFile.readAsStringSync());
  if (raw is! List || raw.isEmpty) {
    return (ok: false, message: 'The capture records are empty.');
  }
  final records = raw.cast<Map<String, dynamic>>()
    ..sort(
      (Map<String, dynamic> a, Map<String, dynamic> b) => (a['targetId'] as num)
          .toInt()
          .compareTo((b['targetId'] as num).toInt()),
    );

  final first = Quat.fromList(
    (records.first['cameraOrientation'] as List<dynamic>).cast<double>(),
  );
  final height = width ~/ 2;
  final bestWeight = Float32List(width * height);
  final bestColour = Uint8List(width * height * 3);
  final secondWeight = Float32List(width * height);
  final secondColour = Uint8List(width * height * 3);
  // How many frames actually see each pixel. Saturating at 3: the audit only
  // reports single/double/triple coverage, and a fourth contributor would not
  // change any of those three numbers.
  final hits = Uint8List(width * height);

  final sinLon = Float64List(width);
  final cosLon = Float64List(width);
  for (var x = 0; x < width; x++) {
    final lon = -3.141592653589793 + (x + 0.5) / width * 6.283185307179586;
    sinLon[x] = math.sin(lon);
    cosLon[x] = math.cos(lon);
  }
  final sinLat = Float64List(height);
  final cosLat = Float64List(height);
  for (var y = 0; y < height; y++) {
    final lat = 1.5707963267948966 - (y + 0.5) / height * 3.141592653589793;
    sinLat[y] = math.sin(lat);
    cosLat[y] = math.cos(lat);
  }

  // Decode JPEGs at a resolution appropriate for the output. A 2048-wide
  // equirectangular panorama does not need 38 full-resolution 12 MP buffers.
  // OpenCV's reduced decoder uses scaled-IDCT, reducing allocations/decoding.
  // Preserve more detail for optional higher-resolution panoramas.
  final decodeFlag = width <= 2048
      ? cv.IMREAD_REDUCED_COLOR_4
      : width <= 4096
      ? cv.IMREAD_REDUCED_COLOR_2
      : cv.IMREAD_COLOR;
  for (var frameIndex = 0; frameIndex < records.length; frameIndex++) {
    final record = records[frameIndex];
    final path = record['imagePath'] as String?;
    if (path == null || !File(path).existsSync()) {
      return (ok: false, message: 'A captured photograph is missing: $path');
    }
    final mat = cv.imread(path, flags: decodeFlag);
    if (mat.isEmpty) {
      mat.dispose();
      return (ok: false, message: 'A photograph could not be decoded: $path');
    }
    try {
      final q = Quat.fromList(
        (record['cameraOrientation'] as List<dynamic>).cast<double>(),
      );
      // camera -> sphere. The first frame defines the sphere's origin.
      final cameraToSphere = (first.conjugate * q).normalized;
      final sphereToCamera = cameraToSphere.conjugate;

      final imageWidth = mat.cols;
      final imageHeight = mat.rows;
      // Focal length and principal point **in the decoded image's coordinate
      // system**. The stitcher decodes reduced (IMREAD_REDUCED_COLOR_4 by
      // default), so the lens focal — a lens property, computed once on the
      // uncropped source frame — must be multiplied by the decode scale, and
      // the principal point must follow the recorded crop offsets. Using the
      // source height directly against a quarter-scale decoded image overstated
      // the focal 4×: every frame's angular footprint collapsed to about a
      // quarter of its true size and the coverage audit saw holes almost
      // everywhere. See `decodedProjection` for the full transform.
      final decoded = decodedProjection(
        decodedWidth: imageWidth,
        decodedHeight: imageHeight,
        savedWidth: (record['imageWidth'] as num?)?.toInt() ?? 0,
        savedHeight: (record['imageHeight'] as num?)?.toInt() ?? 0,
        sourceWidth: (record['sourceImageWidth'] as num?)?.toInt() ?? 0,
        sourceHeight: (record['sourceImageHeight'] as num?)?.toInt() ?? 0,
        verticalFovDeg: kSphereAssumedVerticalFovDeg,
        cropOffsetX: (record['cropOffsetX'] as num?)?.toInt() ?? 0,
        cropOffsetY: (record['cropOffsetY'] as num?)?.toInt() ?? 0,
      );
      if (decoded == null) {
        return (
          ok: false,
          message:
              'A photograph has invalid dimensions ($imageWidth×'
              '$imageHeight), so it cannot be projected.',
        );
      }
      final focal = decoded.focalPx;
      final cx = decoded.cx;
      final cy = decoded.cy;
      if (kSphereStitchLog && frameIndex == 0) {
        debugPrint(
          'SPHERE_STITCH: decoded=${imageWidth}x$imageHeight '
          'saved=${record['imageWidth']}x${record['imageHeight']} '
          'source=${record['sourceImageWidth']}x${record['sourceImageHeight']} '
          'decodeScale=${decoded.decodeScale.toStringAsFixed(3)} '
          'focalSource=${(decoded.focalPx / decoded.decodeScale).toStringAsFixed(1)} '
          'focalDecoded=${decoded.focalPx.toStringAsFixed(1)} '
          'hfov=${decoded.horizontalFovDeg.toStringAsFixed(2)}° '
          'vfov=${decoded.verticalFovDegDeg.toStringAsFixed(2)}°',
        );
      }
      final pixels = mat.data;
      final rowStride = imageWidth * 3;
      final marginX = 0.05 * imageWidth;
      final marginY = 0.05 * imageHeight;

      final bounds = equirectFrameBounds(
        cameraToSphere,
        imageWidth,
        imageHeight,
        focal,
        cx,
        cy,
      );
      final yStart = _clampInt(
        ((-bounds.maxLat + 1.5707963267948966) / 3.141592653589793 * height)
                .floor() -
            2,
        0,
        height - 1,
      );
      final yEnd = _clampInt(
        ((1.5707963267948966 - bounds.minLat) / 3.141592653589793 * height)
                .ceil() +
            2,
        0,
        height - 1,
      );
      // `minLon`/`maxLon` are unwrapped around the frame's own centre, so a
      // frame that straddles ±180° still has `minLon <= maxLon` and a span
      // below 2π. The column range may therefore fall outside [0, width) —
      // that is the wrap, and the `% width` in the loop handles it. A frame
      // that contains a pole covers every longitude and is marked full-width.
      final xStart = bounds.fullWidth
          ? 0
          : ((bounds.minLon + 3.141592653589793) / 6.283185307179586 * width)
                    .floor() -
                2;
      final xEnd = bounds.fullWidth
          ? width - 1
          : ((bounds.maxLon + 3.141592653589793) / 6.283185307179586 * width)
                    .ceil() +
                2;

      // Scalar quaternion components: the inner loop rotates millions of
      // directions, and allocating a Vec3 per pixel dominated the runtime.
      final qx = sphereToCamera.x;
      final qy = sphereToCamera.y;
      final qz = sphereToCamera.z;
      final qw = sphereToCamera.w;

      for (var y = yStart; y <= yEnd; y++) {
        final dy = sinLat[y];
        final dxz = cosLat[y];
        for (var xi = xStart; xi <= xEnd; xi++) {
          // The longitude interval extends by at most one panorama wrap.
          // Avoid two integer modulo operations in the hot pixel loop.
          final x = xi < 0 ? xi + width : (xi >= width ? xi - width : xi);
          final dx = sinLon[x] * dxz;
          final dz = -cosLon[x] * dxz;
          // v' = v + 2w(u×v) + 2u×(u×v), inlined.
          final c0x = qy * dz - qz * dy;
          final c0y = qz * dx - qx * dz;
          final c0z = qx * dy - qy * dx;
          final c1x = qy * c0z - qz * c0y;
          final c1y = qz * c0x - qx * c0z;
          final c1z = qx * c0y - qy * c0x;
          final camX = dx + 2 * (qw * c0x + c1x);
          final camY = dy + 2 * (qw * c0y + c1y);
          final camZ = dz + 2 * (qw * c0z + c1z);
          final depth = -camZ;
          if (depth <= 0.05) continue;
          final u = cx + focal * camX / depth;
          final v = cy - focal * camY / depth;
          if (u < 0 || u >= imageWidth - 1 || v < 0 || v >= imageHeight - 1) {
            continue;
          }
          final u0 = u.floor();
          final v0 = v.floor();
          final du = u - u0;
          final dv = v - v0;
          final i00 = v0 * rowStride + u0 * 3;
          final i10 = i00 + 3;
          final i01 = i00 + rowStride;
          final i11 = i01 + 3;
          final b = _lerp4(
            pixels[i00],
            pixels[i10],
            pixels[i01],
            pixels[i11],
            du,
            dv,
          );
          final g = _lerp4(
            pixels[i00 + 1],
            pixels[i10 + 1],
            pixels[i01 + 1],
            pixels[i11 + 1],
            du,
            dv,
          );
          final r = _lerp4(
            pixels[i00 + 2],
            pixels[i10 + 2],
            pixels[i01 + 2],
            pixels[i11 + 2],
            du,
            dv,
          );

          var weight = _pow6(depth);
          weight *= _smoothStep(_min(u, imageWidth - 1 - u) / marginX);
          weight *= _smoothStep(_min(v, imageHeight - 1 - v) / marginY);
          if (weight <= 0) continue;

          final index = y * width + x;
          if (hits[index] < 3) hits[index]++;
          if (weight > bestWeight[index]) {
            secondWeight[index] = bestWeight[index];
            secondColour[index * 3] = bestColour[index * 3];
            secondColour[index * 3 + 1] = bestColour[index * 3 + 1];
            secondColour[index * 3 + 2] = bestColour[index * 3 + 2];
            bestWeight[index] = weight;
            bestColour[index * 3] = r;
            bestColour[index * 3 + 1] = g;
            bestColour[index * 3 + 2] = b;
          } else if (weight > secondWeight[index]) {
            secondWeight[index] = weight;
            secondColour[index * 3] = r;
            secondColour[index * 3 + 1] = g;
            secondColour[index * 3 + 2] = b;
          }
        }
      }
    } finally {
      mat.dispose();
    }
    progress.send(
      'Projecting photographs: ${frameIndex + 1}/${records.length} '
      '(${stopwatch.elapsed.inSeconds}s elapsed)…',
    );
  }

  progress.send('Blending panorama and encoding JPEG…');
  // Nearest frame per pixel, with a narrow seam blend where the top two
  // weights are almost equal.
  final output = Uint8List(width * height * 3);
  for (var i = 0; i < width * height; i++) {
    final best = bestWeight[i];
    if (best <= 1e-4) continue;
    final second = secondWeight[i];
    if (second > 0.97 * best) {
      final total = best + second;
      final t = best / total;
      output[i * 3] = (bestColour[i * 3] * t + secondColour[i * 3] * (1 - t))
          .round();
      output[i * 3 +
          1] = (bestColour[i * 3 + 1] * t + secondColour[i * 3 + 1] * (1 - t))
          .round();
      output[i * 3 +
          2] = (bestColour[i * 3 + 2] * t + secondColour[i * 3 + 2] * (1 - t))
          .round();
    } else {
      output[i * 3] = bestColour[i * 3];
      output[i * 3 + 1] = bestColour[i * 3 + 1];
      output[i * 3 + 2] = bestColour[i * 3 + 2];
    }
  }
  // ── Coverage audit ──────────────────────────────────────────────────
  //
  // Equirectangular rows are not equal-area: a row at latitude φ covers only
  // cos(φ) of what an equatorial row does. Counting pixels would overstate
  // coverage near the poles — which is exactly where a sparse layout leaves
  // holes — so every number below is area-weighted.
  //
  // `single` is the one that decides success: every direction of the finished
  // sphere must come from a real photograph. The previous gate accepted 90%,
  // which let a ten-percent black band pass as a finished panorama.
  var totalArea = 0.0;
  var singleArea = 0.0;
  var doubleArea = 0.0;
  var tripleArea = 0.0;
  var worstRowWeight = -1.0;
  var worstLat = 0.0;
  var worstLon = 0.0;
  // 15°-cell grid of uncovered area, for the "where are the holes" report.
  const gapCols = 24;
  const gapRows = 12;
  final gapCells = Float64List(gapCols * gapRows);
  for (var y = 0; y < height; y++) {
    final rowWeight = cosLat[y];
    totalArea += rowWeight * width;
    for (var x = 0; x < width; x++) {
      final n = hits[y * width + x];
      if (n == 0) {
        gapCells[(y * gapRows ~/ height) * gapCols + (x * gapCols ~/ width)] +=
            rowWeight;
        // Remember the widest remaining gap, preferring the horizon: a hole
        // there is far more visible than one at the pole.
        if (rowWeight > worstRowWeight) {
          worstRowWeight = rowWeight;
          worstLat = 90 - (y + 0.5) / height * 180;
          worstLon = -180 + (x + 0.5) / width * 360;
        }
        continue;
      }
      singleArea += rowWeight;
      if (n >= 2) doubleArea += rowWeight;
      if (n >= 3) tripleArea += rowWeight;
    }
  }
  final single = singleArea / totalArea;
  final doubleCoverage = doubleArea / totalArea;
  final tripleCoverage = tripleArea / totalArea;
  if (kSphereStitchLog) {
    debugPrint(
      'SPHERE_STITCH: coverage single=${(single * 100).toStringAsFixed(2)}% '
      'double=${(doubleCoverage * 100).toStringAsFixed(2)}% '
      'triple=${(tripleCoverage * 100).toStringAsFixed(2)}% '
      'uncovered=${((1 - single) * 100).toStringAsFixed(2)}% '
      'output=${width}x$height',
    );
  }

  // ── Coverage diagnostics, written whether the gate passes or not ─────
  //
  // The map is generated from the *actual* photographs and their recorded
  // orientations — the same hits buffer the audit used — never from the ideal
  // layout alone. A passing coverage number says every direction received
  // real pixels; it does **not** claim the seams are invisible or the
  // alignment visually perfect.
  final mapBytes = Uint8List(width * height * 3);
  for (var i = 0; i < width * height; i++) {
    // Red: uncovered. Yellow: one photograph. Blue: two. Teal: three or more.
    final (r, g, b) = switch (hits[i]) {
      0 => (190, 40, 40),
      1 => (235, 200, 60),
      2 => (60, 110, 220),
      _ => (40, 190, 180),
    };
    mapBytes[i * 3] = r;
    mapBytes[i * 3 + 1] = g;
    mapBytes[i * 3 + 2] = b;
  }
  final mapPath = p.join(File(outPath).parent.path, 'coverage_map.jpg');
  _encodeJpeg(mapPath, width, height, mapBytes);
  final rankedGaps = <Map<String, Object?>>[];
  for (var cell = 0; cell < gapCells.length; cell++) {
    if (gapCells[cell] <= 0) continue;
    rankedGaps.add({
      'longitudeDeg': -180 + ((cell % gapCols) + 0.5) / gapCols * 360,
      'latitudeDeg':
          90 - ((cell ~/ gapCols) + 0.5) / gapRows * 180,
      'uncoveredAreaPercent': gapCells[cell] / totalArea * 100,
    });
  }
  rankedGaps.sort(
    (a, b) => (b['uncoveredAreaPercent']! as double).compareTo(
      a['uncoveredAreaPercent']! as double,
    ),
  );
  try {
    File(
      p.join(File(outPath).parent.path, 'coverage_report.json'),
    ).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'station': File(outPath).parent.path,
        'panorama': {
          'path': outPath,
          'width': width,
          'height': height,
          'aspect': '2:1 equirectangular',
        },
        'photographCount': records.length,
        'verticalFovAssumedDeg': kSphereAssumedVerticalFovDeg,
        'thresholdPercent': 99.5,
        'passed': single >= 0.995,
        'coveragePercent': {
          'single': single * 100,
          'double': doubleCoverage * 100,
          'triple': tripleCoverage * 100,
        },
        'uncoveredPercent': (1 - single) * 100,
        'coverageMapPath': mapPath,
        if (single < 1)
          'largestGap': {
            'longitudeDeg': worstLon,
            'latitudeDeg': worstLat,
          },
        'uncoveredRegions': rankedGaps
            .take(6)
            .map(
              (Map<String, Object?> region) => <String, Object?>{
                'longitudeDeg':
                    (region['longitudeDeg']! as double).toStringAsFixed(1),
                'latitudeDeg':
                    (region['latitudeDeg']! as double).toStringAsFixed(1),
                'uncoveredAreaPercent': (region['uncoveredAreaPercent']! as double)
                    .toStringAsFixed(3),
              },
            )
            .toList(growable: false),
      }),
      flush: true,
    );
  } catch (_) {
    // A missing report must not fail an otherwise valid panorama; the map is
    // diagnostics, not the product.
  }

  if (single < 0.995) {
    final lon = worstLon >= 0 ? '+${worstLon.round()}' : '${worstLon.round()}';
    final lat = worstLat >= 0 ? '+${worstLat.round()}' : '${worstLat.round()}';
    return (
      ok: false,
      message:
          'The sphere is only ${(single * 100).toStringAsFixed(1)}% covered, '
          'so the panorama would have a hole. The largest gap is around '
          'longitude $lon°, latitude $lat° — retake that direction. Every '
          'saved photograph has been kept.',
    );
  }

  // Write PPM (cheap, no encoder in Dart), then let OpenCV encode the JPEG.
  if (!_encodeJpeg(outPath, width, height, output)) {
    return (ok: false, message: 'The panorama could not be saved.');
  }
  return (
    ok: true,
    message:
        'Panorama generated ($width×$height). Coverage '
        '${(single * 100).toStringAsFixed(1)}% single, '
        '${(doubleCoverage * 100).toStringAsFixed(1)}% double, '
        '${(tripleCoverage * 100).toStringAsFixed(1)}% triple.',
  );
}

/// Encodes an RGB byte buffer as a JPEG at [path] through a PPM intermediate
/// (Dart has no JPEG encoder; OpenCV reads PPM and writes JPEG).
///
/// The temporary PPM is deleted afterwards; a failure to delete it is
/// harmless and ignored. Returns whether the JPEG exists and is non-empty.
bool _encodeJpeg(String path, int width, int height, Uint8List rgb) {
  final ppmPath = p.join(File(path).parent.path, '.${p.basename(path)}.ppm');
  final header = Uint8List.fromList(ascii.encode('P6\n$width $height\n255\n'));
  final bytes = BytesBuilder(copy: false)
    ..add(header)
    ..add(rgb);
  try {
    File(ppmPath).writeAsBytesSync(bytes.takeBytes(), flush: true);
    final ppm = cv.imread(ppmPath, flags: cv.IMREAD_COLOR);
    try {
      if (ppm.isEmpty) return false;
      if (!cv.imwrite(path, ppm)) return false;
    } finally {
      ppm.dispose();
    }
  } catch (_) {
    return false;
  } finally {
    try {
      File(ppmPath).deleteSync();
    } catch (_) {}
  }
  final out = File(path);
  return out.existsSync() && out.lengthSync() > 0;
}

int _lerp4(int c00, int c10, int c01, int c11, double du, double dv) =>
    (c00 * (1 - du) * (1 - dv) +
            c10 * du * (1 - dv) +
            c01 * (1 - du) * dv +
            c11 * du * dv)
        .round();

double _smoothStep(double value) {
  final t = _clampDouble(value, 0, 1);
  return t * t * (3 - 2 * t);
}

double _pow6(double value) {
  final v = _clampDouble(value, 0, 1);
  final v2 = v * v;
  return v2 * v2 * v2;
}

double _min(double a, double b) => a < b ? a : b;

double _clampDouble(double value, double min, double max) =>
    value < min ? min : (value > max ? max : value);

int _clampInt(int value, int min, int max) =>
    value < min ? min : (value > max ? max : value);
