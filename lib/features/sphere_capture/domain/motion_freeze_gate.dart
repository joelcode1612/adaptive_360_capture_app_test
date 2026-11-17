/// "The phone has stopped turning" — the gyroscope half of the capture gate.
///
/// ## Why this exists
///
/// Angular alignment alone says the target is *in the right place*, not that the
/// phone has *stopped*. A sweep that passes through the target at speed can
/// satisfy a 2° cone for a single sample, and a still taken while the phone is
/// rotating rolls the shutter across a vertical wall: the top of the frame is
/// exposed a few milliseconds before the bottom, so door frames and wall corners
/// lean by an amount that grows with the rate. The result is a frame that
/// *looks* sharp but cannot be aligned to its neighbour, which then shows up as
/// a torn seam rather than as a blurry photograph.
///
/// The gate is therefore a **dwell**: the angular rate must stay under
/// [maxRateRadPerSec] continuously for [requiredStill]. One fast sample resets
/// it — a pause is a pause, not an average.
///
/// 0.05 rad/s is about 2.9°/s: slow enough that the shutter's exposure window
/// contributes no visible skew, and reachable by a hand holding a phone steady.
library;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Tracks how long the device has been angularly still.
class MotionFreezeGate {
  MotionFreezeGate({
    this.maxRateRadPerSec = 0.05,
    this.requiredStill = const Duration(milliseconds: 250),
  });

  /// Angular rate, in rad/s, at or below which the phone counts as still.
  final double maxRateRadPerSec;

  /// How long the rate must stay under [maxRateRadPerSec] before [still].
  final Duration requiredStill;

  DateTime? _stillSince;
  DateTime? _lastUpdate;
  double _lastRate = double.infinity;

  /// When the current still window began, or null when the phone is moving.
  DateTime? get stillSince => _stillSince;

  /// The most recent angular rate magnitude, in rad/s.
  double get lastRateRadPerSec => _lastRate;

  /// Whether the phone has been still for [requiredStill].
  bool get still {
    final since = _stillSince;
    final at = _lastUpdate;
    if (since == null || at == null) return false;
    return at.difference(since) >= requiredStill;
  }

  /// How far into the dwell the phone is, 0–1. Drives a progress ring if wanted.
  double get progress {
    final since = _stillSince;
    final at = _lastUpdate;
    if (since == null || at == null) return 0;
    final elapsed = at.difference(since).inMicroseconds;
    final needed = requiredStill.inMicroseconds;
    if (needed <= 0) return 1;
    return (elapsed / needed).clamp(0.0, 1.0);
  }

  /// Feeds one gyroscope sample.
  ///
  /// [rateRadPerSec] is the raw gyroscope vector in rad/s, in the device frame;
  /// only its magnitude matters here.
  void update(Vec3 rateRadPerSec, DateTime at) {
    _lastUpdate = at;
    final rate = rateRadPerSec.length;
    _lastRate = rate.isFinite ? rate : double.infinity;
    if (_lastRate <= maxRateRadPerSec) {
      _stillSince ??= at;
    } else {
      // Any sample above the threshold breaks the dwell, including one bad one:
      // a spike is exactly the moment a still would be skewed.
      _stillSince = null;
    }
  }

  /// Forgets the dwell. Called when the capture session restarts.
  void reset() {
    _stillSince = null;
    _lastUpdate = null;
    _lastRate = double.infinity;
  }
}
