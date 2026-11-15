import 'dart:io';

import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';

/// Why an upload attempt did not complete.
///
/// The distinction that matters is [isRecoverable]: a network blip should be
/// retried silently, while an expired session or a revoked property needs the
/// user, and retrying it on a timer would just burn battery.
enum PanoramaUploadFailure {
  /// No failure.
  none,

  /// Nobody is signed in. The panorama is kept and queued.
  unauthenticated,

  /// The session existed but has expired or was revoked.
  sessionExpired,

  /// The server refused the property association for this account.
  propertyNotAuthorized,

  /// The session has no property id, so there is nowhere legitimate to put it.
  propertyNotAssociated,

  /// The local panorama file is gone.
  missingLocalFile,

  /// The local panorama file exists but is not a decodable JPEG.
  unreadableLocalFile,

  /// The device could not reach Supabase.
  network,

  /// Supabase Storage rejected the object.
  storage,

  /// The object was stored but `pano_jobs` could not be updated.
  jobRecord,

  /// Anything else.
  unknown;

  bool get isRecoverable => switch (this) {
    PanoramaUploadFailure.none => false,
    PanoramaUploadFailure.unauthenticated => false,
    PanoramaUploadFailure.sessionExpired => false,
    PanoramaUploadFailure.propertyNotAuthorized => false,
    PanoramaUploadFailure.propertyNotAssociated => false,
    PanoramaUploadFailure.missingLocalFile => false,
    PanoramaUploadFailure.unreadableLocalFile => false,
    PanoramaUploadFailure.network => true,
    PanoramaUploadFailure.storage => true,
    PanoramaUploadFailure.jobRecord => true,
    PanoramaUploadFailure.unknown => true,
  };
}

/// A cloud operation failed in a way the gateway can classify.
class PanoramaCloudException implements Exception {
  const PanoramaCloudException(this.failure, this.message);

  final PanoramaUploadFailure failure;
  final String message;

  @override
  String toString() => 'PanoramaCloudException(${failure.name}): $message';
}

/// The Supabase operations the panorama workflow needs, and nothing more.
///
/// ## Why the job row is written before the object
///
/// The order is deliberate. `public.pano_jobs` carries the RLS policy that
/// verifies the property association, so writing the row first means an
/// unauthorised account is refused **before a single byte reaches Storage** —
/// there is no window in which a panorama sits in another owner's folder
/// waiting for a job that will never be created.
///
/// It also makes the retry story simple: the row exists in `queued`/`error`, the
/// object path is deterministic, and re-running the upload either re-stores the
/// same bytes at the same path (`upsert`) or updates the same row. No duplicate
/// objects and no duplicate jobs.
abstract class PanoramaCloudGateway {
  /// Creates or updates the `pano_jobs` row for a session.
  ///
  /// Throws [PanoramaCloudException] with
  /// [PanoramaUploadFailure.propertyNotAuthorized] when the server's RLS
  /// policies refuse the association. That refusal *is* the verification step;
  /// the client never decides on its own that a property is fair game.
  Future<void> upsertJob({
    required String jobId,
    required String sessionId,
    required String userId,
    required int propertyId,
    required PanoJobStatus status,
    required Map<String, Object?> frames,
    String? panoramaPath,
    String? error,
  });

  /// Uploads the JPEG to `objectPath`, replacing any object already there.
  ///
  /// `upsert` is what makes a retry idempotent: the object path is derived from
  /// the property and session, so a second attempt overwrites its own previous
  /// partial upload instead of creating a `panorama (1).jpg`.
  Future<void> uploadPanoramaObject({
    required String objectPath,
    required File file,
  });

  /// A time-limited URL for viewing a private panorama.
  ///
  /// Signed URLs are minted on demand and never stored: a persisted signed URL
  /// is a permanent capability to read a private object.
  Future<String?> createSignedUrl({
    required String objectPath,
    Duration ttl = const Duration(minutes: 10),
  });
}

/// The canonical Storage object path for a session's panorama.
///
/// `properties/{property_id}/sessions/{session_id}/panorama.jpg`
///
/// Deterministic on purpose: it is the retry key, the duplicate guard and the
/// value stored in `pano_jobs.panorama_path`. It is never a device path.
String panoramaObjectPath({
  required int propertyId,
  required String sessionId,
}) {
  final safeSession = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return 'properties/$propertyId/sessions/$safeSession/panorama.jpg';
}

/// The deterministic `pano_jobs.id` for a session.
///
/// Deriving it instead of generating a UUID is what prevents duplicate jobs: a
/// retry after a crash writes the same primary key, so the second attempt is an
/// update rather than a second job for one panorama.
String panoramaJobId(String sessionId) {
  final safeSession = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return 'pano_$safeSession';
}

/// The minimal target manifest stored in `pano_jobs.frames`.
///
/// Target ids and angles only. Absolute device paths are deliberately excluded:
/// `frames` is a cloud-readable column, and a phone's private storage layout is
/// neither useful nor appropriate there.
Map<String, Object?> buildFrameManifest(
  List<CapturedFrame> frames, {
  required int targetCount,
}) {
  final ordered = List<CapturedFrame>.of(frames)
    ..sort((a, b) => a.targetId.compareTo(b.targetId));
  return <String, Object?>{
    // Self-describing, so the cloud side does not have to assume 38 from its own
    // copy of a constant that only this app owns.
    'targetCount': targetCount,
    'targets': <Map<String, Object?>>[
      for (final frame in ordered)
        <String, Object?>{
          'targetId': frame.targetId,
          'yawDeg': frame.targetYawDegrees,
          'pitchDeg': frame.targetPitchDegrees,
          'capturedAt': frame.capturedAt.toUtc().toIso8601String(),
          'width': frame.imageWidth,
          'height': frame.imageHeight,
          'alignmentErrorDeg': frame.alignmentErrorDeg,
        },
    ],
  };
}
