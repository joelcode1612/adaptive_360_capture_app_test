import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// The longitude/latitude interval a frame can contribute to, in radians.
///
/// ## The seam
///
/// A photograph centred near ±180° has edge samples on **both** sides of the
/// panorama seam: `atan2` returns +179° for one and −176° for another. Taking
/// the minimum and maximum of those raw values gives an interval that runs the
/// wrong way round the circle, and the old code then unwrapped `min` and `max`
/// *independently* — which could leave `maxLon < minLon`, so the column loop
/// ran zero times and the photograph was silently dropped. That is a hole in
/// the panorama that no amount of retaking fixes, because the frame was never
/// projected at all.
///
/// Every sample is therefore unwrapped **around the frame's own centre
/// longitude before** the minimum and maximum are taken. The interval is then
/// contiguous by construction, `minLon <= maxLon`, and a frame that crosses the
/// seam simply produces a range that extends past ±π. The caller converts that
/// to columns and wraps them with `% width`, so no interval is ever reversed.
///
/// ## Poles
///
/// A frame looking at the zenith or nadir covers **every** longitude: its
/// projected rectangle encircles the pole, and no single interval describes it.
/// Those frames are marked [fullWidth], as is any frame whose axis is within
/// ~37° of vertical or whose sampled latitude reaches 80° — a cheap, safe
/// over-estimate that costs one full-row scan and can never skip a pixel.
///
/// Pure and public so the seam behaviour is testable without an image or a
/// device.
({double minLon, double maxLon, double minLat, double maxLat, bool fullWidth})
equirectFrameBounds(
  Quat cameraToSphere,
  int width,
  int height,
  double focal,
  double cx,
  double cy,
) {
  const double twoPi = 6.283185307179586;
  const double halfPi = 1.5707963267948966;

  // The optical axis in sphere coordinates, and the centre longitude every
  // sample is unwrapped around.
  final axis = cameraToSphere.rotate(const Vec3(0, 0, -1));
  final centreLon = math.atan2(axis.x, -axis.z);

  var minLon = double.infinity;
  var maxLon = -double.infinity;
  var minLat = halfPi;
  var maxLat = -halfPi;

  // Nine samples per edge, not four corners: a projected rectangle bows
  // outward, so corners alone under-estimate the covered region.
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
      // Unwrap before comparing — this is the fix.
      final lon = _unwrap(math.atan2(dir.x, -dir.z), centreLon);
      final lat = math.asin(_clampDouble(dir.y, -1, 1));
      if (lon < minLon) minLon = lon;
      if (lon > maxLon) maxLon = lon;
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
    }
  }

  // Does the frame actually contain a pole? Sampling the edges cannot answer
  // that: a zenith frame's border sits at 90° − vfov/2, so its latitude range
  // would stop ~23° short of the pole and the stitcher would leave the cap
  // black. Project the pole into the camera frame instead and test the frustum.
  bool containsPole(Vec3 world) {
    final cam = cameraToSphere.conjugate.rotate(world);
    final depth = -cam.z;
    if (depth <= 0.05) return false;
    final halfW = (width / 2) / focal;
    final halfH = (height / 2) / focal;
    return (cam.x / depth).abs() <= halfW && (cam.y / depth).abs() <= halfH;
  }

  final containsZenith = containsPole(const Vec3(0, 1, 0));
  final containsNadir = containsPole(const Vec3(0, -1, 0));
  if (containsZenith) maxLat = halfPi;
  if (containsNadir) minLat = -halfPi;

  // A frame that contains a pole covers every longitude: its rectangle
  // encircles the pole and no single interval describes it.
  final fullWidth =
      containsZenith || containsNadir || (maxLon - minLon) >= twoPi - 0.05;

  const double margin = 0.035;
  return (
    minLon: minLon - margin,
    maxLon: maxLon + margin,
    minLat: _clampDouble(minLat - margin, -halfPi, halfPi),
    maxLat: _clampDouble(maxLat + margin, -halfPi, halfPi),
    fullWidth: fullWidth,
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

double _clampDouble(double value, double min, double max) =>
    value < min ? min : (value > max ? max : value);
