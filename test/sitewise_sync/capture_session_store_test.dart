import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/sitewise_schema.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';

import 'support/test_support.dart';

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

  group('schema', () {
    test('records its version and enforces foreign keys', () async {
      expect(await harness.database.recordedVersion(), kSitewiseSchemaVersion);
      final pragma = await harness.database.db.rawQuery('PRAGMA foreign_keys');
      expect(pragma.first.values.first, 1);
    });

    test('rejects a 39th target id', () async {
      await harness.store.createSession(sessionId: 's1');
      // The 38-target layout is a database fact, not just a UI constant: a bug
      // that tried to save target 39 must fail loudly here rather than create a
      // frame the stitcher will never read.
      expect(
        () => harness.store.saveFrame(
          frameFor('s1', 39, imagePath: workspace.path('t39.jpg')),
        ),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('sessions', () {
    test('creates a session with the required target count', () async {
      final session = await harness.store.createSession(
        sessionId: 'sphere-1',
        userId: 'user-abc',
        propertyId: 42,
      );
      expect(session.sessionId, 'sphere-1');
      expect(session.userId, 'user-abc');
      expect(session.propertyId, 42);
      expect(session.requiredTargetCount, kSphereTargetCount);
      expect(session.requiredTargetCount, 38);
      expect(session.status, CaptureSessionStatus.draft);
      expect(session.panoramaStatus, PanoramaGenerationStatus.pending);
      expect(session.hasPanorama, isFalse);
    });

    test('re-creating an existing session does not reset it', () async {
      await harness.store.createSession(sessionId: 'sphere-1');
      await harness.store.saveFrame(
        frameFor('sphere-1', 1, imagePath: workspace.path('t01.jpg')),
      );
      final again = await harness.store.createSession(sessionId: 'sphere-1');
      // A second Start tap, or a screen rebuilt after a rotation, must not throw
      // away the frames already recorded.
      expect(again.status, CaptureSessionStatus.capturing);
      expect(await harness.store.countFrames('sphere-1'), 1);
    });

    test('lists sessions newest first and filters by account', () async {
      await harness.store.createSession(sessionId: 'a', userId: 'u1');
      await harness.store.createSession(sessionId: 'b', userId: 'u2');
      final all = await harness.store.listSessions();
      expect(all.length, 2);
      final mine = await harness.store.listSessions(userId: 'u1');
      expect(mine.single.sessionId, 'a');
    });

    test('finds the newest resumable session', () async {
      final clock = _MutableClock(DateTime.utc(2026, 11, 16, 9));
      final timed = await openTestStore(clock: clock.call);
      addTearDown(timed.close);
      await timed.store.createSession(sessionId: 'old');
      await timed.store.saveFrame(
        frameFor('old', 1, imagePath: workspace.path('old/t01.jpg')),
      );
      clock.advance(const Duration(minutes: 5));
      await timed.store.createSession(sessionId: 'new');
      await timed.store.saveFrame(
        frameFor('new', 1, imagePath: workspace.path('new/t01.jpg')),
      );
      final resumable = await timed.store.findResumableSession();
      expect(resumable, isNotNull);
      expect(resumable!.sessionId, 'new');
    });

    test('a session id containing SQL punctuation is stored literally', () async {
      const hostile = "sphere-1'; DROP TABLE capture_sessions; --";
      final created = await harness.store.createSession(sessionId: hostile);
      expect(created.sessionId, hostile);
      final read = await harness.store.getSession(hostile);
      expect(read, isNotNull);
      // The table is still there: the id was bound as a parameter, not spliced.
      expect(await harness.store.listSessions(), hasLength(1));
    });
  });

  group('frames', () {
    test('saves and reloads all 38 targets in order', () async {
      await harness.store.createSession(sessionId: 's1');
      for (var id = 38; id >= 1; id--) {
        await harness.store.saveFrame(
          frameFor('s1', id, imagePath: workspace.path('frames/t$id.jpg')),
        );
      }
      final frames = await harness.store.loadFrames('s1');
      expect(frames, hasLength(38));
      expect(frames.first.targetId, 1);
      expect(frames.last.targetId, 38);
      expect(await harness.store.countFrames('s1'), 38);
    });

    test('a retake replaces the row instead of appending', () async {
      await harness.store.createSession(sessionId: 's1');
      await harness.store.saveFrame(
        frameFor('s1', 7, imagePath: workspace.path('first.jpg')),
      );
      await harness.store.saveFrame(
        frameFor('s1', 7, imagePath: workspace.path('retake.jpg')),
      );
      final frames = await harness.store.loadFrames('s1');
      expect(frames, hasLength(1));
      expect(frames.single.imagePath, workspace.path('retake.jpg'));
    });

    test('keeps the exact path that was written', () async {
      await harness.store.createSession(sessionId: 's1');
      final path = workspace.path('frames/t01.jpg');
      await harness.store.saveFrame(frameFor('s1', 1, imagePath: path));
      final frames = await harness.store.loadFrames('s1');
      // The stitcher reads these paths directly, so any rewriting here would
      // break panorama generation.
      expect(frames.single.imagePath, path);
      expect(frames.single.toCaptureRecord().imagePath, path);
    });

    test('round-trips the camera metadata the stitcher needs', () async {
      await harness.store.createSession(sessionId: 's1');
      await harness.store.saveFrame(
        frameFor('s1', 5, imagePath: workspace.path('t05.jpg')),
      );
      final frame = (await harness.store.loadFrames('s1')).single;
      expect(frame.imageWidth, 3072);
      expect(frame.imageHeight, 4096);
      expect(frame.sourceImageWidth, 3072);
      expect(frame.alignmentErrorDeg, closeTo(1.5, 1e-9));
      expect(frame.toleranceDeg, closeTo(5, 1e-9));
      expect(frame.cameraOrientation.w, 1);
      final record = frame.toCaptureRecord();
      expect(record.stationId, 's1');
      expect(record.targetId, 5);
      expect(record.imageFormat, 'jpeg');
    });

    test('deleting a session cascades to its frames', () async {
      await harness.store.createSession(sessionId: 's1');
      await harness.store.saveFrame(
        frameFor('s1', 1, imagePath: workspace.path('t01.jpg')),
      );
      await harness.store.deleteSession('s1');
      final rows = await harness.database.db.query('captured_frames');
      expect(rows, isEmpty);
    });
  });

  group('panorama and queue', () {
    test('a ready panorama queues itself for upload', () async {
      await harness.store.createSession(sessionId: 's1', propertyId: 9);
      final panorama = workspace.path('panorama.jpg');
      final record = await harness.store.savePanorama(
        sessionId: 's1',
        localPanoramaPath: panorama,
        status: PanoramaGenerationStatus.ready,
      );
      expect(record, isNotNull);
      expect(record!.status, PanoramaSyncStatus.pending);
      expect(record.localPanoramaPath, panorama);
      expect(record.propertyId, 9);
      expect(record.retryCount, 0);

      final session = await harness.store.getSession('s1');
      expect(session!.panoramaStatus, PanoramaGenerationStatus.ready);
      expect(session.status, CaptureSessionStatus.panoramaReady);
      expect(session.hasPanorama, isTrue);
    });

    test('a failed stitch queues nothing', () async {
      await harness.store.createSession(sessionId: 's1');
      final record = await harness.store.savePanorama(
        sessionId: 's1',
        localPanoramaPath: null,
        status: PanoramaGenerationStatus.failed,
        error: 'Only 37/38 photographs are saved.',
      );
      expect(record, isNull);
      final session = await harness.store.getSession('s1');
      expect(session!.status, CaptureSessionStatus.panoramaFailed);
      expect(session.lastError, 'Only 37/38 photographs are saved.');
      expect(await harness.store.listPendingUploads(), isEmpty);
    });

    test('marking pending is idempotent', () async {
      await harness.store.createSession(sessionId: 's1', propertyId: 3);
      await harness.store.savePanorama(
        sessionId: 's1',
        localPanoramaPath: workspace.path('p.jpg'),
        status: PanoramaGenerationStatus.ready,
      );
      await harness.store.markUploadPending('s1');
      await harness.store.markUploadPending('s1');
      final pending = await harness.store.listPendingUploads();
      expect(pending, hasLength(1));
    });

    test('a confirmed upload survives a regenerated panorama', () async {
      await harness.store.createSession(sessionId: 's1', propertyId: 3);
      await harness.store.savePanorama(
        sessionId: 's1',
        localPanoramaPath: workspace.path('p.jpg'),
        status: PanoramaGenerationStatus.ready,
      );
      await harness.store.markUploadSucceeded(
        sessionId: 's1',
        jobId: 'pano_s1',
        remoteObjectPath: 'properties/3/sessions/s1/panorama.jpg',
        propertyId: 3,
      );
      // Re-stitching writes the panorama again. The cloud copy is still valid —
      // the object path is deterministic — so the queue must not re-arm itself.
      final again = await harness.store.savePanorama(
        sessionId: 's1',
        localPanoramaPath: workspace.path('p.jpg'),
        status: PanoramaGenerationStatus.ready,
      );
      expect(again!.status, PanoramaSyncStatus.uploaded);
      expect(again.jobId, 'pano_s1');
      expect(
        again.remoteObjectPath,
        'properties/3/sessions/s1/panorama.jpg',
      );
      expect(await harness.store.listPendingUploads(), isEmpty);
    });

    test('a failure increments the retry count and stays queued', () async {
      await harness.store.createSession(sessionId: 's1');
      await harness.store.savePanorama(
        sessionId: 's1',
        localPanoramaPath: workspace.path('p.jpg'),
        status: PanoramaGenerationStatus.ready,
      );
      await harness.store.markUploadFailed(
        sessionId: 's1',
        error: 'No connection.',
      );
      final failed = await harness.store.getPanorama('s1');
      expect(failed!.status, PanoramaSyncStatus.failed);
      expect(failed.retryCount, 1);
      expect(failed.lastError, 'No connection.');
      expect(await harness.store.listPendingUploads(), hasLength(1));

      await harness.store.markUploadFailed(
        sessionId: 's1',
        error: 'Still offline.',
      );
      expect((await harness.store.getPanorama('s1'))!.retryCount, 2);
    });

    test('a non-retryable failure blocks instead of queueing', () async {
      await harness.store.createSession(sessionId: 's1');
      await harness.store.savePanorama(
        sessionId: 's1',
        localPanoramaPath: workspace.path('p.jpg'),
        status: PanoramaGenerationStatus.ready,
      );
      await harness.store.markUploadFailed(
        sessionId: 's1',
        error: 'The panorama file is incomplete.',
        retryable: false,
      );
      expect(
        (await harness.store.getPanorama('s1'))!.status,
        PanoramaSyncStatus.blocked,
      );
      // A blocked row is not in the automatic queue: retrying it on a timer
      // would never succeed.
      expect(await harness.store.listPendingUploads(), isEmpty);
    });

    test('two rows cannot claim the same cloud job', () async {
      await harness.store.createSession(sessionId: 'a');
      await harness.store.createSession(sessionId: 'b');
      for (final id in <String>['a', 'b']) {
        await harness.store.savePanorama(
          sessionId: id,
          localPanoramaPath: workspace.path('$id.jpg'),
          status: PanoramaGenerationStatus.ready,
        );
      }
      await harness.store.markUploadSucceeded(
        sessionId: 'a',
        jobId: 'pano_same',
        remoteObjectPath: 'properties/1/sessions/a/panorama.jpg',
        propertyId: 1,
      );
      // The partial unique index is the guard against one panorama being
      // uploaded twice under two local rows.
      expect(
        () => harness.store.markUploadSucceeded(
          sessionId: 'b',
          jobId: 'pano_same',
          remoteObjectPath: 'properties/1/sessions/b/panorama.jpg',
          propertyId: 1,
        ),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('upload lease', () {
    test('only one caller can hold the lease', () async {
      await harness.store.createSession(sessionId: 's1');
      await harness.store.savePanorama(
        sessionId: 's1',
        localPanoramaPath: workspace.path('p.jpg'),
        status: PanoramaGenerationStatus.ready,
      );
      expect(await harness.store.claimUpload('s1'), isTrue);
      // The second concurrent attempt must be refused rather than uploading the
      // same bytes twice.
      expect(await harness.store.claimUpload('s1'), isFalse);
      await harness.store.releaseUpload('s1');
      expect(await harness.store.claimUpload('s1'), isTrue);
    });

    test('an abandoned lease is reclaimed after the timeout', () async {
      final clock = _MutableClock(DateTime.utc(2026, 11, 16, 12));
      final store = await openTestStore(clock: clock.call);
      addTearDown(store.close);
      await store.store.createSession(sessionId: 's1');
      await store.store.savePanorama(
        sessionId: 's1',
        localPanoramaPath: workspace.path('p.jpg'),
        status: PanoramaGenerationStatus.ready,
      );
      expect(await store.store.claimUpload('s1'), isTrue);
      // A process killed mid-upload leaves the lease behind; without expiry the
      // session would be stuck forever.
      clock.advance(PanoramaSyncRecord.leaseTimeout + const Duration(minutes: 1));
      expect(await store.store.claimUpload('s1'), isTrue);
    });
  });

  group('deletion', () {
    test('returns the file paths and deletes no files', () async {
      final file = await workspace.writeFile('frames/t01.jpg', <int>[1, 2, 3]);
      final panorama = await workspace.writeFile('panorama.jpg', <int>[4, 5, 6]);
      await harness.store.createSession(sessionId: 's1');
      await harness.store.saveFrame(
        frameFor('s1', 1, imagePath: file.path),
      );
      await harness.store.savePanorama(
        sessionId: 's1',
        localPanoramaPath: panorama.path,
        status: PanoramaGenerationStatus.ready,
      );

      final paths = await harness.store.deleteSession('s1');
      expect(paths, containsAll(<String>[file.path, panorama.path]));
      // Deleting metadata must never destroy the photographs. The caller does
      // that only after an explicit confirmation.
      expect(await file.exists(), isTrue);
      expect(await panorama.exists(), isTrue);
      expect(await harness.store.getSession('s1'), isNull);
      expect(await harness.store.listPendingUploads(), isEmpty);
    });
  });
}

class _MutableClock {
  _MutableClock(this._now);

  DateTime _now;

  DateTime call() => _now;

  void advance(Duration by) => _now = _now.add(by);
}
