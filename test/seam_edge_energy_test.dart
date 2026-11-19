import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/graph_cut_seams.dart';

void main() {
  test('6x Sobel penalty sends seams toward flat surface', () {
    const width = 24;
    const height = 12;
    final a = Uint8List(width * height * 3);
    final b = Uint8List(width * height * 3);
    final fa = Int16List(width * height)..fillRange(0, width * height, 1);
    final fb = Int16List(width * height)..fillRange(0, width * height, 2);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final v = x < 12 ? 220 : 30;
        final i = (y * width + x) * 3;
        for (var c = 0; c < 3; c++) {
          a[i + c] = v;
          b[i + c] = v; // identical photographs; only Sobel distinguishes edge
        }
      }
    }
    double cost(int x) => seamPixelCostAt(
      bestColour: a, secondColour: b,
      bestFrame: fa, secondFrame: fb,
      width: width, height: height,
      index: 6 * width + x,
    );
    expect(cost(11), greaterThan(cost(3) * 10 + 1));
    expect(cost(12), greaterThan(cost(3) * 10 + 1));
    expect(cost(3), closeTo(0.0, 0.01));
  });
}
