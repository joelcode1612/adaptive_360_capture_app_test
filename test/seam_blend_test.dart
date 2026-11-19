import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/seam_blend.dart';

/// Unit tests for seam selection and the multi-band composite.
///
/// The scenario throughout is the reported defect: two photographs of the same
/// object that disagree by a few pixels of parallax. Averaging drew both edges
/// at partial strength (ghosting); seam selection draws one.
///
/// The same assertions runnable on the plain VM live in
/// `tool/verify_seam_blend.dart`, because `flutter test` is blocked on the
/// development host by the native-assets sandbox probe.
void main() {
  const int width = 64;
  const int height = 32;

  /// Flat background (200) with one dark bar (60).
  Uint8List frameWithBar(int start, int end) {
    final rgb = Uint8List(width * height * 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final v = (x >= start && x < end) ? 60 : 200;
        final i = (y * width + x) * 3;
        rgb[i] = v;
        rgb[i + 1] = v;
        rgb[i + 2] = v;
      }
    }
    return rgb;
  }

  List<double> columnMeans(Uint8List rgb) => <double>[
    for (var x = 0; x < width; x++)
      () {
        var sum = 0.0;
        for (var y = 0; y < height; y++) {
          sum += rgb[(y * width + x) * 3];
        }
        return sum / height;
      }(),
  ];

  /// Columns neither fully background nor fully object — the signature of an
  /// averaged duplicate.
  int partialColumns(List<double> columns) =>
      columns.where((double v) => v > 65 && v < 195).length;

  test('parallax disagreement is drawn once, not twice', () {
    final a = frameWithBar(10, 20);
    final b = frameWithBar(14, 24);

    final bestColour = Uint8List(width * height * 3);
    final secondColour = Uint8List(width * height * 3);
    final bestWeight = Float32List(width * height);
    final secondWeight = Float32List(width * height);
    final bestFrame = Int16List(width * height);
    final secondFrame = Int16List(width * height);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final aIsBest = x < 32;
        bestWeight[i] = 1.0;
        secondWeight[i] = 0.2;
        bestFrame[i] = aIsBest ? 0 : 1;
        secondFrame[i] = aIsBest ? 1 : 0;
        for (var c = 0; c < 3; c++) {
          bestColour[i * 3 + c] = aIsBest ? a[i * 3 + c] : b[i * 3 + c];
          secondColour[i * 3 + c] = aIsBest ? b[i * 3 + c] : a[i * 3 + c];
        }
      }
    }

    final output = Uint8List(width * height * 3);
    final stats = compositeSeams(
      output: output,
      width: width,
      height: height,
      bestColour: bestColour,
      secondColour: secondColour,
      bestWeight: bestWeight,
      secondWeight: secondWeight,
      bestFrame: bestFrame,
      secondFrame: secondFrame,
      channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );

    expect(partialColumns(columnMeans(output)), 0);
    expect(stats.overlapPixels, width * height);
    expect(stats.usedSecondBand, isTrue);
    expect(stats.cutUsed, isTrue);
    expect(stats.seamDiscontinuity, lessThan(1.0));
  });

  test('nonzero frame ID does not cause phantom full-image feather', () {
    // Regression: looking at uninitialised right/down owner pixels interpreted
    // a constant frame ID of 2 as a seam covering nearly the whole canvas.
    final count = width * height;
    final best = Uint8List(count * 3)..fillRange(0, count * 3, 200);
    final second = Uint8List(count * 3)..fillRange(0, count * 3, 30);
    final bw = Float32List(count)..fillRange(0, count, 1.0);
    final sw = Float32List(count)..fillRange(0, count, 0.5);
    final bf = Int16List(count)..fillRange(0, count, 2);
    final sf = Int16List(count)..fillRange(0, count, 1);
    final output = Uint8List(count * 3);
    final stats = compositeSeams(
      output: output,
      width: width,
      height: height,
      bestColour: best,
      secondColour: second,
      bestWeight: bw,
      secondWeight: sw,
      bestFrame: bf,
      secondFrame: sf,
      channelGains: <double>[1, 1, 1, 1, 1, 1, 1, 1, 1],
      minWeight: 0.001,
    );
    expect(output.every((int v) => v == 200), isTrue);
    expect(stats.seamPixels, 0);
  });

  test('unrelated third frame is not mixed across an owner boundary', () {
    final count = width * height;
    final best = Uint8List(count * 3)..fillRange(0, count * 3, 190);
    final second = Uint8List(count * 3)..fillRange(0, count * 3, 80);
    final bw = Float32List(count)..fillRange(0, count, 1.0);
    final sw = Float32List(count)..fillRange(0, count, 0.5);
    final bf = Int16List(count);
    final sf = Int16List(count)..fillRange(0, count, 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        bf[y * width + x] = x < width ~/ 2 ? 1 : 2;
      }
    }
    final output = Uint8List(count * 3);
    final stats = compositeSeams(
      output: output,
      width: width,
      height: height,
      bestColour: best,
      secondColour: second,
      bestWeight: bw,
      secondWeight: sw,
      bestFrame: bf,
      secondFrame: sf,
      channelGains: <double>[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
      minWeight: 0.001,
    );
    expect(stats.seamPixels, greaterThan(0));
    expect(output.every((int v) => v == 190), isTrue);
  });

  test('isolated seam tooth is smoothed only when photos agree', () {
    const w = 7;
    const h = 7;
    final n = w * h;
    final label = Uint8List(n);
    label[3 * w + 3] = 1;
    final bFrame = Int16List(n);
    final sFrame = Int16List(n)..fillRange(0, n, 1);
    final bw = Float32List(n)..fillRange(0, n, 1);
    final sw = Float32List(n)..fillRange(0, n, 0.8);
    final a = Uint8List(n * 3)..fillRange(0, n * 3, 100);
    final b = Uint8List(n * 3)..fillRange(0, n * 3, 110);
    final removed = smoothIsolatedSeamSpikes(
      label: label, width: w, height: h,
      bestFrame: bFrame, secondFrame: sFrame,
      bestWeight: bw, secondWeight: sw,
      bestColour: a, secondColour: b, minWeight: 0.001,
    );
    expect(removed, 1);
    expect(label[3 * w + 3], 0);

    // Same jagged topology but wildly different scene content. Never
    // substitute a second object just to hide the border.
    label[3 * w + 3] = 1;
    b.fillRange(0, n * 3, 220);
    final unsafe = smoothIsolatedSeamSpikes(
      label: label, width: w, height: h,
      bestFrame: bFrame, secondFrame: sFrame,
      bestWeight: bw, secondWeight: sw,
      bestColour: a, secondColour: b, minWeight: 0.001,
    );
    expect(unsafe, 0);
    expect(label[3 * w + 3], 1);
  });

  test('identical contributors produce a byte-exact copy', () {
    final flat = Uint8List(width * height * 3)
      ..fillRange(0, width * height * 3, 137);
    final weight = Float32List(width * height)
      ..fillRange(0, width * height, 1.0);
    final second = Float32List(width * height)
      ..fillRange(0, width * height, 0.2);
    final frames = Int16List(width * height);
    final other = Int16List(width * height)..fillRange(0, width * height, 1);

    final output = Uint8List(width * height * 3);
    final stats = compositeSeams(
      output: output,
      width: width,
      height: height,
      bestColour: flat,
      secondColour: flat,
      bestWeight: weight,
      secondWeight: second,
      bestFrame: frames,
      secondFrame: other,
      channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );

    expect(output.every((int v) => v == 137), isTrue);
    expect(stats.ghostEnergy, 0);
    expect(stats.ghostFraction, 0);
  });

  test('no overlap is a straight copy with colour gain applied', () {
    final single = Uint8List(width * height * 3)
      ..fillRange(0, width * height * 3, 100);
    final weight = Float32List(width * height)
      ..fillRange(0, width * height, 1.0);
    final none = Float32List(width * height);
    final frames = Int16List(width * height);

    final output = Uint8List(width * height * 3);
    final stats = compositeSeams(
      output: output,
      width: width,
      height: height,
      bestColour: single,
      secondColour: single,
      bestWeight: weight,
      secondWeight: none,
      bestFrame: frames,
      secondFrame: frames,
      // Frame 0 dimmed to 60% across all three channels.
      channelGains: <double>[0.6, 0.6, 0.6, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );

    expect(output[0], 60);
    expect(stats.usedSecondBand, isFalse);
    expect(stats.overlapPixels, 0);
  });

  test('disagreement is measured, not hidden', () {
    final bright = Uint8List(width * height * 3)
      ..fillRange(0, width * height * 3, 187);
    final dark = Uint8List(width * height * 3)
      ..fillRange(0, width * height * 3, 137);
    final weight = Float32List(width * height)
      ..fillRange(0, width * height, 1.0);
    final second = Float32List(width * height)
      ..fillRange(0, width * height, 0.2);
    final frames = Int16List(width * height);
    final other = Int16List(width * height)..fillRange(0, width * height, 1);

    final output = Uint8List(width * height * 3);
    final stats = compositeSeams(
      output: output,
      width: width,
      height: height,
      bestColour: bright,
      secondColour: dark,
      bestWeight: weight,
      secondWeight: second,
      bestFrame: frames,
      secondFrame: other,
      channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );

    expect(stats.ghostEnergy, closeTo(50, 0.5));
    expect(stats.ghostFraction, closeTo(1.0, 0.001));
  });

  test('the seam moves off a localised disagreement', () {
    const blobStart = 38;
    const blobEnd = 42;
    final best = Uint8List(width * height * 3);
    final second = Uint8List(width * height * 3);
    final wBest = Float32List(width * height);
    final wSecond = Float32List(width * height);
    final bFrame = Int16List(width * height);
    final sFrame = Int16List(width * height);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final inBlob = x >= blobStart && x < blobEnd;
        final aIsBest = x < 40;
        const valueA = 150;
        final valueB = inBlob ? 30 : 150;
        bFrame[i] = aIsBest ? 0 : 1;
        sFrame[i] = aIsBest ? 1 : 0;
        wBest[i] = 1.0;
        wSecond[i] = 0.99;
        for (var c = 0; c < 3; c++) {
          best[i * 3 + c] = aIsBest ? valueA : valueB;
          second[i * 3 + c] = aIsBest ? valueB : valueA;
        }
      }
    }

    final output = Uint8List(width * height * 3);
    final stats = compositeSeams(
      output: output,
      width: width,
      height: height,
      bestColour: best,
      secondColour: second,
      bestWeight: wBest,
      secondWeight: wSecond,
      bestFrame: bFrame,
      secondFrame: sFrame,
      channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );

    expect(stats.flippedPixels, greaterThan(0));
    final columns = columnMeans(output);
    var worst = 0.0;
    for (var x = blobStart - 4; x < blobEnd + 4; x++) {
      final jump = (columns[x + 1] - columns[x]).abs();
      if (jump > worst) worst = jump;
    }
    expect(worst, lessThan(20), reason: 'the seam cut through the blob');
  });
}
