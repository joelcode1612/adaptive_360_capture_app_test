// ignore_for_file: prefer_initializing_formals
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:adaptive_360_capture_app/features/sitewise_sync/data/cloud/panorama_cloud_gateway.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/cloud/panorama_file_check.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/cloud/sitewise_auth.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/capture_session_store.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';

/// What one synchronisation attempt achieved.
enum SyncOutcome {
  /// The object is in Storage and `pano_jobs` says `done`.
  uploaded,

  /// Nothing to do: no panorama, or already uploaded.
  nothingToDo,

  /// A recoverable failure; the queue will try again after the backoff.
  failed,

  /// The user must act before this can succeed (sign in, restore access).
  blocked,

  /// Another attempt holds the lease, or the backoff has not elapsed.
  skipped,
}

/// The result of one attempt, in words the UI can show.
class SyncAttempt {
  const SyncAttempt({
    required this.sessionId,
    required this.outcome,
    required this.message,
    this.failure = PanoramaUploadFailure.none,
    this.remoteObjectPath,
    this.jobId,
  });

  final String sessionId;
  final SyncOutcome outcome;
  final String message;
  final PanoramaUploadFailure failure;
  final String? remoteObjectPath;
  final String? jobId;

  bool get succeeded => outcome == SyncOutcome.uploaded;

  @override
  String toString() => 'SyncAttempt($sessionId: ${outcome.name}) $message';
}

/// Uploads finished panoramas to Supabase Storage and records the job.
///
/// ## The invariant this class protects
///
/// **A failed upload never costs the user a capture.** Nothing here deletes a
/// local file, and nothing marks a session synchronised until Supabase has
/// confirmed the object *and* the `pano_jobs` row says `done`. The worst
/// outcome of any failure is a queue row that says "not yet".
///
/// ## Idempotency
///
/// Three separate guards, because a retry after a crash is the normal case:
///
/// 1. the object path is derived from `(property, session)`, and the upload uses
///    `upsert`, so a repeat writes the same bytes to the same key;
/// 2. the job id is derived from the session, so a repeat updates one row;
/// 3. a conditional `UPDATE` takes a lease, so two attempts cannot overlap.
class PanoramaSyncService {
  PanoramaSyncService({
    required CaptureSessionStore store,
    required PanoramaCloudGateway gateway,
    required SitewiseAuth auth,
    DateTime Function()? clock,
  }) : _store = store,
       _gateway = gateway,
       _auth = auth,
       _clock = clock ?? (() => DateTime.now().toUtc());

  final CaptureSessionStore _store;
  final PanoramaCloudGateway _gateway;
  final SitewiseAuth _auth;
  final DateTime Function() _clock;

  /// Uploads one session's panorama if it is due.
  ///
  /// [force] is the explicit "Retry" path: it re-arms a `blocked` row (so a user
  /// who has just signed back in is not stuck behind the block) and ignores the
  /// backoff. It still respects a live lease, because that guard exists to stop
  /// two uploads of the same file, not to throttle the user.
  Future<SyncAttempt> syncSession(String sessionId, {bool force = false}) async {
    final record = await _store.getPanorama(sessionId);
    if (record == null) {
      return SyncAttempt(
        sessionId: sessionId,
        outcome: SyncOutcome.nothingToDo,
        message: 'No panorama is waiting to be uploaded for this session.',
      );
    }
    if (record.status == PanoramaSyncStatus.uploaded) {
      return SyncAttempt(
        sessionId: sessionId,
        outcome: SyncOutcome.nothingToDo,
        message: 'This panorama is already in SiteWise.',
        remoteObjectPath: record.remoteObjectPath,
        jobId: record.jobId,
      );
    }
    if (!force && !record.isBackoffElapsed) {
      return SyncAttempt(
        sessionId: sessionId,
        outcome: SyncOutcome.skipped,
        message: 'Waiting before the next attempt.',
      );
    }
    if (force && record.status == PanoramaSyncStatus.blocked) {
      await _store.markUploadPending(sessionId);
    }

    // Authentication first: an anonymous attempt would only burn a round trip
    // and, worse, could be refused by RLS in a way that reads like a property
    // problem.
    final account = await _auth.currentAccount();
    if (account == null) {
      const message = 'Sign in to upload this panorama to SiteWise.';
      await _store.markUploadBlocked(sessionId: sessionId, reason: message);
      return SyncAttempt(
        sessionId: sessionId,
        outcome: SyncOutcome.blocked,
        failure: PanoramaUploadFailure.unauthenticated,
        message: message,
      );
    }
    if (account.isExpired) {
      const message =
          'Your SiteWise sign-in has expired. Sign in again to upload.';
      await _store.markUploadBlocked(sessionId: sessionId, reason: message);
      return SyncAttempt(
        sessionId: sessionId,
        outcome: SyncOutcome.blocked,
        failure: PanoramaUploadFailure.sessionExpired,
        message: message,
      );
    }

    final session = await _store.getSession(sessionId);
    final propertyId = record.propertyId ?? session?.propertyId;
    if (propertyId == null) {
      // Never upload an unassociated panorama: there is no folder that is
      // legitimately its own, and guessing one would put a user's room in
      // another owner's property.
      const message =
          'This capture is not linked to a property, so it stays on this '
          'device. Select the property before uploading.';
      await _store.markUploadBlocked(sessionId: sessionId, reason: message);
      return SyncAttempt(
        sessionId: sessionId,
        outcome: SyncOutcome.blocked,
        failure: PanoramaUploadFailure.propertyNotAssociated,
        message: message,
      );
    }

    final issue = await PanoramaFileCheck.inspect(record.localPanoramaPath);
    if (issue != PanoramaFileIssue.none) {
      final message = PanoramaFileCheck.describe(issue)!;
      // Not recoverable by retrying: the bytes on disk will not change.
      await _store.markUploadFailed(
        sessionId: sessionId,
        error: message,
        retryable: false,
      );
      return SyncAttempt(
        sessionId: sessionId,
        outcome: SyncOutcome.blocked,
        failure: issue == PanoramaFileIssue.missing
            ? PanoramaUploadFailure.missingLocalFile
            : PanoramaUploadFailure.unreadableLocalFile,
        message: message,
      );
    }

    if (!await _store.claimUpload(sessionId)) {
      return SyncAttempt(
        sessionId: sessionId,
        outcome: SyncOutcome.skipped,
        message: 'An upload for this session is already in progress.',
      );
    }

    final jobId = record.jobId ?? panoramaJobId(sessionId);
    final objectPath = record.remoteObjectPath ??
        panoramaObjectPath(propertyId: propertyId, sessionId: sessionId);
    final frames = await _store.loadFrames(sessionId);
    final manifest = buildFrameManifest(
      frames,
      targetCount: session?.requiredTargetCount ?? frames.length,
    );

    // Whether the server accepted the job row. Only once it has is it meaningful
    // to write an `error` status: before that, every write is refused for the
    // same reason and retrying the write just repeats the refusal.
    var jobAccepted = false;
    try {
      await _gateway.upsertJob(
        jobId: jobId,
        sessionId: sessionId,
        userId: account.userId,
        propertyId: propertyId,
        status: PanoJobStatus.queued,
        frames: manifest,
      );
      jobAccepted = true;

      await _gateway.upsertJob(
        jobId: jobId,
        sessionId: sessionId,
        userId: account.userId,
        propertyId: propertyId,
        status: PanoJobStatus.processing,
        frames: manifest,
      );

      await _gateway.uploadPanoramaObject(
        objectPath: objectPath,
        file: File(record.localPanoramaPath!),
      );

      // Only now — with the object confirmed stored — is the job `done`.
      await _gateway.upsertJob(
        jobId: jobId,
        sessionId: sessionId,
        userId: account.userId,
        propertyId: propertyId,
        status: PanoJobStatus.done,
        frames: manifest,
        panoramaPath: objectPath,
      );

      await _store.markUploadSucceeded(
        sessionId: sessionId,
        jobId: jobId,
        remoteObjectPath: objectPath,
        propertyId: propertyId,
      );
      debugPrint('SITEWISE_SYNC: uploaded $sessionId -> $objectPath');
      return SyncAttempt(
        sessionId: sessionId,
        outcome: SyncOutcome.uploaded,
        message: 'Panorama uploaded to SiteWise.',
        remoteObjectPath: objectPath,
        jobId: jobId,
      );
    } on PanoramaCloudException catch (error) {
      return _recordFailure(
        sessionId: sessionId,
        jobId: jobId,
        objectPath: objectPath,
        propertyId: propertyId,
        account: account,
        manifest: manifest,
        jobAccepted: jobAccepted,
        error: error,
      );
    } catch (error) {
      // A non-cloud exception (a file read that failed between the check and the
      // upload, say). Treated as recoverable so the queue tries again, and the
      // local file is untouched either way.
      await _store.markUploadFailed(
        sessionId: sessionId,
        error: 'The upload failed: $error',
      );
      return SyncAttempt(
        sessionId: sessionId,
        outcome: SyncOutcome.failed,
        failure: PanoramaUploadFailure.unknown,
        message: 'The upload failed and will be retried.',
      );
    }
  }

  Future<SyncAttempt> _recordFailure({
    required String sessionId,
    required String jobId,
    required String objectPath,
    required int propertyId,
    required SitewiseAccount account,
    required Map<String, Object?> manifest,
    required bool jobAccepted,
    required PanoramaCloudException error,
  }) async {
    final recoverable = error.failure.isRecoverable;
    await _store.markUploadFailed(
      sessionId: sessionId,
      error: error.message,
      retryable: recoverable,
    );
    // Leave a breadcrumb in the job row so the web side can explain a failure
    // rather than showing a panorama that never arrives. Best effort: if the
    // server is unreachable, the local row already says the same thing.
    if (jobAccepted) {
      try {
        await _gateway.upsertJob(
          jobId: jobId,
          sessionId: sessionId,
          userId: account.userId,
          propertyId: propertyId,
          status: PanoJobStatus.error,
          frames: manifest,
          panoramaPath: objectPath,
          error: error.message,
        );
      } catch (nested) {
        debugPrint('SITEWISE_SYNC: could not record job error: $nested');
      }
    }
    debugPrint(
      'SITEWISE_SYNC: $sessionId failed (${error.failure.name}, '
      'recoverable: $recoverable): ${error.message}',
    );
    return SyncAttempt(
      sessionId: sessionId,
      outcome: recoverable ? SyncOutcome.failed : SyncOutcome.blocked,
      failure: error.failure,
      message: error.message,
      remoteObjectPath: objectPath,
      jobId: jobId,
    );
  }

  /// Works through the queue. Returns one attempt per session considered.
  ///
  /// Sessions are considered oldest first so a long offline period drains in
  /// capture order rather than whichever row SQLite happens to return first.
  Future<List<SyncAttempt>> syncPending({int limit = 20}) async {
    final pending = await _store.listPendingUploads(limit: limit);
    final results = <SyncAttempt>[];
    for (final record in pending) {
      if (record.isLeaseActive) {
        results.add(
          SyncAttempt(
            sessionId: record.sessionId,
            outcome: SyncOutcome.skipped,
            message: 'An upload for this session is already in progress.',
          ),
        );
        continue;
      }
      results.add(await syncSession(record.sessionId));
    }
    return results;
  }

  /// The explicit "Retry" a user taps after fixing whatever blocked the upload.
  Future<SyncAttempt> retry(String sessionId) =>
      syncSession(sessionId, force: true);

  /// Resolves a viewable URL for a property's panorama, after the server has
  /// confirmed the caller may see it.
  ///
  /// Returns `null` when there is nothing to show, the job is not `done`, or the
  /// signed-URL request was refused. A signed URL is minted per call and never
  /// persisted.
  Future<PanoramaView> viewPanorama(String sessionId) async {
    final record = await _store.getPanorama(sessionId);
    if (record == null) {
      return const PanoramaView.unavailable(
        PanoramaViewState.notCaptured,
        'No panorama has been captured for this property yet.',
      );
    }
    switch (record.status) {
      case PanoramaSyncStatus.uploaded:
        break;
      case PanoramaSyncStatus.uploading:
      case PanoramaSyncStatus.pending:
      case PanoramaSyncStatus.failed:
        return const PanoramaView.unavailable(
          PanoramaViewState.processing,
          'The panorama is still being prepared for SiteWise.',
        );
      case PanoramaSyncStatus.blocked:
        return PanoramaView.unavailable(
          PanoramaViewState.failed,
          record.lastError ?? 'The panorama could not be uploaded.',
        );
    }
    final objectPath = record.remoteObjectPath;
    if (objectPath == null) {
      return const PanoramaView.unavailable(
        PanoramaViewState.failed,
        'The panorama has no stored location.',
      );
    }
    final url = await _gateway.createSignedUrl(objectPath: objectPath);
    if (url == null) {
      return const PanoramaView.unavailable(
        PanoramaViewState.failed,
        'The panorama could not be opened right now.',
      );
    }
    return PanoramaView.ready(url, record.localPanoramaPath);
  }

  /// The clock the service uses for backoff decisions. Exposed so a UI can show
  /// "next attempt in …" without guessing.
  DateTime now() => _clock();
}

/// What the property detail screen can show for a panorama.
enum PanoramaViewState {
  /// Nothing has been captured for this property.
  notCaptured,

  /// Captured, but not yet `done` in the cloud.
  processing,

  /// The upload failed or is blocked.
  failed,

  /// A signed URL is available.
  ready,
}

class PanoramaView {
  const PanoramaView.ready(String this.signedUrl, this.localPath)
    : state = PanoramaViewState.ready,
      message = null;

  const PanoramaView.unavailable(this.state, String this.message)
    : signedUrl = null,
      localPath = null;

  final PanoramaViewState state;

  /// A short-lived URL. Never stored anywhere.
  final String? signedUrl;

  /// The on-device copy, when this device is the one that captured it.
  final String? localPath;

  final String? message;

  bool get canOpen => signedUrl != null || localPath != null;
}
