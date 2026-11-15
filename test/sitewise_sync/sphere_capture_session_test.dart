import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/application/sphere_capture_controller.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/normalized_jpeg.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/platform/rotation_sensor.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/platform/sphere_camera.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

import 'support/test_support.dart';

/// The SQLite ↔ capture-workflow seam.
///
/// The 38-target geometry, the shutter and the stitcher are untouched by this
/// change, so these tests deliberately do not drive them. What they prove is the
/// part that is new: a session reopened on a new launch comes back with its
/// saved targets, and it only counts a target whose JPEG is still on disk.
void main() {
  late TestStore harness;
  late TempWorkspace workspace;

  setUp(() async {
    harness = await openTestStore();
    workspace = await TempWorkspace.create();
  });

  tearDown(() async {
    await harness.close();
    await workspace.dispose();
  });

  Future<SphereCaptureController> controllerFor(
    String sessionId, {
    String? userId,
    int? propertyId,
  }) async => SphereCaptureController(
    rotation: FakeRotation(),
    camera: FakeCamera(),
    repository: FileCaptureRepository(workspace.path('ar_capture')),
    stitcher: FakeStitcher(),
    stationId: sessionId,
    normalize: (Uint8List bytes) async =>
        NormalizedJpeg(bytes: bytes, width: 1, height: 1),
    sessions: harness.store,
    userId: userId,
    propertyId: propertyId,
  );

  test('restores the targets a previous launch saved', () async {
    await harness.store.createSession(
      sessionId: 'sphere-1',
      userId: 'user-1',
      propertyId: 12,
    );
    for (var id = 1; id <= 5; id++) {
      final file = await workspace.writeFile('t$id.jpg', syntheticJpeg(size: 1024));
      await harness.store.saveFrame(
        frameFor('sphere-1', id, imagePath: file.path),
      );
    }

    final controller = await controllerFor('sphere-1');
    addTearDown(controller.dispose);

    await controller.restoreFromStore();

    expect(controller.capturedCount, 5);
    expect(controller.targets.where((t) => t.captured).map((t) => t.spec.targetId),
        <int>[1, 2, 3, 4, 5]);
    // The next target in the stitch path is the first uncaptured one, so the
    // guide arrow does not send the user back to target 1.
    expect(controller.guideTargetId, 6);
    expect(controller.sessionId, 'sphere-1');
    expect(controller.propertyId, 12);
  });

  test('does not claim a target whose JPEG has disappeared', () async {
    await harness.store.createSession(sessionId: 'sphere-1');
    final kept = await workspace.writeFile('kept.jpg', syntheticJpeg(size: 1024));
    final gone = workspace.path('gone.jpg');
    await harness.store.saveFrame(
      frameFor('sphere-1', 1, imagePath: kept.path),
    );
    await harness.store.saveFrame(frameFor('sphere-1', 2, imagePath: gone));

    final controller = await controllerFor('sphere-1');
    addTearDown(controller.dispose);
    await controller.restoreFromStore();

    // One row is bookkeeping; the other is evidence. Only the evidence counts.
    expect(controller.capturedCount, 1);
    expect(await harness.store.countFrames('sphere-1'), 2);
  });

  test('a fully captured session reopens as complete with its panorama', () async {
    await harness.store.createSession(sessionId: 'sphere-full');
    for (var id = 1; id <= 38; id++) {
      final file = await workspace.writeFile('f$id.jpg', syntheticJpeg(size: 1024));
      await harness.store.saveFrame(
        frameFor('sphere-full', id, imagePath: file.path),
      );
    }
    final panorama = await workspace.writeFile('panorama.jpg', syntheticJpeg());
    await harness.store.savePanorama(
      sessionId: 'sphere-full',
      localPanoramaPath: panorama.path,
      status: PanoramaGenerationStatus.ready,
    );

    final controller = await controllerFor('sphere-full');
    addTearDown(controller.dispose);
    await controller.restoreFromStore();

    expect(controller.capturedCount, kSphereTargetCount);
    expect(controller.phase, SphereCapturePhase.complete);
    // Reopening must not require re-stitching: the panorama is already on disk
    // and the viewer opens the local file.
    expect(controller.panoramaPath, panorama.path);
    expect(controller.syncRecord?.status, PanoramaSyncStatus.pending);
    expect(controller.isUploaded, isFalse);
  });

  test('restoring an empty session changes nothing', () async {
    await harness.store.createSession(sessionId: 'sphere-empty');
    final controller = await controllerFor('sphere-empty');
    addTearDown(controller.dispose);

    await controller.restoreFromStore();

    expect(controller.capturedCount, 0);
    expect(controller.phase, SphereCapturePhase.idle);
  });
}

// ── fakes ──────────────────────────────────────────────────────────────────
//
// `SphereCamera` and `RotationSource` are already abstract for exactly this
// reason (see their doc comments); these are the smallest possible
// implementations that satisfy them.

class FakeCamera implements SphereCamera {
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
  Future<Uint8List> takePicture() async => Uint8List(0);

  @override
  Future<void> close() async => _open = false;

  @override
  Future<void> ensurePreviewReady({
    Duration timeout = const Duration(seconds: 3),
  }) async {}
}

class FakeRotation implements RotationSource {
  final StreamController<Quat> _controller = StreamController<Quat>.broadcast();

  @override
  Stream<Quat> get rotations => _controller.stream;

  @override
  Vec3 get worldUp => Vec3.unitY;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    await _controller.close();
  }
}

class FakeStitcher implements PanoramaStitcher {
  @override
  Future<StitchResult> stitchFrames(
    List<String> imagePaths, {
    void Function(String stage)? onStage,
  }) async => const StitchResult.failure('The fake stitcher never stitches.');
}
