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
/// 3. **Narrow feather.** A boundary is invisible only if both sides are
///    identical; they never are. The transition is cross-faded over a narrow
///    band of [kSeamFeatherPx] pixels per side of the seam, and the ramp
///    reaches **pure owner** at the band's edge — so every object is drawn
///    once, at 100% opacity, from a single frame. Full
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

/// Feather half-width, in pixels, applied strictly across an ownership
/// boundary.
///
/// Keep this transition narrow: long feather bands double close objects
/// when parallax makes overlapping frames disagree geometrically.
const int kSeamFeatherPx = 6;

/// Sigma of the Gaussian profile used across the ownership seam.
///
/// A short Gaussian falloff only around genuine, well-aligned seams.
const double kSeamGaussianSigmaPx = 4.0;

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
/// [channelGains] holds one bounded multiplicative correction per frame per
/// channel, indexed `frame * 3 + channel` — the median-ratio colour match the
/// stitcher solves before compositing. All other inputs are the stitcher's
/// existing per-pixel buffers; nothing here allocates per frame, so cost is
/// bounded by the canvas, not the frame count.
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
  required List<double> channelGains,
  required double minWeight,
  int featherPx = kSeamFeatherPx,
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
    // No overlap anywhere: nothing to deghost. Straight copy with colour gain.
    _writeBestOnly(
      output: output,
      count: n,
      bestColour: bestColour,
      bestWeight: bestWeight,
      bestFrame: bestFrame,
      channelGains: channelGains,
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

  // Remove isolated graph-cut / row-polish staircase teeth, but only where
  // the original photographs agree. This does not fabricate scene data.
  final smoothedSpikes = smoothIsolatedSeamSpikes(
    label: label,
    width: width,
    height: height,
    bestFrame: bestFrame,
    secondFrame: secondFrame,
    bestWeight: bestWeight,
    secondWeight: secondWeight,
    bestColour: bestColour,
    secondColour: secondColour,
    minWeight: minWeight,
  );

  // ── 2. Ghost measurement, before compositing. ──────────────────────────
  // Measured on the *colour-corrected* contributors, because a brightness or
  // hue step that the median-gain solve already removed is not ghosting.
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
    // but indexing `channelGains` with −1 here would throw inside the
    // stitching isolate and fail the whole station. Guarding is cheaper than
    // that risk.
    if (bestFrame[i] < 0) continue;
    final bestIdx = bestFrame[i] * 3;
    final secondIdx = secondFrame[i] * 3;
    var d = 0.0;
    for (var c = 0; c < 3; c++) {
      final a = bestColour[i * 3 + c] * channelGains[bestIdx + c];
      final b = secondColour[i * 3 + c] * channelGains[secondIdx + c];
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

  // ── 3a. Ownership map and distance-to-seam. ───────────────────────────
  //
  // The band below is measured from the **owner change**, which is the only
  // thing that actually defines a seam, and it is narrow on purpose: all but
  // a few pixels of every photograph are rendered at full clarity from a
  // single source. (For history: a blurred binary mask produced hard
  // cut-lines because the mask read 1.0 across a boundary, and blending by
  // the weight ratio everywhere mixed a bright frame into a dark one across
  // the whole overlap — the chalky wash and the translucent double image.
  // Neither artefact can occur here.)
  // Build the full ownership map before looking up any neighbours.
  // Previously, right/down neighbours were still at the Int16List default 0,
  // marking nearly every pixel owned by any other frame as a fake seam.
  // The feather then mixed two photographs across whole walls and furniture.
  final owner = Int16List(n)..fillRange(0, n, -1);
  for (var i = 0; i < n; i++) {
    if (bestFrame[i] < 0 || bestWeight[i] <= minWeight) continue;
    final useSecond =
        secondFrame[i] >= 0 &&
        secondWeight[i] > minWeight &&
        label[i] == 1;
    owner[i] = useSecond ? secondFrame[i] : bestFrame[i];
  }

  // Only real boundaries between two covered photographs are seams.
  final edge = Uint8List(n);
  var seamPixels = 0;
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      final i = row + x;
      final own = owner[i];
      if (own < 0) continue;
      final isEdge =
          (x > 0 && owner[i - 1] >= 0 && owner[i - 1] != own) ||
          (x + 1 < width && owner[i + 1] >= 0 && owner[i + 1] != own) ||
          (y > 0 && owner[i - width] >= 0 && owner[i - width] != own) ||
          (y + 1 < height && owner[i + width] >= 0 && owner[i + width] != own);
      if (isEdge) {
        edge[i] = 1;
        seamPixels++;
      }
    }
  }

  final seamDistance = _distanceToEdge(edge, width, height);

  // SITEWISE_OBJECT_INTEGRITY_V1: a 12px-wide transition, 6px each
  // side, even near the poles. Its Gaussian mask has sigma=4 (equivalent to
  // the centre portion of a 19x19 GaussianBlur kernel). This does NOT blur
  // photographed objects: only agreeing pixels along real ownership seams
  // can blend; all other pixels remain 100% their assigned frame.
  final bandForRow = Float32List(height)
    ..fillRange(0, height, featherPx.toDouble());

  // ── 3b. Composite: the owner renders the pixel, feathered at the seam. ─
  //
  // Every pixel is rendered from the frame that **owns** it — the graph cut's
  // side of the seam — at full opacity. The only cross-fade is a band of
  // `featherPx` either side of an ownership boundary: 50/50 exactly on the
  // seam, ramping to pure owner at the band's edge.
  //
  // The earlier version of this loop blended `best`/`second` by distance but
  // never read the ownership label, so pixels the cut handed to the second
  // contributor still rendered the best contributor's colour wherever they
  // sat outside the band — the wrong side of a parallax-shifted object. This
  // loop is owner-driven: far from any boundary, alpha is exactly 1.0 on the
  // owner's side and 0.0 on the other, which is what removes the
  // translucent-wardrobe double image.
  for (var i = 0; i < n; i++) {
    final bestIdx = bestFrame[i];
    // Uncovered pixels stay zero here — `fillUncovered` owns them, and the
    // gap-fill covered test (`bestWeight > minWeight`) must agree exactly.
    if (bestIdx < 0 || bestWeight[i] <= minWeight) continue;
    final secondIdx = secondFrame[i];
    if (secondIdx < 0 || secondWeight[i] <= minWeight) {
      for (var c = 0; c < 3; c++) {
        output[i * 3 + c] = _clamp(
          bestColour[i * 3 + c] * channelGains[bestIdx * 3 + c],
        );
      }
      continue;
    }
    final ownSecond = label[i] == 1;
    final ownIdx = ownSecond ? secondIdx : bestIdx;
    final otherIdx = ownSecond ? bestIdx : secondIdx;
    // Gaussian cumulative profile: 0.5 exactly on the seam, rising to ~1.0
    // at two sigma. This is the per-pixel equivalent of blurring each owner
    // mask with a 41×41, σ=12 Gaussian and normalising W_i / ΣW_i, without a
    // second full-canvas mask. No linear ramp remains, so the rectangular
    // borders that a linear 5px ramp left on flat walls are gone.
    final band = bandForRow[i ~/ width];
    // Per-pixel top-two ranks do not define a globally consistent frame pair.
    // The second candidate must genuinely own an adjacent seam pixel; mixing
    // an unrelated third photo produced the translucent polygon artifacts.
    // For substantial geometric disagreement, keep the owner's full-opacity
    // colour instead of displaying two displaced objects at partial opacity.
    final canFeather =
        seamDistance[i] < band &&
        diffField[i] <= kGhostVisibleDelta &&
        _hasNeighbourOwnedBy(owner, width, height, i, otherIdx);
    final wOwn = canFeather
        ? 0.5 + 0.5 * (_seamGaussian(seamDistance[i] / band) /
              _seamGaussian(1.0)).clamp(0.0, 1.0)
        : 1.0;
    for (var c = 0; c < 3; c++) {
      final ownValue =
          (ownSecond ? secondColour[i * 3 + c] : bestColour[i * 3 + c]) *
          channelGains[ownIdx * 3 + c];
      final otherValue =
          (ownSecond ? bestColour[i * 3 + c] : secondColour[i * 3 + c]) *
          channelGains[otherIdx * 3 + c];
      output[i * 3 + c] = _clamp(ownValue * wOwn + otherValue * (1 - wOwn));
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
      final ownerPrev = label[i - 1] == 0
          ? bestFrame[i - 1]
          : secondFrame[i - 1];
      if (ownerHere == ownerPrev) continue;
      seamStepSum += _outputDelta(output, i, i - 1);
      seamStepCount++;
    }
    wrapSum += _outputDelta(output, row, row + width - 1);
  }

  return SeamBlendStats(
    seamPixels: seamPixels,
    flippedPixels: moved + smoothedSpikes,
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
        height: height,
        rowStart: row,
        bestFrame: bestFrame,
        secondFrame: secondFrame,
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
  required int height,
  required int rowStart,
  required int boundary,
  required Int16List bestFrame,
  required Int16List secondFrame,
  required Float32List bestWeight,
  required Float32List secondWeight,
  required Uint8List bestColour,
  required Uint8List secondColour,
}) {
  final current = _seamCostAt(
    rowStart: rowStart,
    position: boundary,
    width: width,
    height: height,
    bestFrame: bestFrame,
    secondFrame: secondFrame,
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
      width: width,
      height: height,
      bestFrame: bestFrame,
      secondFrame: secondFrame,
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
  required int width,
  required int height,
  required Int16List bestFrame,
  required Int16List secondFrame,
  required Uint8List bestColour,
  required Uint8List secondColour,
}) {
  final i = rowStart + position;
  // SITEWISE_OBJECT_INTEGRITY_V1: the graph-cut and the full-res polish
  // minimize the SAME edge-aware seam energy. A seam must not move back
  // through a monitor bezel or cabinet edge in the polish stage.
  final cost = seamPixelCostAt(
    bestColour: bestColour,
    secondColour: secondColour,
    bestFrame: bestFrame,
    secondFrame: secondFrame,
    width: width,
    height: height,
    index: i,
  );
  return kSeamCostWeight * cost / 255.0;
}

/// Mean absolute channel difference between two composited pixels.
double _outputDelta(Uint8List rgb, int a, int b) =>
    ((rgb[a * 3] - rgb[b * 3]).abs() +
        (rgb[a * 3 + 1] - rgb[b * 3 + 1]).abs() +
        (rgb[a * 3 + 2] - rgb[b * 3 + 2]).abs()) /
    3.0;


void _writeBestOnly({
  required Uint8List output,
  required int count,
  required Uint8List bestColour,
  required Float32List bestWeight,
  required Int16List bestFrame,
  required List<double> channelGains,
  required double minWeight,
}) {
  for (var i = 0; i < count; i++) {
    if (bestWeight[i] <= minWeight) continue;
    final f = bestFrame[i] < 0 ? 0 : bestFrame[i];
    for (var c = 0; c < 3; c++) {
      output[i * 3 + c] = _clamp(
        bestColour[i * 3 + c] * channelGains[f * 3 + c],
      );
    }
  }
}

/// Only a frame actually visible on the opposite side of this boundary is a
/// valid feathering partner. A nearby unrelated seam is not sufficient.
/// An alternative may be a few pixels across the same seam rather than
/// immediately adjacent. Keep the search local and limited to genuine owner
/// pixels: best/second ranks can represent entirely different pairs elsewhere.
bool _hasNeighbourOwnedBy(
  Int16List owner,
  int width,
  int height,
  int i,
  int otherFrame,
) {
  if (otherFrame < 0) return false;
  final x = i % width;
  final y = i ~/ width;
  const maxDistance = 6;
  for (var distance = 1; distance <= maxDistance; distance++) {
    final left = x - distance;
    final right = x + distance;
    final up = y - distance;
    final down = y + distance;
    if (left >= 0 && owner[y * width + left] == otherFrame) return true;
    if (right < width && owner[y * width + right] == otherFrame) return true;
    if (up >= 0 && owner[up * width + x] == otherFrame) return true;
    if (down < height && owner[down * width + x] == otherFrame) return true;
    // Diagonal approaches matter for staircase-shaped contours.
    if (left >= 0 && up >= 0 && owner[up * width + left] == otherFrame) {
      return true;
    }
    if (right < width && up >= 0 && owner[up * width + right] == otherFrame) {
      return true;
    }
    if (left >= 0 && down < height &&
        owner[down * width + left] == otherFrame) {
      return true;
    }
    if (right < width && down < height &&
        owner[down * width + right] == otherFrame) {
      return true;
    }
  }
  return false;
}

/// PANORAMA_SEAM_QUALITY_20261119: remove only isolated, low-difference
/// ownership spikes. The graph cut and row polish sometimes leave single-pixel
/// staircase teeth at the edges of a wall or wardrobe. Do not change a pixel
/// unless at least three direct neighbours genuinely belong to the other
/// candidate frame and its two photographs already agree photometrically.
/// Never invent pixels, copy from an unrelated third frame, or blur an object.
int smoothIsolatedSeamSpikes({
  required Uint8List label,
  required int width,
  required int height,
  required Int16List bestFrame,
  required Int16List secondFrame,
  required Float32List bestWeight,
  required Float32List secondWeight,
  required Uint8List bestColour,
  required Uint8List secondColour,
  required double minWeight,
}) {
  if (width < 3 || height < 3) return 0;
  final n = width * height;
  final flips = Uint8List(n);
  int ownerAt(int i) {
    if (bestFrame[i] < 0 || bestWeight[i] <= minWeight) return -1;
    if (label[i] == 1 && secondFrame[i] >= 0 &&
        secondWeight[i] > minWeight) {
      return secondFrame[i];
    }
    return bestFrame[i];
  }

  // Read only from the original label map in this sweep: editing in-place
  // creates order-dependent streaks that make the seam even more jagged.
  for (var y = 1; y + 1 < height; y++) {
    final row = y * width;
    for (var x = 1; x + 1 < width; x++) {
      final i = row + x;
      if (secondFrame[i] < 0 || secondWeight[i] <= minWeight ||
          bestFrame[i] < 0 || bestWeight[i] <= minWeight ||
          bestFrame[i] == secondFrame[i]) {
        continue;
      }
      final current = ownerAt(i);
      final alternative = label[i] == 0 ? secondFrame[i] : bestFrame[i];
      if (current == alternative) continue;
      final neighbours = <int>[i - 1, i + 1, i - width, i + width];
      var alternativeCount = 0;
      for (final j in neighbours) {
        if (ownerAt(j) == alternative) alternativeCount++;
      }
      if (alternativeCount < 3) continue;
      var difference = 0;
      for (var c = 0; c < 3; c++) {
        difference += (bestColour[i * 3 + c] -
                secondColour[i * 3 + c]).abs();
      }
      if (difference / 3 > kGhostVisibleDelta) continue;
      flips[i] = 1;
    }
  }
  var changed = 0;
  for (var i = 0; i < n; i++) {
    if (flips[i] == 0) continue;
    label[i] = label[i] == 0 ? 1 : 0;
    changed++;
  }
  return changed;
}

/// Gaussian cumulative weight from a signed seam distance normalised by the
/// feather band: `erf(d / (σ√2))`, 0 at the seam, ~1 beyond two sigma.
///
/// `dart:math` has no `erf`, so Abramowitz–Stegun 7.1.26 supplies it — the
/// approximation is within 1.5e-7 over the whole domain, far below one byte
/// of output. Using the CDF rather than a linear ramp is what removes the
/// visible brightness boundary on large flat walls and ceilings.
double _seamGaussian(double normalisedDistance) {
  // `normalisedDistance` is distance / the 6px half-width; the
  // Gaussian sigma is 4px. Mask values are normalized at band edge.
  final dSigma = normalisedDistance * (kSeamFeatherPx / kSeamGaussianSigmaPx);
  final x = dSigma < 0 ? 0.0 : dSigma;
  if (x >= 3.0) return 1.0;
  final z = x / math.sqrt(2);
  const double a1 = 0.254829592;
  const double a2 = -0.284496736;
  const double a3 = 1.421413741;
  const double a4 = -1.453152027;
  const double a5 = 1.061405429;
  const double p = 0.3275911;
  final t = 1 / (1 + p * z);
  final erf =
      1 -
      (((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t * math.exp(-z * z));
  return erf.clamp(0.0, 1.0).toDouble();
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
      if (x + 1 < width && distance[i + 1] + 1 < best) {
        best = distance[i + 1] + 1;
      }
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
