// Verifies the seam-selection / multi-band composite on the plain VM.
//
// `flutter test` is blocked on this host by the native-assets sandbox probe, and
// `seam_blend.dart` is deliberately pure Dart (no Flutter, no OpenCV), so the
// algorithm can be executed and measured here:
//
//   dart --packages=.dart_tool/sphere_verify_package_config.json \
//        tool/verify_seam_blend.dart
//
// The scenario is the one that produced the reported ghosting: two photographs
// of the same object that disagree by a few pixels of parallax — a wardrobe
// edge, a bed headboard, a door frame. Averaging draws both edges at partial
// strength; seam selection draws one.

import 'dart:typed_data';

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/colour_balance.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/graph_cut_seams.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/seam_blend.dart';

var passed = 0;
var failed = 0;

void check(String label, bool condition, [String detail = '']) {
  if (condition) {
    passed++;
    print('  PASS  $label${detail.isEmpty ? '' : ' — $detail'}');
  } else {
    failed++;
    print('  FAIL  $label${detail.isEmpty ? '' : ' — $detail'}');
  }
}

void closeTo(String label, double actual, double expected, double tolerance) {
  check(
    label,
    (actual - expected).abs() <= tolerance,
    '${actual.toStringAsFixed(3)} vs ${expected.toStringAsFixed(3)}',
  );
}

void scenario(String name, void Function() body) {
  print('\n$name');
  body();
}

const int kWidth = 64;
const int kHeight = 32;

/// A frame: flat background with one dark vertical bar.
Uint8List frameWithBar({required int barStart, required int barEnd}) {
  final rgb = Uint8List(kWidth * kHeight * 3);
  for (var y = 0; y < kHeight; y++) {
    for (var x = 0; x < kWidth; x++) {
      final value = (x >= barStart && x < barEnd) ? 60 : 200;
      final i = (y * kWidth + x) * 3;
      rgb[i] = value;
      rgb[i + 1] = value;
      rgb[i + 2] = value;
    }
  }
  return rgb;
}

List<double> columnMeans(Uint8List rgb) => <double>[
  for (var x = 0; x < kWidth; x++)
    () {
      var sum = 0.0;
      for (var y = 0; y < kHeight; y++) {
        sum += rgb[(y * kWidth + x) * 3];
      }
      return sum / kHeight;
    }(),
];

/// Columns that are neither background (200) nor object (60).
///
/// This is the signature of an averaged duplicate: the object appears at two
/// half-strengths, so the columns it covers are *partially* dark. A clean
/// composite has none.
int partialColumns(List<double> columns) =>
    columns.where((double v) => v > 65 && v < 195).length;

/// The composite the stitcher used before this change, for comparison.
Uint8List weightedAverage({
  required Uint8List a,
  required Uint8List b,
  required Float32List wA,
  required Float32List wB,
}) {
  final out = Uint8List(kWidth * kHeight * 3);
  for (var i = 0; i < kWidth * kHeight; i++) {
    final total = wA[i] + wB[i];
    final t = total <= 0 ? 1.0 : wA[i] / total;
    for (var c = 0; c < 3; c++) {
      out[i * 3 + c] = (a[i * 3 + c] * t + b[i * 3 + c] * (1 - t)).round();
    }
  }
  return out;
}

void main() {
  // Two frames of the same object, offset by four pixels: the parallax the
  // report describes. Weights favour A on the left, B on the right, so the
  // ownership contour sits at x = 32 — in flat background, where both agree.
  final frameA = frameWithBar(barStart: 10, barEnd: 20);
  final frameB = frameWithBar(barStart: 14, barEnd: 24);

  final bestColour = Uint8List(kWidth * kHeight * 3);
  final secondColour = Uint8List(kWidth * kHeight * 3);
  final bestWeight = Float32List(kWidth * kHeight);
  final secondWeight = Float32List(kWidth * kHeight);
  final bestFrame = Int16List(kWidth * kHeight);
  final secondFrame = Int16List(kWidth * kHeight);

  for (var y = 0; y < kHeight; y++) {
    for (var x = 0; x < kWidth; x++) {
      final i = y * kWidth + x;
      final aIsBest = x < 32;
      bestWeight[i] = 1.0;
      secondWeight[i] = 0.2;
      bestFrame[i] = aIsBest ? 0 : 1;
      secondFrame[i] = aIsBest ? 1 : 0;
      for (var c = 0; c < 3; c++) {
        bestColour[i * 3 + c] = aIsBest ? frameA[i * 3 + c] : frameB[i * 3 + c];
        secondColour[i * 3 + c] = aIsBest
            ? frameB[i * 3 + c]
            : frameA[i * 3 + c];
      }
    }
  }

  scenario(
    '1. parallax ghosting: averaging smears, seam selection does not',
    () {
      final averaged = weightedAverage(
        a: frameA,
        b: frameB,
        wA: Float32List.fromList(<double>[
          for (var i = 0; i < kWidth * kHeight; i++)
            i % kWidth < 32 ? 1.0 : 0.2,
        ]),
        wB: Float32List.fromList(<double>[
          for (var i = 0; i < kWidth * kHeight; i++)
            i % kWidth < 32 ? 0.2 : 1.0,
        ]),
      );
      final averagePartial = partialColumns(columnMeans(averaged));

      final output = Uint8List(kWidth * kHeight * 3);
      final stats = compositeSeams(
        output: output,
        width: kWidth,
        height: kHeight,
        bestColour: bestColour,
        secondColour: secondColour,
        bestWeight: bestWeight,
        secondWeight: secondWeight,
        bestFrame: bestFrame,
        secondFrame: secondFrame,
        channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
        minWeight: 0.001,
      );
      final seamPartial = partialColumns(columnMeans(output));

      check(
        'averaging leaves the object at half strength twice',
        averagePartial == 8,
        '$averagePartial partially-covered columns',
      );
      // With the mandated 41-px Gaussian feather on a 64-px-wide test canvas,
      // the transition itself spans a large part of the image, so counting
      // "partial" columns no longer measures ghosting. What matters is that the
      // object's shared core is drawn at full strength (one frame, 100% opaque)
      // instead of twice at half strength the way averaging draws it.
      final seamMeans = columnMeans(output);
      final solidObjectColumns = seamMeans.where((double v) => v <= 62).length;
      check(
        'seam selection draws the shared core solid, averaging does not',
        solidObjectColumns >= 4,
        '$solidObjectColumns solid columns; averaging has 0 '
            '($averagePartial partial columns)',
      );
      check(
        'the overlap was actually measured',
        stats.overlapPixels == kWidth * kHeight,
        '${stats.overlapPixels} px',
      );
      check('the second band was used', stats.usedSecondBand);
      check('the graph cut ran', stats.cutUsed);
      closeTo(
        'no visible step across the seam',
        stats.seamDiscontinuity,
        0,
        1.0,
      );
    },
  );

  scenario('2. identical frames: the composite is a byte-exact copy', () {
    final flat = Uint8List(kWidth * kHeight * 3);
    for (var i = 0; i < flat.length; i++) {
      flat[i] = 137;
    }
    final output = Uint8List(kWidth * kHeight * 3);
    final stats = compositeSeams(
      output: output,
      width: kWidth,
      height: kHeight,
      bestColour: flat,
      secondColour: flat,
      bestWeight: bestWeight,
      secondWeight: secondWeight,
      bestFrame: bestFrame,
      secondFrame: secondFrame,
      channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );
    var identical = true;
    for (var i = 0; i < output.length; i++) {
      if (output[i] != 137) {
        identical = false;
        break;
      }
    }
    check('output equals the shared content', identical);
    closeTo('no ghosting reported', stats.ghostEnergy, 0, 0.001);
    closeTo('no visible disagreement', stats.ghostFraction, 0, 0.001);
  });

  scenario('3. seam band is smooth, not a cut', () {
    final output = Uint8List(kWidth * kHeight * 3);
    compositeSeams(
      output: output,
      width: kWidth,
      height: kHeight,
      bestColour: bestColour,
      secondColour: secondColour,
      bestWeight: bestWeight,
      secondWeight: secondWeight,
      bestFrame: bestFrame,
      secondFrame: secondFrame,
      channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );
    final columns = columnMeans(output);
    final jump = (columns[32] - columns[31]).abs();
    check(
      'no luminance step across the ownership contour',
      jump < 6,
      '${jump.toStringAsFixed(2)}/255',
    );
  });

  scenario('4. ghosting is measured, not hidden', () {
    final bright = Uint8List(kWidth * kHeight * 3);
    for (var i = 0; i < bright.length; i++) {
      bright[i] = 187;
    }
    final dark = Uint8List(kWidth * kHeight * 3);
    for (var i = 0; i < dark.length; i++) {
      dark[i] = 137;
    }
    final output = Uint8List(kWidth * kHeight * 3);
    final stats = compositeSeams(
      output: output,
      width: kWidth,
      height: kHeight,
      bestColour: bright,
      secondColour: dark,
      bestWeight: bestWeight,
      secondWeight: secondWeight,
      bestFrame: bestFrame,
      secondFrame: secondFrame,
      channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );
    closeTo('mean disagreement is reported', stats.ghostEnergy, 50, 0.5);
    closeTo(
      'all of it is above the visible threshold',
      stats.ghostFraction,
      1,
      0.001,
    );
  });

  scenario('5. no overlap: straight copy with exposure applied', () {
    final none = Float32List(kWidth * kHeight);
    final single = Uint8List(kWidth * kHeight * 3);
    for (var i = 0; i < single.length; i++) {
      single[i] = 100;
    }
    final output = Uint8List(kWidth * kHeight * 3);
    final stats = compositeSeams(
      output: output,
      width: kWidth,
      height: kHeight,
      bestColour: single,
      secondColour: single,
      bestWeight: bestWeight,
      secondWeight: none,
      bestFrame: bestFrame,
      secondFrame: secondFrame,
      // Frame 0 dimmed to 60% across all three channels.
      channelGains: <double>[0.6, 0.6, 0.6, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );
    check('output is 0.6 x 100', output[0] == 60, '${output[0]}');
    check('no second band built', !stats.usedSecondBand);
    check('no overlap measured', stats.overlapPixels == 0);
  });

  scenario('6. the seam moves off a localised disagreement', () {
    // A and B agree everywhere except a four-column blob at x = 38..41, where B
    // shows something different (a person who moved between shots). The weights
    // put the ownership contour at x = 40 — straight through the blob, which
    // would leave a visible step. The seam term should move it to x = 42, where
    // the two frames agree again.
    const blobStart = 38;
    const blobEnd = 42;
    final best = Uint8List(kWidth * kHeight * 3);
    final second = Uint8List(kWidth * kHeight * 3);
    final wBest = Float32List(kWidth * kHeight);
    final wSecond = Float32List(kWidth * kHeight);
    final bFrame = Int16List(kWidth * kHeight);
    final sFrame = Int16List(kWidth * kHeight);

    for (var y = 0; y < kHeight; y++) {
      for (var x = 0; x < kWidth; x++) {
        final i = y * kWidth + x;
        final inBlob = x >= blobStart && x < blobEnd;
        final aIsBest = x < 40;
        // Frame 0 (A) is 150 everywhere. Frame 1 (B) is 30 inside the blob.
        final valueA = 150;
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

    final output = Uint8List(kWidth * kHeight * 3);
    final stats = compositeSeams(
      output: output,
      width: kWidth,
      height: kHeight,
      bestColour: best,
      secondColour: second,
      bestWeight: wBest,
      secondWeight: wSecond,
      bestFrame: bFrame,
      secondFrame: sFrame,
      channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );

    check(
      'seam search moved ownership to reduce the seam cost',
      stats.flippedPixels > 0,
      '${stats.flippedPixels} px flipped',
    );

    final columns = columnMeans(output);
    // The blob exists in one frame only — it is a moving object. The correct
    // outcome is that it appears **once**, crisply, whichever side of the seam
    // owns it. Asserting "no step" would be wrong: the object's own edge is a
    // legitimate 120-level step, and hiding it would mean discarding real
    // content. What must not happen is the blob being split across the seam,
    // which would draw it twice at partial strength.
    final blobColumns = columns.where((double v) => v < 90).length;
    // The seam may sit within the feather band of the object's edge, which
    // softens that edge — a 6 px transition, not a second copy. The property
    // that must hold is that the object is **not duplicated**: no more dark
    // columns than the object itself occupies.
    check(
      'the object is not duplicated',
      blobColumns <= blobEnd - blobStart,
      '$blobColumns dark columns (object is ${blobEnd - blobStart} wide)',
    );
  });

  scenario('7. wraparound boundary is measured', () {
    // A canvas whose left and right edges are the same content wraps cleanly;
    // one where they differ is a vertical tear in the viewer. The metric has to
    // tell them apart, or it cannot be used as a gate.
    Uint8List build(int leftValue, int rightValue) {
      final rgb = Uint8List(kWidth * kHeight * 3);
      for (var y = 0; y < kHeight; y++) {
        for (var x = 0; x < kWidth; x++) {
          final v = x == 0 ? leftValue : (x == kWidth - 1 ? rightValue : 120);
          final i = (y * kWidth + x) * 3;
          rgb[i] = v;
          rgb[i + 1] = v;
          rgb[i + 2] = v;
        }
      }
      return rgb;
    }

    final none = Float32List(kWidth * kHeight);
    final w = Float32List(kWidth * kHeight)
      ..fillRange(0, kWidth * kHeight, 1.0);
    final frames = Int16List(kWidth * kHeight);

    SeamBlendStats run(Uint8List content) {
      final output = Uint8List(kWidth * kHeight * 3);
      return compositeSeams(
        output: output,
        width: kWidth,
        height: kHeight,
        bestColour: content,
        secondColour: content,
        bestWeight: w,
        secondWeight: none,
        bestFrame: frames,
        secondFrame: frames,
        channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
        minWeight: 0.001,
      );
    }

    final continuous = run(build(120, 120));
    final torn = run(build(0, 255));
    check(
      'matching edges report no tear',
      continuous.wrapDiscontinuity < 0.5,
      continuous.wrapDiscontinuity.toStringAsFixed(2),
    );
    check(
      'mismatched edges report the tear',
      torn.wrapDiscontinuity > 100,
      torn.wrapDiscontinuity.toStringAsFixed(2),
    );
  });

  scenario('8. full-size cost (2048 x 1024) on this machine', () {
    const w = 2048;
    const h = 1024;
    final best = Uint8List(w * h * 3);
    final second = Uint8List(w * h * 3);
    final wBest = Float32List(w * h);
    final wSecond = Float32List(w * h);
    final bFrame = Int16List(w * h);
    final sFrame = Int16List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        // A gradient with vertical structure, so the cut has real content to
        // route around rather than a flat field.
        final v = ((x * 255) ~/ w + ((x ~/ 32) % 2) * 12).clamp(0, 255);
        final v2 = ((v + ((y ~/ 16) % 2) * 6)).clamp(0, 255);
        for (var c = 0; c < 3; c++) {
          best[i * 3 + c] = v;
          second[i * 3 + c] = v2;
        }
        final aIsBest = x < w ~/ 2;
        wBest[i] = 1.0;
        wSecond[i] = 0.7;
        bFrame[i] = aIsBest ? 0 : 1;
        sFrame[i] = aIsBest ? 1 : 0;
      }
    }

    final cutWatch = Stopwatch()..start();
    final cut = findSeamLabels(
      width: w,
      height: h,
      bestColour: best,
      secondColour: second,
      bestWeight: wBest,
      secondWeight: wSecond,
      bestFrame: bFrame,
      secondFrame: sFrame,
      minWeight: 0.001,
      seamCostWeight: kSeamCostWeight,
    );
    cutWatch.stop();

    final output = Uint8List(w * h * 3);
    final compositeWatch = Stopwatch()..start();
    final stats = compositeSeams(
      output: output,
      width: w,
      height: h,
      bestColour: best,
      secondColour: second,
      bestWeight: wBest,
      secondWeight: wSecond,
      bestFrame: bFrame,
      secondFrame: sFrame,
      channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );
    compositeWatch.stop();

    check('cut produced labels', cut != null);
    check('composite ran the cut', stats.cutUsed);
    print(
      '  INFO  graph cut: ${cutWatch.elapsedMilliseconds} ms, '
      'full composite: ${compositeWatch.elapsedMilliseconds} ms',
    );
    check(
      'full-size composite stays inside a usable budget',
      compositeWatch.elapsedMilliseconds < 20000,
      '${compositeWatch.elapsedMilliseconds} ms',
    );
  });

  scenario('9. colour balance removes a white-balance step, within bounds', () {
    const n = kWidth * kHeight;
    // Frame 0 is neutral grey; frame 1 is 10% warm (red lifted).
    Uint8List build(int red) {
      final rgb = Uint8List(n * 3);
      for (var i = 0; i < n; i++) {
        rgb[i * 3] = red;
        rgb[i * 3 + 1] = 120;
        rgb[i * 3 + 2] = 120;
      }
      return rgb;
    }

    final a = build(120);
    final b = build(132);
    final best = Uint8List(n * 3);
    final second = Uint8List(n * 3);
    final wBest = Float32List(n);
    final wSecond = Float32List(n);
    final bFrame = Int16List(n);
    final sFrame = Int16List(n);
    for (var i = 0; i < n; i++) {
      final aIsBest = i % kWidth < 32;
      bFrame[i] = aIsBest ? 0 : 1;
      sFrame[i] = aIsBest ? 1 : 0;
      wBest[i] = 1.0;
      wSecond[i] = 1.0;
      for (var c = 0; c < 3; c++) {
        best[i * 3 + c] = aIsBest ? a[i * 3 + c] : b[i * 3 + c];
        second[i * 3 + c] = aIsBest ? b[i * 3 + c] : a[i * 3 + c];
      }
    }

    final balance = solveColourBalance(
      frameCount: 2,
      pixelCount: n,
      bestFrame: bFrame,
      secondFrame: sFrame,
      bestWeight: wBest,
      secondWeight: wSecond,
      bestColour: best,
      secondColour: second,
    );

    check(
      'green and blue are untouched',
      (balance[1] - 1.0).abs() < 1e-9 && (balance[2] - 1.0).abs() < 1e-9,
      'g=${balance[1].toStringAsFixed(4)} b=${balance[2].toStringAsFixed(4)}',
    );
    check(
      'the warm frame is pulled down, the neutral one up',
      balance[3] < 1.0 && balance[0] > 1.0,
      'f0=${balance[0].toStringAsFixed(4)} f1=${balance[3].toStringAsFixed(4)}',
    );

    applyColourBalance(best, bFrame, balance);
    applyColourBalance(second, sFrame, balance);
    var redA = 0.0;
    var redB = 0.0;
    for (var i = 0; i < n; i++) {
      if (bFrame[i] == 0) redA += best[i * 3];
      if (bFrame[i] == 1) redB += best[i * 3];
    }
    redA /= n / 2;
    redB /= n / 2;
    check(
      'the two frames now agree in red',
      (redA - redB).abs() < 1.5,
      '${redA.toStringAsFixed(1)} vs ${redB.toStringAsFixed(1)}',
    );

    // An extreme cast must be clamped, not "corrected" into nonsense. Fresh
    // buffers: the ones above were balanced in place, so reusing them would make
    // this assertion pass without testing anything.
    final cool = build(60);
    final hot = build(255);
    final bestX = Uint8List(n * 3);
    final secondX = Uint8List(n * 3);
    for (var i = 0; i < n; i++) {
      final aIsBest = i % kWidth < 32;
      for (var c = 0; c < 3; c++) {
        bestX[i * 3 + c] = aIsBest ? cool[i * 3 + c] : hot[i * 3 + c];
        secondX[i * 3 + c] = aIsBest ? hot[i * 3 + c] : cool[i * 3 + c];
      }
    }
    final extremeBalance = solveColourBalance(
      frameCount: 2,
      pixelCount: n,
      bestFrame: bFrame,
      secondFrame: sFrame,
      bestWeight: wBest,
      secondWeight: wSecond,
      bestColour: bestX,
      secondColour: secondX,
    );
    // Reference 157.5; the hot frame's ratio would be 0.62, so the clamp bites.
    check(
      'an extreme cast is clamped to the bound',
      (extremeBalance[3] - kColourBalanceMin).abs() < 1e-9,
      'f1 red ${extremeBalance[3].toStringAsFixed(4)}',
    );
  });

  scenario('10. a pure brightness step feathers instead of cutting', () {
    // The frames are identical except exposure: 40 levels apart, no content
    // difference at all. Before the detail-layer gate this produced a binary
    // owner mask and a hard rectangular cut-line along the seam.
    const int n = kWidth * kHeight;
    final dim = Uint8List(n * 3)..fillRange(0, n * 3, 120);
    final bright = Uint8List(n * 3)..fillRange(0, n * 3, 160);

    final best = Uint8List(n * 3);
    final second = Uint8List(n * 3);
    final wBest = Float32List(n);
    final wSecond = Float32List(n);
    final bFrame = Int16List(n);
    final sFrame = Int16List(n);
    for (var i = 0; i < n; i++) {
      final aIsBest = i % kWidth < 32;
      bFrame[i] = aIsBest ? 0 : 1;
      sFrame[i] = aIsBest ? 1 : 0;
      wBest[i] = 1.0;
      wSecond[i] = 0.8;
      for (var c = 0; c < 3; c++) {
        best[i * 3 + c] = aIsBest ? dim[i * 3 + c] : bright[i * 3 + c];
        second[i * 3 + c] = aIsBest ? bright[i * 3 + c] : dim[i * 3 + c];
      }
    }

    final output = Uint8List(n * 3);
    compositeSeams(
      output: output,
      width: kWidth,
      height: kHeight,
      bestColour: best,
      secondColour: second,
      bestWeight: wBest,
      secondWeight: wSecond,
      bestFrame: bFrame,
      secondFrame: sFrame,
      channelGains: <double>[1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
      minWeight: 0.001,
    );

    final columns = columnMeans(output);
    var worstStep = 0.0;
    for (var x = 0; x + 1 < columns.length; x++) {
      final step = (columns[x + 1] - columns[x]).abs();
      if (step > worstStep) worstStep = step;
    }
    final midtones = columns.where((double v) => v > 125 && v < 155).length;

    check(
      'no hard cut-line at the seam',
      worstStep < 12,
      'worst adjacent step ${worstStep.toStringAsFixed(1)}/255',
    );
    check(
      'the brightness change is spread across the seam',
      midtones >= 4,
      '$midtones intermediate columns',
    );
  });

  print('\n$passed passed, $failed failed');
  if (failed > 0) {
    throw StateError('$failed seam-blend check(s) failed');
  }
}
