import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/data/equirectangular_stitcher.dart';

/// Verification for the three repairs made after reviewing a real capture that
/// shipped with black discs at the zenith and nadir.
///
/// These exercise the pure algorithms directly — no camera, no OpenCV, no
/// isolate — because each one is a function over typed arrays and nothing about
/// it needs a device.
void main() {
  group('exposure gains', () {
    test('pulls a brighter photograph down to its neighbour', () {
      // Frame 1 sees the same wall at twice the brightness of frame 0. The
      // correction must halve frame 1, not double it — the sign is the whole
      // point of this test.
      const pixelCount = 64;
      final gains = solveExposureGains(
        pixelCount: pixelCount,
        frameCount: 2,
        bestFrame: Int16List(pixelCount)..fillRange(0, pixelCount, 1),
        secondFrame: Int16List(pixelCount)..fillRange(0, pixelCount, 0),
        bestWeight: Float32List(pixelCount)..fillRange(0, pixelCount, 1),
        secondWeight: Float32List(pixelCount)..fillRange(0, pixelCount, 1),
        bestColour: _flatColour(pixelCount, 200),
        secondColour: _flatColour(pixelCount, 100),
      );
      expect(gains.length, 2);
      expect(gains[1] / gains[0], closeTo(0.5, 0.02));
    });

    test('leaves an evenly exposed pair at unity', () {
      const pixelCount = 64;
      final gains = solveExposureGains(
        pixelCount: pixelCount,
        frameCount: 2,
        bestFrame: Int16List(pixelCount)..fillRange(0, pixelCount, 1),
        secondFrame: Int16List(pixelCount)..fillRange(0, pixelCount, 0),
        bestWeight: Float32List(pixelCount)..fillRange(0, pixelCount, 1),
        secondWeight: Float32List(pixelCount)..fillRange(0, pixelCount, 1),
        bestColour: _flatColour(pixelCount, 128),
        secondColour: _flatColour(pixelCount, 128),
      );
      expect(gains[0], closeTo(1.0, 0.001));
      expect(gains[1], closeTo(1.0, 0.001));
    });

    test('does not trust a pair it has barely seen', () {
      // Ten overlapping pixels is not evidence of an exposure difference; a
      // handful of samples on a textured edge would otherwise set the gain.
      const pixelCount = 10;
      final gains = solveExposureGains(
        pixelCount: pixelCount,
        frameCount: 2,
        bestFrame: Int16List(pixelCount)..fillRange(0, pixelCount, 1),
        secondFrame: Int16List(pixelCount)..fillRange(0, pixelCount, 0),
        bestWeight: Float32List(pixelCount)..fillRange(0, pixelCount, 1),
        secondWeight: Float32List(pixelCount)..fillRange(0, pixelCount, 1),
        bestColour: _flatColour(pixelCount, 200),
        secondColour: _flatColour(pixelCount, 100),
      );
      expect(gains[0], closeTo(1.0, 1e-9));
      expect(gains[1], closeTo(1.0, 1e-9));
    });

    test('normalises so the panorama does not drift overall', () {
      const pixelCount = 64;
      final gains = solveExposureGains(
        pixelCount: pixelCount,
        frameCount: 2,
        bestFrame: Int16List(pixelCount)..fillRange(0, pixelCount, 1),
        secondFrame: Int16List(pixelCount)..fillRange(0, pixelCount, 0),
        bestWeight: Float32List(pixelCount)..fillRange(0, pixelCount, 1),
        secondWeight: Float32List(pixelCount)..fillRange(0, pixelCount, 1),
        bestColour: _flatColour(pixelCount, 200),
        secondColour: _flatColour(pixelCount, 100),
      );
      // Only ratios are observable, so the geometric mean must stay at 1.
      final mean = (gains[0] + gains[1]) / 2;
      expect(mean, closeTo(1.0, 0.001));
    });
  });

  group('gap fill', () {
    test('replaces a hole with its surroundings instead of black', () {
      const width = 8;
      const height = 4;
      const pixelCount = width * height;
      final output = Uint8List(pixelCount * 3);
      for (var i = 0; i < pixelCount; i++) {
        output[i * 3] = 120;
        output[i * 3 + 1] = 90;
        output[i * 3 + 2] = 60;
      }
      final bestWeight = Float32List(pixelCount)
        ..fillRange(0, pixelCount, 1);
      // A 2x2 hole in the middle, exactly as an uncovered direction appears.
      final hole = <int>[
        1 * width + 3,
        1 * width + 4,
        2 * width + 3,
        2 * width + 4,
      ];
      for (final i in hole) {
        bestWeight[i] = 0;
        output[i * 3] = 0;
        output[i * 3 + 1] = 0;
        output[i * 3 + 2] = 0;
      }

      final filled = fillUncovered(
        output: output,
        bestWeight: bestWeight,
        width: width,
        height: height,
      );

      expect(filled, 4);
      for (final i in hole) {
        expect(
          output[i * 3],
          greaterThan(0),
          reason: 'a filled pixel must never stay at zero',
        );
        expect(output[i * 3], closeTo(120, 25));
        expect(output[i * 3 + 1], closeTo(90, 25));
        expect(output[i * 3 + 2], closeTo(60, 25));
      }
    });

    test('does nothing when every pixel has a photograph', () {
      const width = 6;
      const height = 3;
      const pixelCount = width * height;
      final output = Uint8List(pixelCount * 3)
        ..fillRange(0, pixelCount * 3, 77);
      final before = Uint8List.fromList(output);
      final filled = fillUncovered(
        output: output,
        bestWeight: Float32List(pixelCount)..fillRange(0, pixelCount, 1),
        width: width,
        height: height,
      );
      expect(filled, 0);
      expect(output, before);
    });

    test('fills a hole that spans the whole longitude wrap', () {
      // A polar cap is not a small blob: it wraps the entire seam at +/-180.
      // If the fill walked columns without wrapping, the left and right edges of
      // the cap would stay black.
      const width = 16;
      const height = 8;
      const pixelCount = width * height;
      final output = Uint8List(pixelCount * 3)
        ..fillRange(0, pixelCount * 3, 100);
      final bestWeight = Float32List(pixelCount)
        ..fillRange(0, pixelCount, 1);
      for (var x = 0; x < width; x++) {
        final i = x;
        bestWeight[i] = 0;
        output[i * 3] = 0;
        output[i * 3 + 1] = 0;
        output[i * 3 + 2] = 0;
      }

      final filled = fillUncovered(
        output: output,
        bestWeight: bestWeight,
        width: width,
        height: height,
      );

      expect(filled, width);
      for (var x = 0; x < width; x++) {
        expect(output[x * 3], greaterThan(0));
      }
    });
  });

  group('viewport audit', () {
    const width = 360;
    const height = 180;

    test('a fully covered sphere reports no gap', () {
      final result = worstViewportGap(
        hits: Uint8List(width * height)..fillRange(0, width * height, 1),
        width: width,
        height: height,
      );
      expect(result.gap, lessThan(0.01));
    });

    test('a polar hole is small in area and large in a view', () {
      // Zero the top ten rows: latitude 90 down to 80.
      final hits = Uint8List(width * height)
        ..fillRange(0, width * height, 1);
      const holeRows = 10;
      for (var y = 0; y < holeRows; y++) {
        for (var x = 0; x < width; x++) {
          hits[y * width + x] = 0;
        }
      }

      final result = worstViewportGap(
        hits: hits,
        width: width,
        height: height,
      );

      // Area-weighted, this hole is a fraction of a percent of the sphere — the
      // number the old gate looked at, and the reason a black disc could pass it.
      final lowestLatRad = (90 - holeRows * 180 / height) * math.pi / 180;
      final areaFraction = (1 - math.sin(lowestLatRad)) / 2;
      expect(areaFraction, lessThan(0.01));

      // In a 90° view it is several percent of everything the user can see.
      expect(result.gap, greaterThan(0.03));
      expect(
        result.gap,
        greaterThan(areaFraction * 4),
        reason: 'the viewport metric must amplify what the area metric hides',
      );
      expect(result.latitudeDeg.abs(), greaterThan(40));
    });

    test('an equatorial hole is reported too', () {
      final hits = Uint8List(width * height)
        ..fillRange(0, width * height, 1);
      for (var y = 86; y < 94; y++) {
        for (var x = 0; x < width; x++) {
          hits[y * width + x] = 0;
        }
      }
      final result = worstViewportGap(
        hits: hits,
        width: width,
        height: height,
      );
      expect(result.gap, greaterThan(0.0));
      expect(result.latitudeDeg.abs(), lessThan(20));
    });
  });
}

Uint8List _flatColour(int pixelCount, int value) {
  final buffer = Uint8List(pixelCount * 3);
  for (var i = 0; i < buffer.length; i++) {
    buffer[i] = value;
  }
  return buffer;
}
