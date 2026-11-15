import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/legacy_session_importer.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';

import 'support/test_support.dart';

/// The pre-SQLite layout this importer has to survive:
///
/// ```
/// ar_capture/<stationId>/
///   station.json      { stationId, total, ... }
///   records.json      [ CaptureRecord.toJson(), ... ]
///   frames/t01.jpg …
///   panorama.jpg
///   panorama.json     { panoramaPath, frameCount, ... }
/// ```
void main() {
  late TestStore harness;
  late TempWorkspace workspace;
  late String root;
  late FileCaptureRepository repository;
  late LegacySessionImporter importer;

  setUp(() async {
    harness = await openTestStore();
    workspace = await TempWorkspace.create();
    root = workspace.path('ar_capture');
    repository = FileCaptureRepository(root);
    importer = LegacySessionImporter(
      repository: repository,
      store: harness.store,
    );
  });

  tearDown(() async {
    await harness.close();
    await workspace.dispose();
  });

  Future<void> writeStation({
    required String stationId,
    required int total,
    required int captured,
    bool withPanorama = false,
  }) async {
    final stationDir = '$root${Platform.pathSeparator}$stationId';
    await Directory(stationDir).create(recursive: true);
    await File('$stationDir${Platform.pathSeparator}station.json').writeAsString(
      jsonEncode(<String, Object?>{
        'stationId': stationId,
        'referencePosition': <double>[0, 0, 0],
        'referenceOrientation': <double>[0, 0, 0, 1],
        'createdAt': DateTime.utc(2026, 10, 1).toIso8601String(),
        'trackingStatus': 'tracking',
        'capturedCount': captured,
        'total': total,
      }),
    );

    final records = <Map<String, Object?>>[];
    for (var targetId = 1; targetId <= captured; targetId++) {
      final relative = 'frames/t${targetId.toString().padLeft(2, '0')}.jpg';
      final file = await workspace.writeFile(
        'ar_capture/$stationId/$relative',
        syntheticJpeg(size: 1024),
      );
      records.add(<String, Object?>{
        'stationId': stationId,
        'targetId': targetId,
        'imagePath': file.path,
        'capturedAt': DateTime.utc(2026, 10, 1, 10, targetId).toIso8601String(),
        'targetYawDegrees': ((targetId - 1) % 12) * 30.0,
        'targetPitchDegrees': 0,
        'cameraPosition': <double>[0, 0, 0],
        'cameraOrientation': <double>[0, 0, 0, 1],
        'alignmentErrorDeg': 1.0,
        'anchored': false,
        'imageWidth': 3072,
        'imageHeight': 4096,
        'sourceImageWidth': 3072,
        'sourceImageHeight': 4096,
      });
    }
    await File('$stationDir${Platform.pathSeparator}records.json').writeAsString(
      jsonEncode(records),
    );

    if (withPanorama) {
      final panorama = await workspace.writeFile(
        'ar_capture/$stationId/panorama.jpg',
        syntheticJpeg(),
      );
      await File(
        '$stationDir${Platform.pathSeparator}panorama.json',
      ).writeAsString(
        jsonEncode(<String, Object?>{
          'stationId': stationId,
          'panoramaPath': panorama.path,
          'frameCount': captured,
          'generatedAt': DateTime.utc(2026, 10, 1, 11).toIso8601String(),
        }),
      );
    }
  }

  test('imports a completed station with its panorama', () async {
    await writeStation(
      stationId: 'sphere-old',
      total: 38,
      captured: 38,
      withPanorama: true,
    );

    final report = await importer.importAll();

    expect(report.stationsScanned, 1);
    expect(report.sessionsImported, 1);
    expect(report.framesImported, 38);
    expect(report.panoramasImported, 1);
    expect(report.skipped, isEmpty);

    final session = await harness.store.getSession('sphere-old');
    expect(session, isNotNull);
    expect(session!.requiredTargetCount, 38);
    expect(session.status, CaptureSessionStatus.panoramaReady);
    expect(session.hasPanorama, isTrue);
    expect(await harness.store.countFrames('sphere-old'), 38);
  });

  test('imports a partially captured station as resumable', () async {
    await writeStation(stationId: 'sphere-partial', total: 38, captured: 5);

    await importer.importAll();

    final session = await harness.store.getSession('sphere-partial');
    // Five of 38 is `capturing`, which is what makes it appear in the resume
    // list rather than looking like a finished station.
    expect(session!.status, CaptureSessionStatus.capturing);
    expect(await harness.store.countFrames('sphere-partial'), 5);
  });

  test('running twice does not duplicate anything', () async {
    await writeStation(
      stationId: 'sphere-old',
      total: 38,
      captured: 38,
      withPanorama: true,
    );

    await importer.importAll();
    final second = await importer.importAll();

    expect(second.sessionsImported, 0);
    expect(second.framesImported, 0);
    expect(await harness.store.countFrames('sphere-old'), 38);
  });

  test('never deletes or rewrites the legacy files', () async {
    await writeStation(
      stationId: 'sphere-old',
      total: 38,
      captured: 3,
      withPanorama: false,
    );
    final recordsBefore = await File(
      '$root${Platform.pathSeparator}sphere-old${Platform.pathSeparator}records.json',
    ).readAsString();
    final frameBefore = await File(
      '$root${Platform.pathSeparator}sphere-old${Platform.pathSeparator}frames'
      '${Platform.pathSeparator}t01.jpg',
    ).readAsBytes();

    await importer.importAll();

    expect(
      await File(
        '$root${Platform.pathSeparator}sphere-old${Platform.pathSeparator}records.json',
      ).readAsString(),
      recordsBefore,
    );
    expect(
      await File(
        '$root${Platform.pathSeparator}sphere-old${Platform.pathSeparator}frames'
        '${Platform.pathSeparator}t01.jpg',
      ).readAsBytes(),
      frameBefore,
    );
  });

  test('a record whose JPEG has gone is not imported', () async {
    await writeStation(stationId: 'sphere-old', total: 38, captured: 3);
    await File(
      '$root${Platform.pathSeparator}sphere-old${Platform.pathSeparator}frames'
      '${Platform.pathSeparator}t02.jpg',
    ).delete();

    final report = await importer.importAll();

    // Two of three frames survive; a row for a missing file would make the app
    // claim progress the stitcher cannot honour.
    expect(report.framesImported, 2);
    final frames = await harness.store.loadFrames('sphere-old');
    expect(frames.map((CapturedFrame f) => f.targetId), <int>[1, 3]);
  });

  test('an empty store and no stations is a no-op', () async {
    final report = await importer.importAll();
    expect(report.stationsScanned, 0);
    expect(report.didAnything, isFalse);
    expect(await harness.store.listSessions(), isEmpty);
  });

  test('a 26-target legacy station keeps its own target count', () async {
    await writeStation(stationId: 'ar-legacy', total: 26, captured: 26);

    await importer.importAll();

    final session = await harness.store.getSession('ar-legacy');
    // The 3DoF flow is 38; an older AR station declares 26 in station.json and
    // must not be rewritten as 38, or it would look permanently incomplete.
    expect(session!.requiredTargetCount, 26);
    expect(session.status, CaptureSessionStatus.complete);
  });
}
