/// Per-channel colour balance across the frames of one station.
///
/// ## Why this exists alongside the stitcher's median gains
///
/// [solveChannelMedianGains] in the stitcher recovers one bounded gain per
/// photograph per channel from the medians of the pixels photographs share.
/// That levels the dominant difference — every frame runs its own
/// auto-exposure and auto-white-balance loop — but a frame whose overlap
/// samples are sparse or skewed can keep a residual hue step.
///
/// This pass corrects that residual per channel. Each frame's mean colour over
/// the pixels it shares with a neighbour is compared with the station-wide mean,
/// and the ratio becomes a bounded multiplicative correction.
///
/// ## Why the correction is clamped
///
/// A frame that legitimately contains a large red object would otherwise be
/// "corrected" toward grey, which is worse than the seam it was meant to hide.
/// The clamp ([kColourBalanceMin], [kColourBalanceMax]) keeps the pass inside
/// what white-balance drift can plausibly explain. Outside that range the honest
/// answer is that the frames disagree about the scene, not about the exposure —
/// and that is reported as a quality metric rather than painted over.
library;

import 'dart:typed_data';

/// Lower bound on a per-channel correction.
const double kColourBalanceMin = 0.70;

/// Upper bound on a per-channel correction.
const double kColourBalanceMax = 1.35;

/// Solves one multiplicative correction per frame per channel.
///
/// Returns `frameCount * 3` values, indexed `frame * 3 + channel`, all `1.0` for
/// a frame with no usable overlap (nothing proven, nothing changed).
Float64List solveColourBalance({
  required int frameCount,
  required int pixelCount,
  required Int16List bestFrame,
  required Int16List secondFrame,
  required Float32List bestWeight,
  required Float32List secondWeight,
  required Uint8List bestColour,
  required Uint8List secondColour,
  double minWeight = 0,
}) {
  final sums = Float64List(frameCount * 3);
  final weights = Float64List(frameCount);

  for (var i = 0; i < pixelCount; i++) {
    final b = bestFrame[i];
    final wb = bestWeight[i];
    if (b >= 0 && wb > minWeight) {
      for (var c = 0; c < 3; c++) {
        sums[b * 3 + c] += bestColour[i * 3 + c] * wb;
      }
      weights[b] += wb;
    }
    final s = secondFrame[i];
    final ws = secondWeight[i];
    if (s >= 0 && ws > minWeight) {
      for (var c = 0; c < 3; c++) {
        sums[s * 3 + c] += secondColour[i * 3 + c] * ws;
      }
      weights[s] += ws;
    }
  }

  // Station-wide reference: the weighted mean colour of the whole overlap.
  final reference = Float64List(3);
  var totalWeight = 0.0;
  for (var f = 0; f < frameCount; f++) {
    if (weights[f] <= 0) continue;
    totalWeight += weights[f];
    for (var c = 0; c < 3; c++) {
      reference[c] += sums[f * 3 + c];
    }
  }

  final balance = Float64List(frameCount * 3)
    ..fillRange(0, frameCount * 3, 1.0);
  if (totalWeight <= 0) return balance;
  for (var c = 0; c < 3; c++) {
    reference[c] /= totalWeight;
  }

  for (var f = 0; f < frameCount; f++) {
    if (weights[f] <= 0) continue;
    for (var c = 0; c < 3; c++) {
      final mean = sums[f * 3 + c] / weights[f];
      if (mean <= 1e-3) continue;
      final ratio = reference[c] / mean;
      balance[f * 3 + c] = ratio.clamp(kColourBalanceMin, kColourBalanceMax);
    }
  }
  return balance;
}

/// Applies [balance] to one contributor buffer, in place.
///
/// Pixels whose `frame` is negative (no contributor) are left untouched.
void applyColourBalance(
  Uint8List colour,
  Int16List frame,
  Float64List balance,
) {
  for (var i = 0; i < frame.length; i++) {
    final f = frame[i];
    if (f < 0) continue;
    final base = f * 3;
    for (var c = 0; c < 3; c++) {
      final value = colour[i * 3 + c] * balance[base + c];
      colour[i * 3 + c] = value <= 0 ? 0 : (value >= 255 ? 255 : value.round());
    }
  }
}
