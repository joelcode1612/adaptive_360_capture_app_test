import 'dart:math' as math;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/guidance/projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Gyro-plus-accelerometer attitude estimation, in the Android device frame.
///
/// This is the numerical core behind [SensorPoseSource] on a device with no
/// ARCore. It lives here, separate from the plugin, for two reasons: it is the
/// only new maths in this port, and `sensors_plus` cannot be imported by the
/// plain-`dart` harness that runs the rest of the geometry — so an estimator
/// that only existed inside the plugin wrapper would have had no test at all.
///
/// ## Frames, stated once
///
/// `deviceToWorld` is the rotation `D` from the **Android sensor frame** to the
/// world frame: device `+X` right, `+Y` towards the top of the screen, `+Z` out
/// of the *back* of the phone; world `+Y` up. That device frame is the same one
/// ARCore reports camera poses in, which is why `D` can be handed to
/// `ArPose.orientation` unchanged — see `sensor_pose_source.dart`.
///
/// ## Why the accelerometer says *up*
///
/// A resting accelerometer measures specific force, not gravitational
/// acceleration: it reads the reaction that keeps the phone from falling, which
/// points **away from the ground**. A phone flat on a table reads `(0, 0, +9.8)`,
/// not `(0, 0, −9.8)`. So the reading's direction is world-up expressed in
/// device coordinates, `Dᵀ·ŷ`, and that is what the error is measured against.
///
/// Getting this sign backwards does not throw and does not look wrong in the
/// code — it makes the estimator converge to the phone being face-down when it
/// is face-up, i.e. the zenith and nadir frames swap, and only a test with a
/// named physical pose catches it. That is `fusion_checks.dart`'s flat-on-table
/// check.
///
/// ## What is observable
///
/// Gravity fixes two of the three degrees of freedom. The remaining one —
/// rotation about the world vertical, i.e. heading — has no reference here, so
/// the filter keeps whatever heading the gyro integration gave it, and that
/// heading drifts by the gyro's bias. Every target direction in this app is
/// measured relative to the heading locked at "Set Station Here", which is what
/// makes a drifting-but-consistent heading usable.
class AttitudeFusion {
  /// Fraction of the tilt error corrected per [step].
  ///
  /// With a 20 ms sample period this pulls the estimate towards gravity with a
  /// time constant near 0.4 s: fast enough that the horizon does not visibly
  /// sag, slow enough that a walking stride does not swing the reticle.
  /// Provisional, and `DEVICE_TEST_CHECKLIST.md` measures it.
  final double beta;

  /// Accelerometer magnitude, in m/s², that is accepted as gravity.
  final ({double min, double max}) gravityWindow;

  Quat _deviceToWorld = Quat.identity;
  bool _lastSampleUsedGravity = false;

  /// Whether a real gravity sample has been applied in full yet.
  ///
  /// Until it has, the estimate is only a gyro integration from identity, which
  /// is *not* the horizon unless the phone happens to be perfectly upright.
  bool _gravityInitialised = false;

  AttitudeFusion({
    this.beta = 0.05,
    this.gravityWindow = const (min: 6.9, max: 12.8),
  });

  /// The estimate, as a device → world rotation.
  Quat get deviceToWorld => _deviceToWorld;

  /// The same estimate in this project's capture-world convention.
  ///
  /// The one conversion, shared with every other pose source, so the sensor
  /// path cannot develop its own handedness.
  Quat get captureWorld => arCameraPoseToCaptureWorld(_deviceToWorld);

  /// Whether the most recent [step] was able to use its accelerometer sample.
  ///
  /// `false` means the sample was rejected as not-gravity (or there was no
  /// accelerometer at all) and that step was gyro-only.
  bool get lastSampleUsedGravity => _lastSampleUsedGravity;

  /// Resets to "device axes are world axes", i.e. upright portrait, heading 0.
  void reset() {
    _deviceToWorld = Quat.identity;
    _lastSampleUsedGravity = false;
    // Re-armed: the next usable accelerometer sample re-establishes the horizon
    // in one step instead of easing toward it.
    _gravityInitialised = false;
  }

  /// The gravity direction the model expects, in device coordinates.
  ///
  /// Exposed because it is the whole contract between the filter and the
  /// accelerometer: a test can ask what sample this attitude implies instead of
  /// trusting a hand-derived vector.
  Vec3 get expectedGravityDevice => _deviceToWorld.conjugate.rotate(Vec3.unitY);

  /// One fused sample.
  ///
  /// [accelMs2] is the raw accelerometer vector in m/s², [gyroRadSec] the raw
  /// gyroscope vector in rad/s (both in the device frame, as the framework
  /// reports them), and [dtSeconds] the elapsed time since the previous call.
  ///
  /// Either input may be short by a component the other sensor cannot supply —
  /// that is the point of fusing them — but both are needed for a correction, so
  /// a step with no accelerometer integrates the gyro and nothing else.
  void step({
    required Vec3 accelMs2,
    required Vec3 gyroRadSec,
    required double dtSeconds,
  }) {
    if (dtSeconds <= 0 || dtSeconds > 0.25) return;

    // 1. The gyro reports rotation about the *device's own* axes, so the
    //    increment goes on the right: `D ← D · exp(½ ω dt)`.
    final rate = gyroRadSec.length;
    if (rate > 1e-6) {
      _deviceToWorld =
          (_deviceToWorld *
                  Quat.axisAngle(
                    rate * dtSeconds * radToDeg,
                    gyroRadSec.normalized,
                  ))
              .normalized;
    }

    // 2. Gravity. A moving phone measures acceleration, not gravity, so a
    //    sample outside the window is dropped rather than trusted partially —
    //    the gyro alone carries that step.
    final mag = accelMs2.length;
    if (mag < gravityWindow.min || mag > gravityWindow.max) {
      _lastSampleUsedGravity = false;
      return;
    }
    final measured = accelMs2.normalized;
    final expected = expectedGravityDevice;

    // ── First usable gravity sample: solve tilt, do not ease into it ──────
    //
    // `beta` is a *fraction of the error per step*, which is the right rule for
    // a running filter and the wrong rule for the first sample. Starting from
    // identity, the horizon spends roughly 1/β steps — about 0.4 s at 20 ms —
    // converging, so the first frames show a tilted horizon: the middle ring
    // sits off the reticle at exactly the moment the user is aiming with it.
    //
    // The first accelerometer reading that passes the gravity window is a
    // direct measurement of up, so the whole error is applied at once. The
    // correction axis is perpendicular to gravity, so this fixes pitch and roll
    // and leaves heading untouched at its initial value of 0 — which is what
    // puts the first middle-ring target dead ahead.
    if (!_gravityInitialised) {
      _gravityInitialised = true;
      _lastSampleUsedGravity = true;
      final snapAxis = measured.cross(expected);
      final snapLen = snapAxis.length;
      if (snapLen >= 1e-9) {
        final snapDeg =
            math.atan2(snapLen, measured.dot(expected)) * radToDeg;
        _deviceToWorld =
            (_deviceToWorld *
                    Quat.axisAngle(snapDeg, snapAxis.normalized))
                .normalized;
      }
      return;
    }

    // δ rotates `measured` onto `expected`, and is applied on the right so it
    // acts in the device frame. The axis is perpendicular to both up-vectors,
    // hence near-horizontal, which is how the correction fixes tilt without
    // touching heading.
    final axis = measured.cross(expected);
    final axisLen = axis.length;
    if (axisLen < 1e-9) {
      _lastSampleUsedGravity = true;
      return;
    }
    final angleDeg =
        math.atan2(axisLen, measured.dot(expected)) * radToDeg * beta;
    _deviceToWorld =
        (_deviceToWorld * Quat.axisAngle(angleDeg, axis.normalized)).normalized;
    _lastSampleUsedGravity = true;
  }

  /// Feeds [count] samples of the attitude's own equilibrium state.
  ///
  /// Only useful for tests and for the startup pre-roll, where the point is to
  /// let the gravity correction reach the horizon before the user is asked to
  /// trust the reticle.
  void settleFromGravity({required int count, double dtSeconds = 0.02}) {
    final g = expectedGravityDevice * 9.80665;
    for (var i = 0; i < count; i++) {
      step(accelMs2: g, gyroRadSec: Vec3.zero, dtSeconds: dtSeconds);
    }
  }

  @override
  String toString() =>
      'AttitudeFusion(${(_deviceToWorld.length - 1).abs() < 1e-9 ? 'unit' : 'NOT UNIT'}, '
      'gravity used: $_lastSampleUsedGravity)';
}
