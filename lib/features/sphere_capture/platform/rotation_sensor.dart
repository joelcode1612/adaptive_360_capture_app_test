import 'dart:async';

import 'package:flutter/services.dart';

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';

/// The device-rotation stream the 3DoF architecture runs on.
///
/// One abstract class exists so the capture controller can be tested without a
/// platform channel: the production implementation is [NativeRotationSource],
/// and the tests feed a `StreamController<Quat>` directly.
abstract class RotationSource {
  /// Device → world quaternions, in the Android sensor frame.
  Stream<Quat> get rotations;

  /// Starts the platform sensor. Idempotent.
  Future<void> start();

  /// Stops it and releases the sensor. Idempotent.
  Future<void> stop();
}

/// Android's `TYPE_ROTATION_VECTOR`, delivered by the Kotlin host.
///
/// This is the sensor the specification names: a fused orientation estimate
/// (accelerometer + gyroscope, magnetometer-corrected where present) reported
/// as a unit quaternion in the device frame. It is deliberately **not** a
/// hand-rolled gyro integrator: heading drift would accumulate across a full
/// 360° sweep, and the sphere's targets are fixed in heading.
///
/// The channel carries `[x, y, z, w]` as doubles. Anything that is not four
/// finite numbers is dropped rather than normalised into a pose the renderer
/// would then trust.
class NativeRotationSource implements RotationSource {
  NativeRotationSource({EventChannel? channel})
    : _channel = channel ?? const EventChannel('adaptive360/rotation');

  final EventChannel _channel;

  final StreamController<Quat> _out = StreamController<Quat>.broadcast();
  StreamSubscription<dynamic>? _subscription;

  @override
  Stream<Quat> get rotations => _out.stream;

  bool get isRunning => _subscription != null;

  @override
  Future<void> start() async {
    if (_subscription != null) return;
    _subscription = _channel.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) {
        if (!_out.isClosed) _out.addError(error);
      },
      cancelOnError: false,
    );
  }

  void _onEvent(dynamic event) {
    if (event is! List || event.length < 4) return;
    final x = (event[0] as num).toDouble();
    final y = (event[1] as num).toDouble();
    final z = (event[2] as num).toDouble();
    final w = (event[3] as num).toDouble();
    if (!x.isFinite || !y.isFinite || !z.isFinite || !w.isFinite) return;
    final quaternion = Quat(x, y, z, w);
    if (quaternion.length < 1e-6) return;
    if (!_out.isClosed) _out.add(quaternion.normalized);
  }

  @override
  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  Future<void> dispose() async {
    await stop();
    await _out.close();
  }
}
