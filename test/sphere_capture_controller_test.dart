import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_station.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_target.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/application/sphere_capture_controller.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/data/jpeg_normalizer.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/platform/rotation_sensor.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/platform/sphere_camera.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// The device rotation that aims the camera at [target].
///
/// Derived from the same equation the renderer uses, so a test that aims at a
/// target proves the projection and the controller agree rather than asserting
/// a hand-tuned angle.
Quat aimAt(SphereTargetSpec target) =>
    (Quat.axisAngle(-target.yawDeg, Vec3.unitY) *
            Quat.axisAngle(target.pitchDeg, Vec3.unitX))
        .normalized;

void main() {
  late Directory temp;
  late FakeRotationSource rotation;
  late FakeCamera camera;
  late FakeRepository repository;
  late FakeStitcher stitcher;
  late SphereCaptureController controller;
  late DateTime now;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sphere_controller_test');
    rotation = FakeRotationSource();
    camera = FakeCamera();
    repository = FakeRepository(temp);
    stitcher = FakeStitcher(temp);
    now = DateTime(2026, 11, 13, 9);
    controller = SphereCaptureController(
      rotation: rotation,
      camera: camera,
      repository: repository,
      stitcher: stitcher,
      stationId: 's1',
      clock: () => now,
      haptic: () async {},
      normalize: (Uint8List bytes) async =>
          NormalizedJpeg(bytes: bytes, width: 4032, height: 3024),
      export:
          ({
            required String stationId,
            required List<SphereTargetState> targets,
            required String? panoramaPath,
          }) async => 'export/$stationId',
    );
  });

  tearDown(() async {
    controller.dispose();
    await rotation.close();
    await temp.delete(recursive: true);
  });

  Future<void> flush() =>
      Future<void>.delayed(const Duration(milliseconds: 40));

  /// Emits the aim quaternion four times, 200 ms apart, so the 600 ms hold
  /// completes and the automatic shutter fires.
  Future<void> aimAndHold(Quat aim) async {
    for (var i = 0; i < 4; i++) {
      rotation.emit(aim);
      await Future<void>.delayed(Duration.zero);
      if (i < 3) now = now.add(const Duration(milliseconds: 200));
    }
    await flush();
  }

  test('start opens the camera and exposes all 38 targets', () async {
    await controller.start();
    expect(controller.phase, SphereCapturePhase.ready);
    expect(controller.targets, hasLength(kSphereTargetCount));
    expect(controller.capturedCount, 0);
    expect(camera.isOpen, isTrue);
    expect(controller.progressLabel, 'Target 1 / 38 — Middle Ring (0°)');
  });

  test('aiming at the front target and holding captures it once', () async {
    await controller.start();
    final aim = aimAt(controller.targets.first.spec);
    rotation.emit(aim);
    await Future<void>.delayed(Duration.zero);
    expect(controller.activeTargetId, 1);
    expect(controller.activeErrorDeg, lessThan(1));

    await aimAndHold(aim);

    expect(controller.capturedCount, 1);
    expect(camera.pictures, 1);
    expect(controller.targets.first.captured, isTrue);
    expect(controller.banner, 'Captured!');
    expect(repository.records, hasLength(1));
    expect(repository.records.single.targetId, 1);
    expect(
      repository.records.single.alignmentErrorDeg,
      lessThan(kSphereAlignmentToleranceDeg),
    );
    expect(repository.records.single.imageWidth, 4032);
    expect(repository.records.single.imageHeight, 3024);
    expect(repository.records.single.anchored, isFalse);
  });

  test('a target outside the 5° cone never fires the shutter', () async {
    await controller.start();
    final offAim = Quat.axisAngle(-22.5, Vec3.unitY);
    for (var i = 0; i < 12; i++) {
      rotation.emit(offAim);
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(milliseconds: 200));
    }
    await flush();
    expect(camera.pictures, 0);
    expect(controller.capturedCount, 0);
    expect(controller.holdProgress, 0);
    expect(controller.activeErrorDeg, greaterThan(20));
  });

  test('the hold survives the 5–7° band and resets past 7°', () async {
    await controller.start();
    final aim = aimAt(controller.targets.first.spec);
    rotation.emit(aim);
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(milliseconds: 200));
    rotation.emit(aim);
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(milliseconds: 200));
    rotation.emit(aim);
    await Future<void>.delayed(Duration.zero);
    final filled = controller.holdProgress;
    expect(filled, greaterThan(0.5));

    now = now.add(const Duration(milliseconds: 200));
    rotation.emit(Quat.axisAngle(-6, Vec3.unitY));
    await Future<void>.delayed(Duration.zero);
    expect(controller.holdProgress, closeTo(filled, 1e-9));

    now = now.add(const Duration(milliseconds: 200));
    rotation.emit(Quat.axisAngle(-10, Vec3.unitY));
    await Future<void>.delayed(Duration.zero);
    expect(controller.holdProgress, 0);
  });

  test(
    'the guide follows the target order and estimates frame overlap',
    () async {
      await controller.start();
      expect(controller.guideTargetId, 1);

      await aimAndHold(aimAt(controller.targets.first.spec));
      expect(controller.capturedCount, 1);
      expect(controller.guideTargetId, 2);
      expect(controller.guideSeparationDeg, closeTo(30, 0.5));
      expect(controller.guideOverlapFraction, closeTo(0.4, 0.02));

      for (var i = 1; i < 12; i++) {
        await aimAndHold(aimAt(controller.targets[i].spec));
      }
      expect(controller.capturedCount, 12);
      // The middle ring ends at the horizon; the zenith is 90° up, then the
      // upper ring starts 45° below it.
      expect(controller.guideTargetId, 13);
      expect(controller.guideSeparationDeg, closeTo(90, 0.5));
      expect(controller.guideOverlapFraction, 0);

      await aimAndHold(aimAt(controller.targets[12].spec));
      expect(controller.capturedCount, 13);
      expect(controller.guideTargetId, 14);
      expect(controller.guideSeparationDeg, closeTo(45, 0.5));
      expect(controller.guideOverlapFraction, closeTo(0.1, 0.02));
    },
  );

  test('all 38 targets capture, then the panorama stitches once', () async {
    await controller.start();
    for (final target in controller.targets) {
      await aimAndHold(aimAt(target.spec));
      expect(
        controller.capturedCount,
        target.spec.targetId,
        reason: 'after target ${target.spec.targetId}',
      );
    }
    await flush();

    expect(controller.capturedCount, kSphereTargetCount);
    expect(controller.phase, SphereCapturePhase.complete);
    expect(camera.pictures, kSphereTargetCount);
    expect(stitcher.calls, 1);
    expect(controller.panoramaPath, isNotNull);
    expect(controller.stitchError, isNull);
  });

  test('save and finish exports the station', () async {
    await controller.start();
    for (final target in controller.targets) {
      await aimAndHold(aimAt(target.spec));
    }
    await flush();
    final path = await controller.saveAndFinish();
    expect(path, 'export/s1');
    expect(controller.exportPath, 'export/s1');
  });
}

// ── fakes ──────────────────────────────────────────────────────────────────

class FakeRotationSource implements RotationSource {
  final StreamController<Quat> _controller = StreamController<Quat>.broadcast();

  @override
  Stream<Quat> get rotations => _controller.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  void emit(Quat quaternion) => _controller.add(quaternion);

  Future<void> close() => _controller.close();
}

class FakeCamera implements SphereCamera {
  int pictures = 0;
  bool _open = false;

  @override
  Future<void> open() async => _open = true;

  @override
  bool get isOpen => _open;

  @override
  double? get previewAspectRatio => 0.75;

  @override
  Widget preview() => const SizedBox.shrink();

  @override
  Future<Uint8List> takePicture() async {
    pictures++;
    return Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]);
  }

  @override
  Future<void> close() async => _open = false;
}

class FakeRepository implements CaptureRepository {
  FakeRepository(this.root);

  final Directory root;
  final List<CaptureRecord> records = <CaptureRecord>[];

  @override
  Future<String> framePath(String stationId, int targetId) async =>
      p.join(root.path, stationId, 'frames', 't$targetId.jpg');

  @override
  Future<void> saveRecord(CaptureRecord record) async {
    records
      ..removeWhere((CaptureRecord r) => r.targetId == record.targetId)
      ..add(record);
  }

  @override
  Future<List<CaptureRecord>> loadRecords(String stationId) async =>
      List<CaptureRecord>.of(records);

  @override
  Future<void> saveStation(CaptureStation station) async {}

  @override
  Future<void> saveTargets(List<CaptureTarget> targets) async {}

  @override
  Future<void> saveCalibration(
    CaptureStation station,
    List<CaptureTarget> targets,
  ) async {}

  @override
  Future<CaptureStation?> loadStation(String stationId) async => null;

  @override
  Future<List<CaptureTarget>> loadTargets(String stationId) async =>
      const <CaptureTarget>[];

  @override
  Future<List<String>> stationIds() async => const <String>[];
}

class FakeStitcher implements PanoramaStitcher {
  FakeStitcher(this.root);

  final Directory root;
  int calls = 0;

  @override
  Future<StitchResult> stitchFrames(
    List<String> imagePaths, {
    void Function(String stage)? onStage,
  }) async {
    calls++;
    onStage?.call('Stitching ${imagePaths.length} frames…');
    return StitchResult(
      success: true,
      panoramaPath: p.join(root.path, 'panorama.jpg'),
      message: 'Panorama generated successfully.',
    );
  }
}
