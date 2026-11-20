import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/seam_blend.dart';

// SITEWISE_SEAM_POSE_INTEGRITY_20261121: the seam must never assign a pixel
// to a third photograph merely because its best/second rank changes mid-row.
void main() {
  test('row seam refinement never invents a third-frame ownership', () {
    const width = 28;
    const height = 4;
    final length = width * height;
    final bestFrame = Int16List(length);
    final secondFrame = Int16List(length);
    final bestWeight = Float32List(length);
    final secondWeight = Float32List(length);
    final bestColour = Uint8List(length * 3);
    final secondColour = Uint8List(length * 3);
    final labels = Uint8List(length);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        bestFrame[i] = 1;
        // The candidate rank changes at x=13: photograph 2 disappears,
        // while an unrelated photograph 3 becomes the runner-up.
        secondFrame[i] = x < 13 ? 2 : 3;
        bestWeight[i] = 0.9;
        secondWeight[i] = 0.84;
        labels[i] = x >= 7 && x < 13 ? 1 : 0;
        for (var channel = 0; channel < 3; channel++) {
          bestColour[i * 3 + channel] = 60;
          secondColour[i * 3 + channel] =
              (x >= 7 && x <= 12) ? 230 : 60;
        }
      }
    }

    final before = Uint8List.fromList(labels);
    final moved = refineSeams(
      label: labels,
      width: width,
      height: height,
      bestWeight: bestWeight,
      secondWeight: secondWeight,
      bestColour: bestColour,
      secondColour: secondColour,
      bestFrame: bestFrame,
      secondFrame: secondFrame,
      minWeight: 0.001,
    );
    expect(moved, greaterThanOrEqualTo(0));
    for (var y = 0; y < height; y++) {
      for (var x = 13; x < width; x++) {
        final i = y * width + x;
        // No boundary from frames 1/2 may leak into the third photograph.
        expect(labels[i], before[i], reason: 'third-frame rank at $x,$y');
      }
    }
  });

  test('seam refinement respects a missing second contributor', () {
    const width = 20;
    const height = 3;
    final bestFrame = Int16List(width * height);
    final secondFrame = Int16List(width * height);
    final bestWeight = Float32List(width * height);
    final secondWeight = Float32List(width * height);
    final bestColour = Uint8List(width * height * 3);
    final secondColour = Uint8List(width * height * 3);
    final labels = Uint8List(width * height);
    for (var i = 0; i < width * height; i++) {
      final x = i % width;
      bestFrame[i] = 1;
      secondFrame[i] = x >= 10 ? -1 : 2;
      bestWeight[i] = 0.9;
      secondWeight[i] = x >= 10 ? 0 : 0.8;
      labels[i] = x >= 4 && x < 10 ? 1 : 0;
    }
    refineSeams(
      label: labels,
      width: width,
      height: height,
      bestWeight: bestWeight,
      secondWeight: secondWeight,
      bestColour: bestColour,
      secondColour: secondColour,
      bestFrame: bestFrame,
      secondFrame: secondFrame,
      minWeight: 0.001,
    );
    for (var i = 0; i < labels.length; i++) {
      if (secondFrame[i] < 0) expect(labels[i], 0);
    }
  });
}
