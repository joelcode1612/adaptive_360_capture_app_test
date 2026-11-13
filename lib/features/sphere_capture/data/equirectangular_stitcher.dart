import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

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
/// stitch caused an ANR).
class EquirectangularStitcher implements PanoramaStitcher {
  const EquirectangularStitcher({this.width = 2048});

  /// Output width in pixels; height is half of it, i.e. a 2:1 equirectangular.
  final int width;

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
    onStage?.call('Projecting ${imagePaths.length} photographs…');
    try {
      final result = await Isolate.run(
        () => _projectEquirect(stationDir, outPath, width),
      );
      if (!result.ok) return StitchResult.failure(result.message);
      return StitchResult(
        success: true,
        panoramaPath: outPath,
        message: 'Panorama generated successfully.',
      );
    } catch (error) {
      return StitchResult.failure('Panorama projection failed: $error');
    }
  }
}

/// The projection, on a background isolate.
({bool ok, String message}) _projectEquirect(
  String stationDir,
  String outPath,
  int width,
) {
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

  for (final record in records) {
    final path = record['imagePath'] as String?;
    if (path == null || !File(path).existsSync()) {
      return (ok: false, message: 'A captured photograph is missing: $path');
    }
    final mat = cv.imread(path, flags: cv.IMREAD_COLOR);
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
      final focal =
          0.75 * (imageWidth > imageHeight ? imageWidth : imageHeight);
      final cx = imageWidth / 2;
      final cy = imageHeight / 2;
      final pixels = mat.data;
      final rowStride = imageWidth * 3;

      final bounds = _lonLatBounds(
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
      final fullWidth =
          bounds.span >= 3.0 ||
          cameraToSphere.rotate(const Vec3(0, 0, -1)).y.abs() > 0.8;
      final xStart = fullWidth
          ? 0
          : ((bounds.minLon + 3.141592653589793) / 6.283185307179586 * width)
                    .floor() -
                2;
      final xEnd = fullWidth
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
          final x = ((xi % width) + width) % width;
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
          final marginX = 0.05 * imageWidth;
          final marginY = 0.05 * imageHeight;
          weight *= _smoothStep(_min(u, imageWidth - 1 - u) / marginX);
          weight *= _smoothStep(_min(v, imageHeight - 1 - v) / marginY);
          if (weight <= 0) continue;

          final index = y * width + x;
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
  }

  // Nearest frame per pixel, with a narrow seam blend where the top two
  // weights are almost equal.
  final output = Uint8List(width * height * 3);
  var covered = 0;
  for (var i = 0; i < width * height; i++) {
    final best = bestWeight[i];
    if (best <= 1e-4) continue;
    covered++;
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
  if (covered < width * height * 0.9) {
    return (
      ok: false,
      message:
          'Only ${(covered / (width * height) * 100).round()}% of the sphere '
          'was covered. The capture may be missing frames.',
    );
  }

  // Write PPM (cheap, no encoder in Dart), then let OpenCV encode the JPEG.
  final ppmPath = p.join(File(outPath).parent.path, '.panorama.ppm');
  final header = Uint8List.fromList(ascii.encode('P6\n$width $height\n255\n'));
  final bytes = BytesBuilder(copy: false)
    ..add(header)
    ..add(output);
  File(ppmPath).writeAsBytesSync(bytes.takeBytes(), flush: true);
  final ppm = cv.imread(ppmPath, flags: cv.IMREAD_COLOR);
  if (ppm.isEmpty) {
    ppm.dispose();
    return (ok: false, message: 'The panorama canvas could not be encoded.');
  }
  try {
    if (!cv.imwrite(outPath, ppm)) {
      return (ok: false, message: 'The panorama could not be saved.');
    }
  } finally {
    ppm.dispose();
    try {
      File(ppmPath).deleteSync();
    } catch (_) {
      // Best effort; the JPEG is what matters.
    }
  }
  return (ok: true, message: 'Panorama generated successfully.');
}

/// Longitude/latitude bounds of a frame's image rectangle, in radians.
({double minLon, double maxLon, double minLat, double maxLat, double span})
_lonLatBounds(
  Quat cameraToSphere,
  int width,
  int height,
  double focal,
  double cx,
  double cy,
) {
  var minLon = 10.0;
  var maxLon = -10.0;
  var minLat = 10.0;
  var maxLat = -10.0;
  // Sample the four edges, not just the corners: a projected rectangle bows
  // outward, so corners alone can under-estimate the covered region.
  for (var i = 0; i <= 8; i++) {
    final t = i / 8;
    final samples = <(double, double)>[
      (t * (width - 1), 0),
      (t * (width - 1), height - 1),
      (0, t * (height - 1)),
      (width - 1, t * (height - 1)),
    ];
    for (final (u, v) in samples) {
      final cam = Vec3((u - cx) / focal, -(v - cy) / focal, -1).normalized;
      final dir = cameraToSphere.rotate(cam);
      final lon = math.atan2(dir.x, -dir.z);
      final lat = math.asin(_clampDouble(dir.y, -1, 1));
      if (lon < minLon) minLon = lon;
      if (lon > maxLon) maxLon = lon;
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
    }
  }
  // Unwrap around the frame centre so a frame near ±180° gets a contiguous
  // range instead of a min/max spanning the whole circle.
  final centreLon = math.atan2(
    cameraToSphere.rotate(const Vec3(0, 0, -1)).x,
    -cameraToSphere.rotate(const Vec3(0, 0, -1)).z,
  );
  minLon = _unwrap(minLon, centreLon);
  maxLon = _unwrap(maxLon, centreLon);
  if (maxLon - minLon > 3.141592653589793) {
    // A frame that straddles the seam: treat it as full width.
    return (
      minLon: -3.141592653589793,
      maxLon: 3.141592653589793,
      minLat: minLat,
      maxLat: maxLat,
      span: 6.283185307179586,
    );
  }
  const margin = 0.035;
  return (
    minLon: minLon - margin,
    maxLon: maxLon + margin,
    minLat: _clampDouble(
      minLat - margin,
      -1.5707963267948966,
      1.5707963267948966,
    ),
    maxLat: _clampDouble(
      maxLat + margin,
      -1.5707963267948966,
      1.5707963267948966,
    ),
    span: maxLon - minLon,
  );
}

double _unwrap(double angle, double centre) {
  var value = angle;
  while (value - centre > 3.141592653589793) {
    value -= 6.283185307179586;
  }
  while (value - centre < -3.141592653589793) {
    value += 6.283185307179586;
  }
  return value;
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
