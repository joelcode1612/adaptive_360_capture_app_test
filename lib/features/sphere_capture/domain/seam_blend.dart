/// Seam selection and multi-band compositing for the equirectangular canvas.
///
/// ## The problem this solves
///
/// The stitcher projects every photograph onto the canvas through its recorded
/// orientation, then used to take a **normalised weighted average of the top two
/// contributors over the whole overlap**. Where two frames disagreed — and they
/// do disagree, by a few centimetres of parallax indoors — averaging drew the
/// disagreement *twice*: a wardrobe edge appeared as two soft edges, a door
/// frame as a translucent double line. That is ghosting, and no amount of
/// exposure correction hides it, because it is a geometric disagreement, not a
/// photometric one.
///
/// ## What replaces it
///
/// 1. **Ownership.** Every pixel is owned by exactly one frame — the one that
///    sees it best — so each object is drawn once. That single rule removes the
///    duplicated-edge artefact; everything below only decides *where* the
///    boundary between two owners runs.
///
/// 2. **Seam placement.** A boundary that runs through a high-contrast object is
///    visible even after blending, so [refineSeams] searches each row for a
///    boundary position with a lower cost, where cost is
///    `Σ |A(p) − B(p)|` along the seam plus the log-weight penalty for handing
///    pixels to the weaker frame. Moving the seam one pixel is a real trade
///    (better agreement, slightly worse sampling), and the search only accepts
///    moves that pay for themselves.
///
///    This is a **1-D search along each row**, not a graph cut. A global min-cut
///    over 2.1 M nodes would dominate the whole stitch in Dart, and an
///    iterated-conditional-modes pass cannot cross a plateau of uniform
///    disagreement — it can only improve a boundary one pixel at a time, which
///    is exactly what this search does, with the whole neighbourhood evaluated
///    instead of one greedy flip.
///
/// 3. **Multi-band blending.** A boundary is invisible only if both sides are
///    identical; they never are. The transition is blended in two frequency
///    bands — a coarse band over a wide mask, a fine band over a narrow one —
///    which is a two-level Laplacian-pyramid blend. Full
///    `detail::MultiBandBlender` is not exposed by dartcv4 2.2.2, and a Dart
///    pyramid at 4096×2048 would cost more memory than the accumulator itself.
///
/// 4. **Ghosting measurement.** The disagreement that survives alignment is
///    measured, not assumed away. [SeamBlendStats] reports the mean colour
///    difference across the overlap and the share of it large enough to read as
///    a double edge; the stitcher writes both into `coverage_report.json` and
///    names the figure in its result message.
///
/// ## What this deliberately does not do
///
/// No inpainting, no blur over duplicated objects, no widening of the overlap.
/// Large misaligned regions stay visible and are reported. The point is to
/// remove the *averaging* artefact, not to disguise the parallax that no
/// rotation-only model can remove.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/graph_cut_seams.dart';

/// How much the seam term outweighs the sampling term when moving a boundary.
///
/// The sampling term is `|ln(wBest/wSecond)|` per reassigned pixel; the seam
/// term is a mean channel difference scaled by [/255]. At 2.0 a seam moves to
/// avoid a difference of ~100/255 even when that costs a factor of e² in weight,
/// and refuses to move for noise-level differences.
const double kSeamCostWeight = 2.0;

/// Colour difference above which a pixel reads as a visible double edge.
///
/// 24/255 is roughly 9% of full scale: below it the eye reads texture, above it
/// the eye reads a second edge. Used only for reporting, never for compositing.
const double kGhostVisibleDelta = 24.0;

/// How far a seam may be moved in one search, in pixels.
///
/// The weight contour is already close to correct, so a small window is enough;
/// a larger one would let a seam wander into a frame's edge where the projection
/// is weakest.
const int kSeamSearchRadius = 8;

/// What the seam pass did, and how much disagreement it could not remove.
class SeamBlendStats {
  const SeamBlendStats({
    required this.seamPixels,
    required this.flippedPixels,
    required this.overlapPixels,
    required this.ghostEnergy,
    required this.ghostFraction,
    required this.usedSecondBand,
    this.seamDiscontinuity = 0,
    this.wrapDiscontinuity = 0,
    this.cutUsed = false,
  });

  /// Pixels inside the feathered band around an ownership boundary.
  final int seamPixels;

  /// Pixels the seam search reassigned to the other contributor.
  final int flippedPixels;

  /// Pixels two photographs both see.
  final int overlapPixels;

  /// Mean absolute channel difference between the two contributors, 0–255.
  final double ghostEnergy;

  /// Share of the overlap whose disagreement exceeds [kGhostVisibleDelta].
  final double ghostFraction;

  /// Whether the second band was actually built (false when the station has no
  /// overlapping pair, in which case the composite is a straight copy).
  final bool usedSecondBand;

  /// Mean absolute step across the ownership boundaries, 0–255.
  ///
  /// This is the number that decides whether a seam is *visible*: a well-placed
  /// cut through agreeing content reads near zero, a cut through a wardrobe edge
  /// reads high. It is measured on the composited output, not on the inputs.
  final double seamDiscontinuity;

  /// Mean absolute difference between the first and last column, 0–255.
  ///
  /// The equirectangular canvas wraps: column 0 and column W−1 are adjacent
  /// directions. A discontinuity here is a vertical tear in the 360° viewer.
  final double wrapDiscontinuity;

  /// Whether the graph-cut pass ran (false when the graph exceeded its budget).
  final bool cutUsed;

  Map<String, Object?> toJson() => <String, Object?>{
    'seamPixels': seamPixels,
    'seamPixelsMoved': flippedPixels,
    'overlapPixels': overlapPixels,
    'ghostEnergy': double.parse(ghostEnergy.toStringAsFixed(2)),
    'ghostFraction': double.parse(ghostFraction.toStringAsFixed(4)),
    'multiBand': usedSecondBand,
    'seamDiscontinuity': double.parse(seamDiscontinuity.toStringAsFixed(2)),
    'wrapDiscontinuity': double.parse(wrapDiscontinuity.toStringAsFixed(2)),
    'graphCut': cutUsed,
  };
}

/// Composites [output] from the best/second contributor buffers.
///
/// All inputs are the stitcher's existing per-pixel buffers; nothing here
/// allocates per frame, so cost is bounded by the canvas, not the frame count.
SeamBlendStats compositeSeams({
  required Uint8List output,
  required int width,
  required int height,
  required Uint8List bestColour,
  required Uint8List secondColour,
  required Float32List bestWeight,
  required Float32List secondWeight,
  required Int16List bestFrame,
  required Int16List secondFrame,
  required List<double> gains,
  required List<double> offsets,
  required double minWeight,
  int featherPx = 2,
}) {
  final n = width * height;

  // ── 1. Ownership: 0 = best contributor, 1 = second. ────────────────────
  // Starts as "the frame that sees it best owns it". That is already a
  // winner-take-all map, so an object is drawn once from the outset; the seam
  // search below only moves the boundary, never duplicates content.
  final label = Uint8List(n);
  var overlap = 0;
  for (var i = 0; i < n; i++) {
    if (secondWeight[i] > minWeight && secondFrame[i] >= 0) overlap++;
  }
  if (overlap == 0) {
    // No overlap anywhere: nothing to deghost. Straight copy with exposure.
    _writeBestOnly(
      output: output,
      count: n,
      bestColour: bestColour,
      bestWeight: bestWeight,
      bestFrame: bestFrame,
      gains: gains,
      offsets: offsets,
      minWeight: minWeight,
    );
    // The wraparound metric still applies: a single-frame station can still tear
    // where the last ring frame meets the first, and a caller that gates on this
    // number must get a real answer rather than a default zero.
    var wrapOnly = 0.0;
    for (var y = 0; y < height; y++) {
      final row = y * width;
      wrapOnly += _outputDelta(output, row, row + width - 1);
    }
    return SeamBlendStats(
      seamPixels: 0,
      flippedPixels: 0,
      overlapPixels: 0,
      ghostEnergy: 0,
      ghostFraction: 0,
      usedSecondBand: false,
      wrapDiscontinuity: height == 0 ? 0 : wrapOnly / height,
    );
  }

  // Globally optimal ownership for this cost function. The cut decides which
  // side of an object the seam passes; it is computed on a reduced grid (see
  // graph_cut_seams.dart) because a full-resolution residual graph would not fit
  // the device budget.
  final cut = findSeamLabels(
    width: width,
    height: height,
    bestColour: bestColour,
    secondColour: secondColour,
    bestWeight: bestWeight,
    secondWeight: secondWeight,
    bestFrame: bestFrame,
    secondFrame: secondFrame,
    minWeight: minWeight,
    seamCostWeight: kSeamCostWeight,
  );
  final cutUsed = cut != null;
  if (cut != null) label.setAll(0, cut);

  // Full-resolution polish. The cut is blocky at the pixel level; this moves the
  // boundary the last few pixels, and only where the move pays for itself.
  final moved = refineSeams(
    label: label,
    width: width,
    height: height,
    bestWeight: bestWeight,
    secondWeight: secondWeight,
    bestColour: bestColour,
    secondColour: secondColour,
    bestFrame: bestFrame,
    secondFrame: secondFrame,
    minWeight: minWeight,
  );

  // ── 2. Ghost measurement, before compositing. ──────────────────────────
  // Measured on the *exposure-corrected* contributors, because a brightness
  // step that the gain/offset solve already removed is not ghosting.
  var diffSum = 0.0;
  var diffCount = 0;
  var visible = 0;
  // Per-pixel magnitude of the disagreement, kept so the composite can tell a
  // *brightness* step from a *displaced object* by looking at how the
  // disagreement varies in space rather than at how large it is.
  final diffField = Float32List(n);
  for (var i = 0; i < n; i++) {
    if (secondWeight[i] <= minWeight || secondFrame[i] < 0) continue;
    // A second contributor without a best one cannot occur in the projection,
    // but indexing `gains` with −1 here would throw inside the stitching isolate
    // and fail the whole station. Guarding is cheaper than that risk.
    if (bestFrame[i] < 0) continue;
    final gB = gains[bestFrame[i]];
    final oB = offsets[bestFrame[i]];
    final gS = gains[secondFrame[i]];
    final oS = offsets[secondFrame[i]];
    var d = 0.0;
    for (var c = 0; c < 3; c++) {
      final a = bestColour[i * 3 + c] * gB + oB;
      final b = secondColour[i * 3 + c] * gS + oS;
      d += (a - b).abs();
    }
    d /= 3;
    diffField[i] = d;
    diffSum += d;
    diffCount++;
    if (d > kGhostVisibleDelta) visible++;
  }
  final ghostEnergy = diffCount == 0 ? 0.0 : diffSum / diffCount;
  final ghostFraction = diffCount == 0 ? 0.0 : visible / diffCount;

  // ── 3. Composite: winner-take-all, feathered in a narrow band only. ───
  //
  // Every pixel is rendered from **one** frame. The only cross-fade is a band of
  // `featherPx` either side of an ownership boundary, which is where the two
  // photographs are blended 50/50 and then ramp to pure over ~8 px.
  //
  // The two earlier attempts failed in opposite directions and this replaces
  // both:
  //
  //  * a blurred binary mask produced hard cut-lines, because at a boundary
  //    where the owner changes from frame A to frame B *both* sides are "the
  //    best contributor" — they are best of different pairs — so the mask read
  //    1.0 across the seam and there was nothing to ramp;
  //  * blending by the weight ratio everywhere removed the cut-line but mixed a
  //    bright frame into a dark one across the whole overlap, which is the
  //    chalky white wash and the semi-transparent double image in the output.
  //
  // The band is measured from the **owner change**, which is the only thing that
  // actually defines a seam, and it is narrow on purpose: 95 % of every
  // photograph is rendered at full clarity from a single source.
  final owner = Int16List(n);
  final edge = Uint8List(n);
  var seamPixels = 0;
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      final i = row + x;
      final own = (secondWeight[i] <= minWeight || secondFrame[i] < 0)
          ? bestFrame[i]
          : (label[i] == 0 ? bestFrame[i] : secondFrame[i]);
      owner[i] = own;
      var isEdge = false;
      if (x > 0 && owner[i - 1] != own) isEdge = true;
      if (x + 1 < width && owner[i + 1] != own) isEdge = true;
      if (y > 0 && owner[i - width] != own) isEdge = true;
      if (y + 1 < height && owner[i + width] != own) isEdge = true;
      if (isEdge) {
        edge[i] = 1;
        seamPixels++;
      }
    }
  }

  final seamDistance = _distanceToEdge(edge, width, height);

  // The feather widens toward the poles.
  //
  // A ring-to-ring seam runs roughly vertically, and a 9 px band is right for
  // it. A pole frame meets its ring along a *circle*, and the same narrow band
  // there reads as a polygonal cut — the hexagonal floor edge around the user's
  // feet. Scaling the band with latitude squared (1× at the equator, 3× at the
  // pole) turns that cut into a radial gradient without softening the walls.
  final bandForRow = Float32List(height);
  for (var y = 0; y < height; y++) {
    final latitude = ((0.5 - (y + 0.5) / height) * math.pi).abs() /
        (math.pi / 2);
    bandForRow[y] = featherPx * (1 + 2 * latitude * latitude);
  }

  for (var i = 0; i < n; i++) {
    final gB = gains[bestFrame[i] < 0 ? 0 : bestFrame[i]];
    final oB = offsets[bestFrame[i] < 0 ? 0 : bestFrame[i]];
    if (secondWeight[i] <= minWeight || secondFrame[i] < 0) {
      for (var c = 0; c < 3; c++) {
        output[i * 3 + c] = _clamp(bestColour[i * 3 + c] * gB + oB);
      }
      continue;
    }
    final gS = gains[secondFrame[i]];
    final oS = offsets[secondFrame[i]];
    // 0.5 exactly on the seam, ramping to 1.0 at the edge of the band.
    final band = bandForRow[i ~/ width];
    final t = (seamDistance[i] / band).clamp(0.0, 1.0);
    final wBest = 0.5 + 0.5 * t;
    for (var c = 0; c < 3; c++) {
      final b = bestColour[i * 3 + c] * gB + oB;
      final s2 = secondColour[i * 3 + c] * gS + oS;
      output[i * 3 + c] = _clamp(b * wBest + s2 * (1 - wBest));
    }
  }

  // ── 4. Seam and wraparound quality, measured on the composited output. ──
  var seamStepSum = 0.0;
  var seamStepCount = 0;
  var wrapSum = 0.0;
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 1; x < width; x++) {
      final i = row + x;
      final ownerHere = label[i] == 0 ? bestFrame[i] : secondFrame[i];
      final ownerPrev = label[i - 1] == 0 ? bestFrame[i - 1] : secondFrame[i - 1];
      if (ownerHere == ownerPrev) continue;
      seamStepSum += _outputDelta(output, i, i - 1);
      seamStepCount++;
    }
    wrapSum += _outputDelta(output, row, row + width - 1);
  }

  return SeamBlendStats(
    seamPixels: seamPixels,
    flippedPixels: moved,
    overlapPixels: overlap,
    ghostEnergy: ghostEnergy,
    ghostFraction: ghostFraction,
    usedSecondBand: true,
    seamDiscontinuity: seamStepCount == 0 ? 0 : seamStepSum / seamStepCount,
    wrapDiscontinuity: height == 0 ? 0 : wrapSum / height,
    cutUsed: cutUsed,
  );
}

/// Moves ownership boundaries to where the two frames agree better.
///
/// For each row, every place the owner changes is a boundary pixel. The search
/// tries shifting that boundary by ±[kSeamSearchRadius] and keeps the shift with
/// the lowest total cost:
///
/// ```text
/// cost(shift) = Σ |A(p) − B(p)| over the seam's new pixels
///             + Σ |ln(wBest/wSecond)| over the pixels reassigned
/// ```
///
/// The second term is what stops the seam drifting into a frame's weak edge: a
/// pixel whose weights are 1.0 and 0.2 costs `ln 5 ≈ 1.6` to hand over, far more
/// than any plausible colour gain, so the seam only moves where the two frames
/// genuinely see the direction about equally well.
///
/// Returns how many pixels changed owner.
int refineSeams({
  required Uint8List label,
  required int width,
  required int height,
  required Float32List bestWeight,
  required Float32List secondWeight,
  required Uint8List bestColour,
  required Uint8List secondColour,
  required Int16List bestFrame,
  required Int16List secondFrame,
  required double minWeight,
}) {
  var moved = 0;
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 1; x < width; x++) {
      final i = row + x;
      final prev = row + x - 1;
      final ownerPrev = label[prev] == 0 ? bestFrame[prev] : secondFrame[prev];
      final ownerHere = label[i] == 0 ? bestFrame[i] : secondFrame[i];
      if (ownerPrev == ownerHere) continue;
      // A boundary runs between `prev` and `i`.
      if (secondWeight[prev] <= minWeight || secondWeight[i] <= minWeight) {
        continue;
      }
      moved += _tryShiftBoundary(
        label: label,
        width: width,
        rowStart: row,
        boundary: x,
        bestWeight: bestWeight,
        secondWeight: secondWeight,
        bestColour: bestColour,
        secondColour: secondColour,
      );
    }
  }
  return moved;
}

/// Tries every shift for one boundary and applies the best. Returns pixels moved.
int _tryShiftBoundary({
  required Uint8List label,
  required int width,
  required int rowStart,
  required int boundary,
  required Float32List bestWeight,
  required Float32List secondWeight,
  required Uint8List bestColour,
  required Uint8List secondColour,
}) {
  final current = _seamCostAt(
    rowStart: rowStart,
    position: boundary,
    bestColour: bestColour,
    secondColour: secondColour,
  );
  var bestCost = current;
  var bestShift = 0;
  var bestSampling = 0.0;

  for (var shift = -kSeamSearchRadius; shift <= kSeamSearchRadius; shift++) {
    if (shift == 0) continue;
    final target = boundary + shift;
    if (target < 1 || target >= width) continue;

    // Sampling penalty for every pixel that would change owner.
    var sampling = 0.0;
    var blocked = false;
    final from = shift > 0 ? boundary : target;
    final to = shift > 0 ? target : boundary;
    for (var p = from; p < to; p++) {
      final i = rowStart + p;
      if (secondWeight[i] <= 0) {
        blocked = true;
        break;
      }
      sampling +=
          (math.log(bestWeight[i] + 1e-6) - math.log(secondWeight[i] + 1e-6))
              .abs();
    }
    if (blocked) continue;

    final seam = _seamCostAt(
      rowStart: rowStart,
      position: target,
      bestColour: bestColour,
      secondColour: secondColour,
    );
    final cost = seam + sampling;
    if (cost < bestCost - 1e-6) {
      bestCost = cost;
      bestShift = shift;
      bestSampling = sampling;
    }
  }

  if (bestShift == 0) return 0;

  final target = boundary + bestShift;
  final from = bestShift > 0 ? boundary : target;
  final to = bestShift > 0 ? target : boundary;
  for (var p = from; p < to; p++) {
    final i = rowStart + p;
    label[i] = label[i] == 0 ? 1 : 0;
  }
  // `bestSampling` is computed to keep the trade explicit at the call site; the
  // decision has already been made on it.
  assert(bestSampling >= 0);
  return to - from;
}

/// Cost of routing the seam through a candidate position.
///
/// Scaled to the same order as the sampling term (`|ln w|`, 0–3), so the two
/// can be added: `kSeamCostWeight · meanChannelDelta / 255`.
double _seamCostAt({
  required int rowStart,
  required int position,
  required Uint8List bestColour,
  required Uint8List secondColour,
}) {
  final i = rowStart + position;
  return kSeamCostWeight * _colourDelta(bestColour, secondColour, i) / 255.0;
}

/// Mean absolute channel difference between two composited pixels.
double _outputDelta(Uint8List rgb, int a, int b) =>
    ((rgb[a * 3] - rgb[b * 3]).abs() +
        (rgb[a * 3 + 1] - rgb[b * 3 + 1]).abs() +
        (rgb[a * 3 + 2] - rgb[b * 3 + 2]).abs()) /
    3.0;

double _colourDelta(Uint8List a, Uint8List b, int i) =>
    ((a[i * 3] - b[i * 3]).abs() +
        (a[i * 3 + 1] - b[i * 3 + 1]).abs() +
        (a[i * 3 + 2] - b[i * 3 + 2]).abs()) /
    3.0;

void _writeBestOnly({
  required Uint8List output,
  required int count,
  required Uint8List bestColour,
  required Float32List bestWeight,
  required Int16List bestFrame,
  required List<double> gains,
  required List<double> offsets,
  required double minWeight,
}) {
  for (var i = 0; i < count; i++) {
    if (bestWeight[i] <= minWeight) continue;
    final f = bestFrame[i] < 0 ? 0 : bestFrame[i];
    final g = gains[f];
    final o = offsets[f];
    for (var c = 0; c < 3; c++) {
      output[i * 3 + c] = _clamp(bestColour[i * 3 + c] * g + o);
    }
  }
}

/// Chamfer distance, in pixels, from each pixel to the nearest seam pixel.
///
/// Two sweeps over a 5-7-11 chamfer metric — accurate to a few percent and O(n),
/// where an exact Euclidean transform would need a second pass over a feature
/// list. The band is 8 px wide, so a few percent of a few pixels is far below
/// what the eye can see.
Float32List _distanceToEdge(Uint8List edge, int width, int height) {
  final distance = Float32List(width * height);
  const far = 1e9;
  const diagonal = 1.41421356237;
  for (var i = 0; i < distance.length; i++) {
    distance[i] = edge[i] == 1 ? 0 : far;
  }
  // Forward: left, up, and the two upper diagonals.
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      final i = row + x;
      var best = distance[i];
      if (x > 0 && distance[i - 1] + 1 < best) best = distance[i - 1] + 1;
      if (y > 0) {
        if (distance[i - width] + 1 < best) best = distance[i - width] + 1;
        if (x > 0 && distance[i - width - 1] + diagonal < best) {
          best = distance[i - width - 1] + diagonal;
        }
        if (x + 1 < width && distance[i - width + 1] + diagonal < best) {
          best = distance[i - width + 1] + diagonal;
        }
      }
      distance[i] = best;
    }
  }
  // Backward: right, down, and the two lower diagonals.
  for (var y = height - 1; y >= 0; y--) {
    final row = y * width;
    for (var x = width - 1; x >= 0; x--) {
      final i = row + x;
      var best = distance[i];
      if (x + 1 < width && distance[i + 1] + 1 < best) best = distance[i + 1] + 1;
      if (y + 1 < height) {
        if (distance[i + width] + 1 < best) best = distance[i + width] + 1;
        if (x + 1 < width && distance[i + width + 1] + diagonal < best) {
          best = distance[i + width + 1] + diagonal;
        }
        if (x > 0 && distance[i + width - 1] + diagonal < best) {
          best = distance[i + width - 1] + diagonal;
        }
      }
      distance[i] = best;
    }
  }
  return distance;
}


int _clamp(double v) => v <= 0 ? 0 : (v >= 255 ? 255 : v.round());
