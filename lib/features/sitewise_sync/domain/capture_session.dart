import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Where a 38-target capture session is in its local lifecycle.
///
/// These are **local** states. They are deliberately not the values written to
/// `public.pano_jobs.status` — that column accepts exactly `queued`,
/// `processing`, `done` and `error`, and adding offline states to its CHECK
/// constraint would make the cloud table describe the device's network instead
/// of the job's progress.
enum CaptureSessionStatus {
  /// The row exists; no photograph has been saved yet.
  draft('draft'),

  /// At least one target has been captured and the session is resumable.
  capturing('capturing'),

  /// All [CaptureSession.requiredTargetCount] targets are on disk.
  complete('complete'),

  /// The panorama was generated and the file is on disk.
  panoramaReady('panorama_ready'),

  /// The panorama could not be generated; the frames are still intact.
  panoramaFailed('panorama_failed'),

  /// The user abandoned the session. Never produced automatically.
  abandoned('abandoned');

  const CaptureSessionStatus(this.wireName);

  /// The value stored in `capture_sessions.status` and enforced by its CHECK
  /// constraint. Snake case, unlike the Dart identifier — the schema was written
  /// first and a rename here would silently fail every write.
  final String wireName;

  static CaptureSessionStatus fromWire(String? value) {
    for (final status in CaptureSessionStatus.values) {
      if (status.wireName == value) return status;
    }
    return CaptureSessionStatus.draft;
  }

  /// Whether reopening the app should offer to continue this session.
  bool get isResumable =>
      this == CaptureSessionStatus.draft ||
      this == CaptureSessionStatus.capturing ||
      this == CaptureSessionStatus.complete;
}

/// Whether a panorama exists locally, and whether generating it failed.
enum PanoramaGenerationStatus {
  pending,
  generating,
  ready,
  failed;

  static PanoramaGenerationStatus fromWire(String? value) {
    for (final status in PanoramaGenerationStatus.values) {
      if (status.name == value) return status;
    }
    return PanoramaGenerationStatus.pending;
  }
}

/// The local view of cloud synchronisation for one panorama.
///
/// This is intentionally richer than `pano_jobs.status`: it has to describe
/// "queued while offline", "uploading", "retrying" and "blocked until the user
/// signs in again" without inventing database values.
enum PanoramaSyncStatus {
  /// A finished panorama that has not been offered to the network yet.
  pending,

  /// An upload holds the session's lease right now.
  uploading,

  /// Supabase confirmed the object and the job row says `done`.
  uploaded,

  /// A recoverable failure. [PanoramaSyncRecord.retryCount] drives backoff.
  failed,

  /// Not retryable without the user doing something: sign in again, restore
  /// access to the property, or supply a readable panorama file.
  blocked;

  static PanoramaSyncStatus fromWire(String? value) {
    for (final status in PanoramaSyncStatus.values) {
      if (status.name == value) return status;
    }
    return PanoramaSyncStatus.pending;
  }

  bool get needsUpload =>
      this == PanoramaSyncStatus.pending || this == PanoramaSyncStatus.failed;

  bool get isTerminal => this == PanoramaSyncStatus.uploaded;
}

/// The four values `public.pano_jobs.status` accepts.
///
/// The ERD's CHECK constraint is the authority; this enum exists so the app
/// cannot send a fifth value by accident.
enum PanoJobStatus {
  queued('queued'),
  processing('processing'),
  done('done'),
  error('error');

  const PanoJobStatus(this.wireName);

  final String wireName;
}

/// One 38-target capture session.
///
/// The primary key is the session id, which is also the station directory name
/// the existing file repository uses. Keeping them equal is what makes the
/// SQLite row and the JPEG paths on disk describe the same thing, so the
/// stitching implementation keeps reading the paths it always read.
class CaptureSession {
  const CaptureSession({
    required this.sessionId,
    required this.userId,
    required this.propertyId,
    required this.requiredTargetCount,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.panoramaStatus,
    this.localPanoramaPath,
    this.lastError,
  });

  final String sessionId;

  /// `auth.users.id` of the signed-in account, or `null` for an anonymous
  /// capture. An anonymous session can still be captured and stitched; it
  /// simply cannot be uploaded.
  final String? userId;

  /// `public.property.property_id` (`bigint`), once a property is selected and
  /// the association is verified. `null` means "not associated yet", and an
  /// unassociated session is never uploaded into a property folder.
  final int? propertyId;

  /// Always [kSphereTargetCount] for this flow; stored rather than assumed so
  /// a future layout change is a data migration, not a code hunt.
  final int requiredTargetCount;

  final CaptureSessionStatus status;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Absolute path of the stitched equirectangular JPEG, when it exists.
  final String? localPanoramaPath;

  final PanoramaGenerationStatus panoramaStatus;

  /// The last user-facing failure for this session, or `null`.
  final String? lastError;

  bool get isComplete => status == CaptureSessionStatus.complete ||
      status == CaptureSessionStatus.panoramaReady;

  bool get hasPanorama =>
      panoramaStatus == PanoramaGenerationStatus.ready &&
      localPanoramaPath != null;

  CaptureSession copyWith({
    String? userId,
    int? propertyId,
    bool clearProperty = false,
    CaptureSessionStatus? status,
    DateTime? updatedAt,
    String? localPanoramaPath,
    bool clearPanoramaPath = false,
    PanoramaGenerationStatus? panoramaStatus,
    String? lastError,
    bool clearLastError = false,
  }) => CaptureSession(
    sessionId: sessionId,
    userId: userId ?? this.userId,
    propertyId: clearProperty ? null : (propertyId ?? this.propertyId),
    requiredTargetCount: requiredTargetCount,
    status: status ?? this.status,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    localPanoramaPath: clearPanoramaPath
        ? null
        : (localPanoramaPath ?? this.localPanoramaPath),
    panoramaStatus: panoramaStatus ?? this.panoramaStatus,
    lastError: clearLastError ? null : (lastError ?? this.lastError),
  );

  Map<String, Object?> toRow() => <String, Object?>{
    'session_id': sessionId,
    'user_id': userId,
    'property_id': propertyId,
    'required_target_count': requiredTargetCount,
    'status': status.wireName,
    'created_at': createdAt.toUtc().millisecondsSinceEpoch,
    'updated_at': updatedAt.toUtc().millisecondsSinceEpoch,
    'local_panorama_path': localPanoramaPath,
    'panorama_status': panoramaStatus.name,
    'last_error': lastError,
  };

  static CaptureSession fromRow(Map<String, Object?> row) => CaptureSession(
    sessionId: row['session_id']! as String,
    userId: row['user_id'] as String?,
    propertyId: (row['property_id'] as num?)?.toInt(),
    requiredTargetCount:
        (row['required_target_count'] as num?)?.toInt() ?? kSphereTargetCount,
    status: CaptureSessionStatus.fromWire(row['status'] as String?),
    createdAt: _time(row['created_at']),
    updatedAt: _time(row['updated_at']),
    localPanoramaPath: row['local_panorama_path'] as String?,
    panoramaStatus: PanoramaGenerationStatus.fromWire(
      row['panorama_status'] as String?,
    ),
    lastError: row['last_error'] as String?,
  );
}

/// One saved photograph, as SQLite records it.
///
/// The JPEG itself stays in application file storage — only its path is stored
/// here. Duplicating 38 multi-megabyte frames as BLOBs would triple the app's
/// storage use and make every query read megabytes it does not need.
class CapturedFrame {
  const CapturedFrame({
    required this.sessionId,
    required this.targetId,
    required this.imagePath,
    required this.capturedAt,
    required this.targetYawDegrees,
    required this.targetPitchDegrees,
    required this.cameraOrientation,
    required this.imageWidth,
    required this.imageHeight,
    required this.alignmentErrorDeg,
    this.sourceImageWidth = 0,
    this.sourceImageHeight = 0,
    this.cropOffsetX = 0,
    this.cropOffsetY = 0,
    this.toleranceDeg = 0,
    this.captureStatus = 'captured',
  });

  final String sessionId;

  /// 1…38.
  final int targetId;

  /// Absolute path of the JPEG on this device.
  final String imagePath;

  final DateTime capturedAt;

  final double targetYawDegrees;
  final double targetPitchDegrees;

  /// The device quaternion at the shutter.
  final Quat cameraOrientation;

  final int imageWidth;
  final int imageHeight;
  final int sourceImageWidth;
  final int sourceImageHeight;
  final int cropOffsetX;
  final int cropOffsetY;

  /// The 3-D alignment error at the shutter, in degrees.
  final double alignmentErrorDeg;

  /// The tolerance in force when the shutter fired.
  final double toleranceDeg;

  /// `captured` for a normal frame. Kept as text so a future "rejected" or
  /// "superseded" state does not need a schema migration.
  final String captureStatus;

  /// Projects this row back into the record the existing stitcher consumes, so
  /// a restored session can regenerate its panorama without a second code path.
  CaptureRecord toCaptureRecord() => CaptureRecord(
    stationId: sessionId,
    targetId: targetId,
    imagePath: imagePath,
    capturedAt: capturedAt,
    targetYawDegrees: targetYawDegrees,
    targetPitchDegrees: targetPitchDegrees,
    // 3DoF measures no translation: the sphere centre is the camera position
    // by definition, which is what the capture path records too.
    cameraPosition: Vec3.zero,
    cameraOrientation: cameraOrientation,
    alignmentErrorDeg: alignmentErrorDeg,
    anchored: false,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    sourceImageWidth: sourceImageWidth,
    sourceImageHeight: sourceImageHeight,
    cropOffsetX: cropOffsetX,
    cropOffsetY: cropOffsetY,
    imageFormat: 'jpeg',
    toleranceDeg: toleranceDeg,
  );

  static CapturedFrame fromCaptureRecord(CaptureRecord record) => CapturedFrame(
    sessionId: record.stationId,
    targetId: record.targetId,
    imagePath: record.imagePath,
    capturedAt: record.capturedAt,
    targetYawDegrees: record.targetYawDegrees,
    targetPitchDegrees: record.targetPitchDegrees,
    cameraOrientation: record.cameraOrientation,
    imageWidth: record.imageWidth,
    imageHeight: record.imageHeight,
    sourceImageWidth: record.sourceImageWidth,
    sourceImageHeight: record.sourceImageHeight,
    cropOffsetX: record.cropOffsetX,
    cropOffsetY: record.cropOffsetY,
    alignmentErrorDeg: record.alignmentErrorDeg,
    toleranceDeg: record.toleranceDeg,
  );

  Map<String, Object?> toRow() => <String, Object?>{
    'session_id': sessionId,
    'target_id': targetId,
    'image_path': imagePath,
    'captured_at': capturedAt.toUtc().millisecondsSinceEpoch,
    'target_yaw_deg': targetYawDegrees,
    'target_pitch_deg': targetPitchDegrees,
    'camera_qx': cameraOrientation.x,
    'camera_qy': cameraOrientation.y,
    'camera_qz': cameraOrientation.z,
    'camera_qw': cameraOrientation.w,
    'image_width': imageWidth,
    'image_height': imageHeight,
    'source_width': sourceImageWidth,
    'source_height': sourceImageHeight,
    'crop_offset_x': cropOffsetX,
    'crop_offset_y': cropOffsetY,
    'alignment_error_deg': alignmentErrorDeg,
    'tolerance_deg': toleranceDeg,
    'capture_status': captureStatus,
  };

  static CapturedFrame fromRow(Map<String, Object?> row) => CapturedFrame(
    sessionId: row['session_id']! as String,
    targetId: (row['target_id']! as num).toInt(),
    imagePath: row['image_path']! as String,
    capturedAt: _time(row['captured_at']),
    targetYawDegrees: (row['target_yaw_deg'] as num?)?.toDouble() ?? 0,
    targetPitchDegrees: (row['target_pitch_deg'] as num?)?.toDouble() ?? 0,
    cameraOrientation: Quat(
      (row['camera_qx'] as num?)?.toDouble() ?? 0,
      (row['camera_qy'] as num?)?.toDouble() ?? 0,
      (row['camera_qz'] as num?)?.toDouble() ?? 0,
      (row['camera_qw'] as num?)?.toDouble() ?? 1,
    ),
    imageWidth: (row['image_width'] as num?)?.toInt() ?? 0,
    imageHeight: (row['image_height'] as num?)?.toInt() ?? 0,
    sourceImageWidth: (row['source_width'] as num?)?.toInt() ?? 0,
    sourceImageHeight: (row['source_height'] as num?)?.toInt() ?? 0,
    cropOffsetX: (row['crop_offset_x'] as num?)?.toInt() ?? 0,
    cropOffsetY: (row['crop_offset_y'] as num?)?.toInt() ?? 0,
    alignmentErrorDeg: (row['alignment_error_deg'] as num?)?.toDouble() ?? 0,
    toleranceDeg: (row['tolerance_deg'] as num?)?.toDouble() ?? 0,
    captureStatus: row['capture_status'] as String? ?? 'captured',
  );
}

/// The synchronisation state of one panorama.
///
/// One row per session (the primary key), because a session has exactly one
/// finished panorama. A partial unique index on `job_id` additionally makes it
/// impossible for two rows to claim the same cloud job, which is the duplicate
/// that a retry storm would otherwise produce.
class PanoramaSyncRecord {
  const PanoramaSyncRecord({
    required this.sessionId,
    required this.status,
    required this.retryCount,
    required this.updatedAt,
    this.localPanoramaPath,
    this.jobId,
    this.remoteObjectPath,
    this.propertyId,
    this.lastError,
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.claimedAt,
  });

  final String sessionId;

  /// Absolute local path. Never uploaded as a path; only read to upload bytes.
  final String? localPanoramaPath;

  /// `public.pano_jobs.id`.
  final String? jobId;

  /// The Supabase Storage object path, e.g.
  /// `properties/12/sessions/sphere-1700/panorama.jpg`.
  ///
  /// This — never the Android file path — is what goes into
  /// `public.pano_jobs.panorama_path`.
  final String? remoteObjectPath;

  final int? propertyId;

  final PanoramaSyncStatus status;

  final int retryCount;

  final String? lastError;

  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;

  /// When an upload last took the lease. A stale lease (app killed mid-upload)
  /// is reclaimed after [PanoramaSyncRecord.leaseTimeout].
  final DateTime? claimedAt;

  final DateTime updatedAt;

  /// How long a lease is honoured before another attempt may claim it.
  static const Duration leaseTimeout = Duration(minutes: 5);

  /// How many recoverable failures are retried before the row is blocked for
  /// user attention. The local file is never deleted either way.
  static const int maxRetries = 5;

  bool get isLeaseActive {
    final claimed = claimedAt;
    if (claimed == null) return false;
    return DateTime.now().toUtc().difference(claimed.toUtc()) < leaseTimeout;
  }

  bool get canRetry => status.needsUpload && retryCount < maxRetries;

  /// Exponential backoff: 0 s, 30 s, 2 m, 8 m, 32 m. Capped so a device that
  /// has been offline for a day does not wait a day to try again.
  Duration get retryDelay {
    const base = Duration(seconds: 30);
    if (retryCount <= 0) return Duration.zero;
    final multiplier = 1 << (retryCount - 1).clamp(0, 5);
    final seconds = base.inSeconds * multiplier;
    return Duration(seconds: seconds > 3600 ? 3600 : seconds);
  }

  bool get isBackoffElapsed {
    final attempt = lastAttemptAt;
    if (attempt == null) return true;
    return DateTime.now().toUtc().difference(attempt.toUtc()) >= retryDelay;
  }

  PanoramaSyncRecord copyWith({
    PanoramaSyncStatus? status,
    String? localPanoramaPath,
    String? jobId,
    String? remoteObjectPath,
    int? propertyId,
    int? retryCount,
    String? lastError,
    bool clearLastError = false,
    DateTime? lastAttemptAt,
    DateTime? lastSuccessAt,
    DateTime? claimedAt,
    bool clearClaim = false,
    DateTime? updatedAt,
  }) => PanoramaSyncRecord(
    sessionId: sessionId,
    localPanoramaPath: localPanoramaPath ?? this.localPanoramaPath,
    jobId: jobId ?? this.jobId,
    remoteObjectPath: remoteObjectPath ?? this.remoteObjectPath,
    propertyId: propertyId ?? this.propertyId,
    status: status ?? this.status,
    retryCount: retryCount ?? this.retryCount,
    lastError: clearLastError ? null : (lastError ?? this.lastError),
    lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
    lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
    claimedAt: clearClaim ? null : (claimedAt ?? this.claimedAt),
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toRow() => <String, Object?>{
    'session_id': sessionId,
    'local_panorama_path': localPanoramaPath,
    'job_id': jobId,
    'remote_object_path': remoteObjectPath,
    'property_id': propertyId,
    'status': status.name,
    'retry_count': retryCount,
    'last_error': lastError,
    'last_attempt_at': lastAttemptAt?.toUtc().millisecondsSinceEpoch,
    'last_success_at': lastSuccessAt?.toUtc().millisecondsSinceEpoch,
    'claimed_at': claimedAt?.toUtc().millisecondsSinceEpoch,
    'updated_at': updatedAt.toUtc().millisecondsSinceEpoch,
  };

  static PanoramaSyncRecord fromRow(Map<String, Object?> row) =>
      PanoramaSyncRecord(
        sessionId: row['session_id']! as String,
        localPanoramaPath: row['local_panorama_path'] as String?,
        jobId: row['job_id'] as String?,
        remoteObjectPath: row['remote_object_path'] as String?,
        propertyId: (row['property_id'] as num?)?.toInt(),
        status: PanoramaSyncStatus.fromWire(row['status'] as String?),
        retryCount: (row['retry_count'] as num?)?.toInt() ?? 0,
        lastError: row['last_error'] as String?,
        lastAttemptAt: _timeOrNull(row['last_attempt_at']),
        lastSuccessAt: _timeOrNull(row['last_success_at']),
        claimedAt: _timeOrNull(row['claimed_at']),
        updatedAt: _time(row['updated_at']),
      );
}

DateTime _time(Object? value) => _timeOrNull(value) ?? DateTime.now().toUtc();

DateTime? _timeOrNull(Object? value) {
  if (value == null) return null;
  final millis = (value as num).toInt();
  return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
}
