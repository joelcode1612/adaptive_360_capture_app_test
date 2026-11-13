import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Walking detection from the raw accelerometer, for the "sphere synced" cue.
///
/// The sphere needs no translation estimate — it is locked to the phone by
/// construction — so this exists purely to confirm to the user that the app is
/// following them. That is why it can be a variance test rather than a
/// pedometer: no `ACTIVITY_RECOGNITION` permission, no hardware step counter,
/// and no claim about a step count.
///
/// A rolling window of `|a|` is used rather than the instantaneous value
/// because a single sample cannot distinguish a step from a hand tremor. The
/// standard deviation over ~1.2 s does: a phone resting on a tripod reads
/// gravity with a deviation near 0.02 m/s², while a walking stride swings it
/// by well over 1 m/s².
class MotionDetector {
  MotionDetector({
    this.window = const Duration(milliseconds: 1200),
    this.movingThresholdMs2 = 0.45,
    this.minimumSamples = 6,
  });

  /// How much history the variance is measured over.
  final Duration window;

  /// Standard deviation of `|a|`, in m/s², above which the user is walking.
  final double movingThresholdMs2;

  /// Samples required before [moving] answers `true`; below this the window
  /// is not evidence of anything.
  final int minimumSamples;

  final List<({DateTime at, double magnitude})> _samples =
      <({DateTime at, double magnitude})>[];

  /// Whether the recent accelerometer history looks like walking.
  bool get moving {
    if (_samples.length < minimumSamples) return false;
    var sum = 0.0;
    for (final sample in _samples) {
      sum += sample.magnitude;
    }
    final mean = sum / _samples.length;
    var variance = 0.0;
    for (final sample in _samples) {
      final delta = sample.magnitude - mean;
      variance += delta * delta;
    }
    final deviation = math.sqrt(variance / _samples.length);
    return deviation > movingThresholdMs2;
  }

  /// Number of samples currently in the window, for diagnostics and tests.
  int get sampleCount => _samples.length;

  /// Adds one raw accelerometer reading (m/s², device frame).
  void addSample(Vec3 acceleration, DateTime at) {
    _samples.add((at: at, magnitude: acceleration.length));
    final cutoff = at.subtract(window);
    _samples.removeWhere(
      (({DateTime at, double magnitude}) sample) => sample.at.isBefore(cutoff),
    );
  }

  void reset() => _samples.clear();
}
