import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/sitewise_sync/application/panorama_sync_service.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/cloud/panorama_cloud_gateway.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/cloud/sitewise_auth.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/app_role.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';

import 'support/test_support.dart';

void main() {
  late TestStore harness;
  late TempWorkspace workspace;
  late FakeGateway gateway;
  late FakeAuth auth;
  late PanoramaSyncService service;
  late File panoramaFile;

  setUp(() async {
    harness = await openTestStore();
    workspace = await TempWorkspace.create();
    gateway = FakeGateway();
    auth = FakeAuth();
    service = PanoramaSyncService(
      store: harness.store,
      gateway: gateway,
      auth: auth,
    );
    panoramaFile = await workspace.writeFile('panorama.jpg', syntheticJpeg());
  });

  tearDown(() async {
    await harness.close();
    await workspace.dispose();
  });

  /// A finished 38-target session with a stitched panorama on disk.
  Future<void> seedSession({
    String sessionId = 'sphere-1',
    int? propertyId = 7,
    String? panoramaPath,
  }) async {
    await harness.store.createSession(
      sessionId: sessionId,
      userId: auth.account?.userId,
      propertyId: propertyId,
    );
    for (var id = 1; id <= 38; id++) {
      await harness.store.saveFrame(
        frameFor(
          sessionId,
          id,
          imagePath: workspace.path('frames/t$id.jpg'),
        ),
      );
    }
    await harness.store.markSessionStatus(
      sessionId: sessionId,
      status: CaptureSessionStatus.complete,
    );
    await harness.store.savePanorama(
      sessionId: sessionId,
      localPanoramaPath: panoramaPath ?? panoramaFile.path,
      status: PanoramaGenerationStatus.ready,
    );
  }

  group('successful upload', () {
    test('stores the object, records the job and marks the row uploaded', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession();

      final attempt = await service.syncSession('sphere-1');

      expect(attempt.outcome, SyncOutcome.uploaded);
      expect(attempt.succeeded, isTrue);
      expect(gateway.uploadedPaths, hasLength(1));
      // The object path is the contract with Storage: property folder, session
      // folder, fixed file name.
      expect(
        gateway.uploadedPaths.single,
        'properties/7/sessions/sphere-1/panorama.jpg',
      );
      // The lifecycle goes queued -> processing -> done, and `done` is the only
      // status that carries a Storage path.
      expect(gateway.jobStatuses, <PanoJobStatus>[
        PanoJobStatus.queued,
        PanoJobStatus.processing,
        PanoJobStatus.done,
      ]);
      expect(gateway.lastPanoramaPath, 'properties/7/sessions/sphere-1/panorama.jpg');
      expect(gateway.lastPropertyId, 7);
      expect(gateway.lastOwner, auth.account!.userId);

      final record = await harness.store.getPanorama('sphere-1');
      expect(record!.status, PanoramaSyncStatus.uploaded);
      expect(record.jobId, 'pano_sphere-1');
      expect(record.remoteObjectPath, 'properties/7/sessions/sphere-1/panorama.jpg');
      expect(record.lastSuccessAt, isNotNull);
      expect(await harness.store.listPendingUploads(), isEmpty);
    });

    test('sends a manifest of targets, never device paths', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession();
      await service.syncSession('sphere-1');

      final frames = gateway.lastFrames!;
      expect(frames['targetCount'], 38);
      final targets = frames['targets']! as List<Map<String, Object?>>;
      expect(targets, hasLength(38));
      expect(targets.first['targetId'], 1);
      expect(targets.last['targetId'], 38);
      // A device path in a cloud-readable column would leak the phone's storage
      // layout and mean nothing to the server.
      final serialised = targets.toString();
      expect(serialised.contains(workspace.directory.path), isFalse);
      expect(serialised.contains('.jpg'), isFalse);
    });

    test('does nothing when the panorama is already uploaded', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession();
      await service.syncSession('sphere-1');
      gateway.reset();

      final second = await service.syncSession('sphere-1');
      expect(second.outcome, SyncOutcome.nothingToDo);
      expect(gateway.uploadedPaths, isEmpty);
    });
  });

  group('offline and retry', () {
    test('a network failure queues the panorama and keeps the file', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession();
      gateway.failOnUpload = const PanoramaCloudException(
        PanoramaUploadFailure.network,
        'No connection to SiteWise.',
      );

      final attempt = await service.syncSession('sphere-1');

      expect(attempt.outcome, SyncOutcome.failed);
      expect(attempt.failure, PanoramaUploadFailure.network);
      final record = await harness.store.getPanorama('sphere-1');
      expect(record!.status, PanoramaSyncStatus.failed);
      expect(record.retryCount, 1);
      expect(record.lastError, contains('No connection'));
      // The whole point of local-first: a failed upload costs nothing.
      expect(await panoramaFile.exists(), isTrue);
      expect(await harness.store.listPendingUploads(), hasLength(1));
    });

    test('an explicit retry succeeds after the network returns', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession();
      gateway.failOnUpload = const PanoramaCloudException(
        PanoramaUploadFailure.network,
        'No connection to SiteWise.',
      );
      await service.syncSession('sphere-1');

      gateway.failOnUpload = null;
      final retry = await service.retry('sphere-1');

      expect(retry.outcome, SyncOutcome.uploaded);
      // Retrying must not create a second object: the path is deterministic.
      expect(gateway.uploadedPaths.toSet(), hasLength(1));
      expect((await harness.store.getPanorama('sphere-1'))!.retryCount, 1);
    });

    test('an object that stored but whose job update failed is retried', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession();
      // The bytes reach Storage, then the `done` write fails. This is the
      // nastiest case: the cloud has the file but the job says otherwise.
      gateway.failOnDone = const PanoramaCloudException(
        PanoramaUploadFailure.jobRecord,
        'The panorama job could not be recorded.',
      );

      final first = await service.syncSession('sphere-1');
      expect(first.outcome, SyncOutcome.failed);
      expect(first.failure, PanoramaUploadFailure.jobRecord);
      expect(first.remoteObjectPath, 'properties/7/sessions/sphere-1/panorama.jpg');
      expect(
        (await harness.store.getPanorama('sphere-1'))!.status,
        PanoramaSyncStatus.failed,
      );

      gateway.failOnDone = null;
      final second = await service.retry('sphere-1');
      expect(second.outcome, SyncOutcome.uploaded);
      // The same key is written again — one object, not two.
      expect(gateway.uploadedPaths.toSet(), hasLength(1));
    });

    test('a concurrent attempt for the same session is skipped', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession();
      // Simulate an upload already in flight.
      expect(await harness.store.claimUpload('sphere-1'), isTrue);

      final attempt = await service.syncSession('sphere-1');

      expect(attempt.outcome, SyncOutcome.skipped);
      expect(gateway.uploadedPaths, isEmpty);
    });

    test('the queue drains pending work and leaves a live lease alone', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession(sessionId: 'a');
      await seedSession(sessionId: 'b');
      await harness.store.claimUpload('a');

      final results = await service.syncPending();

      // 'a' is mid-upload, so it is not in the pending list at all; the queue
      // must not disturb a lease it does not own.
      expect(results, hasLength(1));
      expect(results.single.sessionId, 'b');
      expect(results.single.outcome, SyncOutcome.uploaded);
      expect(
        (await harness.store.getPanorama('a'))!.status,
        PanoramaSyncStatus.uploading,
      );
    });
  });

  group('authorisation', () {
    test('refuses to upload without a session', () async {
      await seedSession();
      final attempt = await service.syncSession('sphere-1');

      expect(attempt.outcome, SyncOutcome.blocked);
      expect(attempt.failure, PanoramaUploadFailure.unauthenticated);
      expect(gateway.calls, isEmpty);
      expect(
        (await harness.store.getPanorama('sphere-1'))!.status,
        PanoramaSyncStatus.blocked,
      );
      expect(await panoramaFile.exists(), isTrue);
    });

    test('refuses an expired session without touching the network', () async {
      auth.account = FakeAuth.expiredAccount();
      await seedSession();

      final attempt = await service.syncSession('sphere-1');

      expect(attempt.outcome, SyncOutcome.blocked);
      expect(attempt.failure, PanoramaUploadFailure.sessionExpired);
      expect(gateway.calls, isEmpty);
    });

    test('refuses an unassociated panorama', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession(propertyId: null);

      final attempt = await service.syncSession('sphere-1');

      // No property means no legitimate folder. Guessing one would put a user's
      // room inside another owner's property.
      expect(attempt.outcome, SyncOutcome.blocked);
      expect(attempt.failure, PanoramaUploadFailure.propertyNotAssociated);
      expect(gateway.calls, isEmpty);
    });

    test('stops before uploading when the server refuses the association', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession();
      gateway.failOnQueued = const PanoramaCloudException(
        PanoramaUploadFailure.propertyNotAuthorized,
        'This account is not authorised for that property.',
      );

      final attempt = await service.syncSession('sphere-1');

      expect(attempt.outcome, SyncOutcome.blocked);
      expect(attempt.failure, PanoramaUploadFailure.propertyNotAuthorized);
      // The job row is the authorisation gate: nothing may be stored when it is
      // refused.
      expect(gateway.uploadedPaths, isEmpty);
      expect(gateway.calls, <String>['upsertJob']);
    });

    test('signing in again unblocks and completes the upload', () async {
      await seedSession();
      await service.syncSession('sphere-1');
      expect(
        (await harness.store.getPanorama('sphere-1'))!.status,
        PanoramaSyncStatus.blocked,
      );

      auth.account = FakeAuth.liveAccount();
      final attempt = await service.retry('sphere-1');

      expect(attempt.outcome, SyncOutcome.uploaded);
    });
  });

  group('local file integrity', () {
    test('refuses a missing panorama file', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession(panoramaPath: workspace.path('gone.jpg'));

      final attempt = await service.syncSession('sphere-1');

      expect(attempt.outcome, SyncOutcome.blocked);
      expect(attempt.failure, PanoramaUploadFailure.missingLocalFile);
      expect(gateway.uploadedPaths, isEmpty);
    });

    test('refuses a truncated panorama file', () async {
      auth.account = FakeAuth.liveAccount();
      final truncated = await workspace.writeFile(
        'truncated.jpg',
        syntheticJpeg().sublist(0, 9 * 1024 - 2),
      );
      await seedSession(panoramaPath: truncated.path);

      final attempt = await service.syncSession('sphere-1');

      expect(attempt.outcome, SyncOutcome.blocked);
      expect(attempt.failure, PanoramaUploadFailure.unreadableLocalFile);
      expect(gateway.uploadedPaths, isEmpty);
    });
  });

  group('viewing', () {
    test('reports processing before the upload is confirmed', () async {
      await seedSession();
      final view = await service.viewPanorama('sphere-1');
      expect(view.state, PanoramaViewState.processing);
      expect(view.canOpen, isFalse);
    });

    test('reports failed with the reason when blocked', () async {
      await seedSession();
      await service.syncSession('sphere-1');
      final view = await service.viewPanorama('sphere-1');
      expect(view.state, PanoramaViewState.failed);
      expect(view.message, contains('Sign in'));
    });

    test('mints a signed URL only after the upload is done', () async {
      auth.account = FakeAuth.liveAccount();
      await seedSession();
      await service.syncSession('sphere-1');

      final view = await service.viewPanorama('sphere-1');
      expect(view.state, PanoramaViewState.ready);
      expect(view.signedUrl, contains('signed'));
      expect(view.localPath, panoramaFile.path);
    });

    test('reports not captured for an unknown session', () async {
      final view = await service.viewPanorama('nope');
      expect(view.state, PanoramaViewState.notCaptured);
    });
  });
}

// ── fakes ──────────────────────────────────────────────────────────────────

class FakeAuth implements SitewiseAuth {
  SitewiseAccount? account;

  static SitewiseAccount liveAccount() => SitewiseAccount(
    userId: 'user-1',
    email: 'owner@example.com',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    role: AppRole.owner,
  );

  static SitewiseAccount expiredAccount() => SitewiseAccount(
    userId: 'user-1',
    email: 'owner@example.com',
    expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
    role: AppRole.owner,
  );

  @override
  Future<SitewiseAccount?> currentAccount() async => account;

  @override
  Stream<SitewiseAccount?> get changes => const Stream<SitewiseAccount?>.empty();

  @override
  Future<SitewiseAccount> signInWithPassword({
    required String email,
    required String password,
  }) async => account = liveAccount();

  @override
  Future<void> signOut() async => account = null;

  @override
  Future<AppRole?> fetchRole(String userId) async => account?.role;
}

class FakeGateway implements PanoramaCloudGateway {
  final List<String> calls = <String>[];
  final List<PanoJobStatus> jobStatuses = <PanoJobStatus>[];
  final List<String> uploadedPaths = <String>[];

  PanoramaCloudException? failOnQueued;
  PanoramaCloudException? failOnProcessing;
  PanoramaCloudException? failOnDone;
  PanoramaCloudException? failOnUpload;

  Map<String, Object?>? lastFrames;
  String? lastPanoramaPath;
  int? lastPropertyId;
  String? lastOwner;
  int _jobWrites = 0;

  void reset() {
    calls.clear();
    jobStatuses.clear();
    uploadedPaths.clear();
    lastFrames = null;
    lastPanoramaPath = null;
    _jobWrites = 0;
  }

  @override
  Future<void> upsertJob({
    required String jobId,
    required String sessionId,
    required String userId,
    required int propertyId,
    required PanoJobStatus status,
    required Map<String, Object?> frames,
    String? panoramaPath,
    String? error,
  }) async {
    calls.add('upsertJob');
    _jobWrites++;
    final failure = switch (status) {
      PanoJobStatus.queued => failOnQueued,
      PanoJobStatus.processing => failOnProcessing,
      PanoJobStatus.done => failOnDone,
      PanoJobStatus.error => null,
    };
    if (failure != null) throw failure;
    jobStatuses.add(status);
    lastFrames = frames;
    lastPropertyId = propertyId;
    lastOwner = userId;
    if (panoramaPath != null) lastPanoramaPath = panoramaPath;
  }

  @override
  Future<void> uploadPanoramaObject({
    required String objectPath,
    required File file,
  }) async {
    calls.add('upload');
    if (failOnUpload != null) throw failOnUpload!;
    uploadedPaths.add(objectPath);
  }

  @override
  Future<String?> createSignedUrl({
    required String objectPath,
    Duration ttl = const Duration(minutes: 10),
  }) async {
    calls.add('signedUrl');
    return 'https://example.supabase.co/storage/v1/object/sign/$objectPath'
        '?token=signed';
  }

  int get jobWrites => _jobWrites;
}
