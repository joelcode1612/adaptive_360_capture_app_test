import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/sitewise_database.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';

/// The local-first metadata store.
///
/// Every operation the 38-target workflow needs is here, and every one of them
/// is a parameterised statement — no string interpolation reaches SQLite, so a
/// session id or a file path containing a quote cannot change a statement's
/// meaning.
///
/// The interface exists so the capture controller can be handed a fake in a
/// unit test while production gets [SqliteCaptureSessionStore], and so the sync
/// service can be tested against a store it does not own.
abstract class CaptureSessionStore {
  /// Creates the session, or returns the existing one with the same id.
  ///
  /// "Create or restore" in one call is what makes reopening the app safe: the
  /// screen asks for the resumable session first and only creates when there is
  /// none, but a double tap on Start must not produce two rows for one session.
  Future<CaptureSession> createSession({
    required String sessionId,
    String? userId,
    int? propertyId,
    int requiredTargetCount = kSphereTargetCount,
  });

  Future<CaptureSession?> getSession(String sessionId);

  /// Newest first. [userId] filters to one account; pass `null` for all.
  Future<List<CaptureSession>> listSessions({String? userId, int limit = 50});

  /// The newest session for [userId] that still has targets to capture, or one
  /// whose panorama has not been uploaded yet.
  Future<CaptureSession?> findResumableSession({String? userId});

  /// Records a saved JPEG.
  ///
  /// Replaces any existing row for the same target — a retake overwrites the
  /// evidence instead of appending a second photograph — and advances the
  /// session to `capturing` in the same transaction.
  Future<CapturedFrame> saveFrame(CapturedFrame frame);

  /// Moves a session to an explicit lifecycle state.
  ///
  /// Used for the two transitions the frame/panorama writes cannot infer: the
  /// 38th frame (`complete`) and a session the user abandoned.
  Future<void> markSessionStatus({
    required String sessionId,
    required CaptureSessionStatus status,
    String? error,
  });

  /// Links a session (and any queued panorama) to a property.
  ///
  /// Written before upload. It is **not** an authorisation: the server's RLS
  /// policies decide whether this account may attach a panorama to that
  /// property, and the upload is refused before any bytes move if they say no.
  Future<void> attachProperty({
    required String sessionId,
    required int propertyId,
  });

  /// All saved frames for [sessionId], ordered by target id.
  Future<List<CapturedFrame>> loadFrames(String sessionId);

  /// How many of the [requiredTargetCount] targets are saved.
  Future<int> countFrames(String sessionId);

  /// Records the stitched panorama and, on success, queues it for upload.
  ///
  /// One transaction: the session row and its `panorama_sync` row must not
  /// disagree about whether a panorama exists, or the upload queue would either
  /// miss a finished panorama or try to upload a file that was never written.
  Future<PanoramaSyncRecord?> savePanorama({
    required String sessionId,
    required String? localPanoramaPath,
    required PanoramaGenerationStatus status,
    String? error,
  });

  Future<PanoramaSyncRecord?> getPanorama(String sessionId);

  /// Marks a finished panorama as waiting for upload. Idempotent.
  Future<void> markUploadPending(String sessionId);

  /// Records a confirmed upload: Supabase returned the object and the job row
  /// says `done`. Never called on an assumption.
  Future<void> markUploadSucceeded({
    required String sessionId,
    required String jobId,
    required String remoteObjectPath,
    required int propertyId,
  });

  /// Records a failed attempt.
  ///
  /// [retryable] chooses between `failed` (the queue will try again after the
  /// backoff) and `blocked` (the user must act: sign in, restore access). Either
  /// way the local panorama stays on disk.
  Future<void> markUploadFailed({
    required String sessionId,
    required String error,
    bool retryable = true,
  });

  /// Marks a session as blocked for a reason only the user can clear.
  Future<void> markUploadBlocked({
    required String sessionId,
    required String reason,
  });

  /// Everything the queue should look at, oldest first.
  Future<List<PanoramaSyncRecord>> listPendingUploads({int limit = 20});

  /// Takes the upload lease for [sessionId].
  ///
  /// Returns `false` when another attempt holds a live lease, which is how two
  /// concurrent uploads of the same panorama are prevented without a lock
  /// server. A lease left behind by a killed process expires after
  /// [PanoramaSyncRecord.leaseTimeout] and can be reclaimed.
  Future<bool> claimUpload(String sessionId);

  /// Releases a lease without recording an outcome (used when an attempt ends
  /// in a state the other methods do not describe).
  Future<void> releaseUpload(String sessionId);

  /// Deletes a session and its frames from SQLite.
  ///
  /// Returns the file paths the session owned, so the caller can delete them
  /// **after** an explicit user confirmation. This method never touches the
  /// filesystem itself: a metadata delete that silently removed 38 photographs
  /// would be the worst possible failure mode for this app.
  Future<List<String>> deleteSession(String sessionId);
}

/// The SQLite implementation.
class SqliteCaptureSessionStore implements CaptureSessionStore {
  SqliteCaptureSessionStore(this._database, {DateTime Function()? clock})
    : _clock = clock ?? (() => DateTime.now().toUtc());

  final SitewiseDatabase _database;
  final DateTime Function() _clock;

  Database get _db => _database.db;

  @override
  Future<CaptureSession> createSession({
    required String sessionId,
    String? userId,
    int? propertyId,
    int requiredTargetCount = kSphereTargetCount,
  }) async {
    final now = _clock();
    await _db.insert(
      'capture_sessions',
      <String, Object?>{
        'session_id': sessionId,
        'user_id': userId,
        'property_id': propertyId,
        'required_target_count': requiredTargetCount,
        'status': CaptureSessionStatus.draft.wireName,
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
        'panorama_status': PanoramaGenerationStatus.pending.name,
      },
      // Re-opening a session must not reset it. A duplicate create is a no-op,
      // so a double tap or a restored screen cannot erase progress.
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    final session = await getSession(sessionId);
    if (session == null) {
      throw StateError('Capture session $sessionId could not be created.');
    }
    return session;
  }

  @override
  Future<CaptureSession?> getSession(String sessionId) async {
    final rows = await _db.query(
      'capture_sessions',
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CaptureSession.fromRow(rows.first);
  }

  @override
  Future<List<CaptureSession>> listSessions({
    String? userId,
    int limit = 50,
  }) async {
    final rows = await _db.query(
      'capture_sessions',
      where: userId == null ? null : 'user_id = ?',
      whereArgs: userId == null ? null : <Object?>[userId],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(CaptureSession.fromRow).toList(growable: false);
  }

  @override
  Future<CaptureSession?> findResumableSession({String? userId}) async {
    // Two kinds of unfinished work matter on relaunch: a session with targets
    // still to capture, and a finished panorama that has not reached the cloud.
    // The second is what makes "close the app, upload later" work, so it is
    // included rather than treated as done.
    final rows = await _db.rawQuery(
      '''
      SELECT s.* FROM capture_sessions s
      WHERE s.status IN ('draft', 'capturing', 'complete')
        AND (? IS NULL OR s.user_id = ?)
      ORDER BY s.updated_at DESC
      LIMIT 1
      ''',
      <Object?>[userId, userId],
    );
    if (rows.isEmpty) return null;
    return CaptureSession.fromRow(rows.first);
  }

  @override
  Future<CapturedFrame> saveFrame(CapturedFrame frame) async {
    final now = _clock();
    await _db.transaction((txn) async {
      await txn.insert(
        'captured_frames',
        frame.toRow(),
        // A retake of the same target replaces the row. The composite primary
        // key (session_id, target_id) is the duplicate guard; this makes the
        // replacement legal rather than an error.
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.update(
        'capture_sessions',
        <String, Object?>{
          'status': CaptureSessionStatus.capturing.wireName,
          'updated_at': now.millisecondsSinceEpoch,
          'last_error': null,
        },
        where: 'session_id = ?',
        whereArgs: <Object?>[frame.sessionId],
      );
    });
    return frame;
  }

  @override
  Future<void> markSessionStatus({
    required String sessionId,
    required CaptureSessionStatus status,
    String? error,
  }) async {
    await _db.update(
      'capture_sessions',
      <String, Object?>{
        'status': status.wireName,
        'last_error': error,
        'updated_at': _clock().millisecondsSinceEpoch,
      },
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
    );
  }

  @override
  Future<void> attachProperty({
    required String sessionId,
    required int propertyId,
  }) async {
    final now = _clock().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      await txn.update(
        'capture_sessions',
        <String, Object?>{'property_id': propertyId, 'updated_at': now},
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
      );
      // The queue row carries its own copy because the uploader reads it
      // without a join; the two must not disagree about where the panorama
      // belongs.
      await txn.update(
        'panorama_sync',
        <String, Object?>{'property_id': propertyId, 'updated_at': now},
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
      );
    });
  }

  @override
  Future<List<CapturedFrame>> loadFrames(String sessionId) async {    final rows = await _db.query(
      'captured_frames',
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
      orderBy: 'target_id ASC',
    );
    return rows.map(CapturedFrame.fromRow).toList(growable: false);
  }

  @override
  Future<int> countFrames(String sessionId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM captured_frames WHERE session_id = ?',
      <Object?>[sessionId],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<PanoramaSyncRecord?> savePanorama({
    required String sessionId,
    required String? localPanoramaPath,
    required PanoramaGenerationStatus status,
    String? error,
  }) async {
    final now = _clock();
    final ready = status == PanoramaGenerationStatus.ready &&
        localPanoramaPath != null;
    await _db.transaction((txn) async {
      final session = await txn.query(
        'capture_sessions',
        columns: <String>['property_id', 'required_target_count'],
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
        limit: 1,
      );
      if (session.isEmpty) {
        throw StateError('Capture session $sessionId does not exist.');
      }
      final propertyId = (session.first['property_id'] as num?)?.toInt();

      await txn.update(
        'capture_sessions',
        <String, Object?>{
          'local_panorama_path': localPanoramaPath,
          'panorama_status': status.name,
          'status': ready
              ? CaptureSessionStatus.panoramaReady.wireName
              : CaptureSessionStatus.panoramaFailed.wireName,
          'last_error': error,
          'updated_at': now.millisecondsSinceEpoch,
        },
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
      );

      if (!ready) {
        // A failed stitch has nothing to upload. Leaving a stale queue row
        // would make the uploader chase a file that does not exist.
        await txn.delete(
          'panorama_sync',
          where: 'session_id = ? AND status != ?',
          whereArgs: <Object?>[sessionId, PanoramaSyncStatus.uploaded.name],
        );
        return;
      }

      // A regenerated panorama keeps any confirmed upload: the object path is
      // deterministic, so a successful upload of a previous render is still a
      // successful upload of this session. Re-marking it pending would upload
      // the same bytes twice. The confirmed job id and remote path are updated
      // in place rather than replaced, because `panorama_path` is the only
      // record of where the cloud copy lives.
      final existing = await txn.query(
        'panorama_sync',
        columns: <String>['status'],
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
        limit: 1,
      );
      final alreadyUploaded = existing.isNotEmpty &&
          PanoramaSyncStatus.fromWire(existing.first['status'] as String?) ==
              PanoramaSyncStatus.uploaded;

      if (existing.isEmpty) {
        await txn.insert('panorama_sync', <String, Object?>{
          'session_id': sessionId,
          'local_panorama_path': localPanoramaPath,
          'property_id': propertyId,
          'status': PanoramaSyncStatus.pending.name,
          'retry_count': 0,
          'updated_at': now.millisecondsSinceEpoch,
        });
      } else if (alreadyUploaded) {
        await txn.update(
          'panorama_sync',
          <String, Object?>{
            'local_panorama_path': localPanoramaPath,
            'property_id': propertyId,
            'updated_at': now.millisecondsSinceEpoch,
          },
          where: 'session_id = ?',
          whereArgs: <Object?>[sessionId],
        );
      } else {
        await txn.update(
          'panorama_sync',
          <String, Object?>{
            'local_panorama_path': localPanoramaPath,
            'property_id': propertyId,
            'status': PanoramaSyncStatus.pending.name,
            'retry_count': 0,
            'last_error': null,
            'claimed_at': null,
            'updated_at': now.millisecondsSinceEpoch,
          },
          where: 'session_id = ?',
          whereArgs: <Object?>[sessionId],
        );
      }
    });
    return getPanorama(sessionId);
  }

  @override
  Future<PanoramaSyncRecord?> getPanorama(String sessionId) async {
    final rows = await _db.query(
      'panorama_sync',
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PanoramaSyncRecord.fromRow(rows.first);
  }

  @override
  Future<void> markUploadPending(String sessionId) async {
    final now = _clock();
    final session = await getSession(sessionId);
    if (session == null) {
      throw StateError('Capture session $sessionId does not exist.');
    }
    if (session.localPanoramaPath == null) return;
    await _db.insert(
      'panorama_sync',
      <String, Object?>{
        'session_id': sessionId,
        'local_panorama_path': session.localPanoramaPath,
        'property_id': session.propertyId,
        'status': PanoramaSyncStatus.pending.name,
        'updated_at': now.millisecondsSinceEpoch,
      },
      // Existing rows are only reset when they are not already confirmed, so
      // "queue it again" cannot un-upload a panorama the cloud already has.
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await _db.update(
      'panorama_sync',
      <String, Object?>{
        'local_panorama_path': session.localPanoramaPath,
        'property_id': session.propertyId,
        'status': PanoramaSyncStatus.pending.name,
        'last_error': null,
        'updated_at': now.millisecondsSinceEpoch,
      },
      where: 'session_id = ? AND status != ?',
      whereArgs: <Object?>[sessionId, PanoramaSyncStatus.uploaded.name],
    );
  }

  @override
  Future<void> markUploadSucceeded({
    required String sessionId,
    required String jobId,
    required String remoteObjectPath,
    required int propertyId,
  }) async {
    final now = _clock();
    await _db.transaction((txn) async {
      await txn.update(
        'panorama_sync',
        <String, Object?>{
          'status': PanoramaSyncStatus.uploaded.name,
          'job_id': jobId,
          'remote_object_path': remoteObjectPath,
          'property_id': propertyId,
          'last_success_at': now.millisecondsSinceEpoch,
          'last_attempt_at': now.millisecondsSinceEpoch,
          'last_error': null,
          'claimed_at': null,
          'updated_at': now.millisecondsSinceEpoch,
        },
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
      );
      await txn.update(
        'capture_sessions',
        <String, Object?>{
          'property_id': propertyId,
          'last_error': null,
          'updated_at': now.millisecondsSinceEpoch,
        },
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
      );
    });
  }

  @override
  Future<void> markUploadFailed({
    required String sessionId,
    required String error,
    bool retryable = true,
  }) async {
    final now = _clock();
    await _db.rawUpdate(
      '''
      UPDATE panorama_sync
         SET status = ?,
             retry_count = retry_count + 1,
             last_error = ?,
             last_attempt_at = ?,
             claimed_at = NULL,
             updated_at = ?
       WHERE session_id = ?
      ''',
      <Object?>[
        retryable
            ? PanoramaSyncStatus.failed.name
            : PanoramaSyncStatus.blocked.name,
        error,
        now.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
        sessionId,
      ],
    );
  }

  @override
  Future<void> markUploadBlocked({
    required String sessionId,
    required String reason,
  }) async {
    final now = _clock();
    await _db.update(
      'panorama_sync',
      <String, Object?>{
        'status': PanoramaSyncStatus.blocked.name,
        'last_error': reason,
        'claimed_at': null,
        'updated_at': now.millisecondsSinceEpoch,
      },
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
    );
  }

  @override
  Future<List<PanoramaSyncRecord>> listPendingUploads({int limit = 20}) async {
    final rows = await _db.query(
      'panorama_sync',
      where: 'status IN (?, ?)',
      whereArgs: <Object?>[
        PanoramaSyncStatus.pending.name,
        PanoramaSyncStatus.failed.name,
      ],
      orderBy: 'updated_at ASC',
      limit: limit,
    );
    return rows.map(PanoramaSyncRecord.fromRow).toList(growable: false);
  }

  @override
  Future<bool> claimUpload(String sessionId) async {
    final now = _clock();
    final leaseCutoff = now
        .subtract(PanoramaSyncRecord.leaseTimeout)
        .millisecondsSinceEpoch;
    // A conditional UPDATE is the whole concurrency control: only one caller can
    // observe rowsAffected == 1, because SQLite serialises writes.
    //
    // Two ways to win the lease, and both are needed:
    //  * the row is waiting (`pending`/`failed`) and no live lease is held;
    //  * the row is already `uploading` but its lease has expired, which is what
    //    a process killed mid-upload leaves behind. Without the second case a
    //    crash during an upload would strand the panorama permanently.
    final affected = await _db.rawUpdate(
      '''
      UPDATE panorama_sync
         SET status = ?, claimed_at = ?, updated_at = ?
       WHERE session_id = ?
         AND (
              (status IN (?, ?) AND (claimed_at IS NULL OR claimed_at < ?))
           OR (status = ? AND claimed_at IS NOT NULL AND claimed_at < ?)
         )
      ''',
      <Object?>[
        PanoramaSyncStatus.uploading.name,
        now.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
        sessionId,
        PanoramaSyncStatus.pending.name,
        PanoramaSyncStatus.failed.name,
        leaseCutoff,
        PanoramaSyncStatus.uploading.name,
        leaseCutoff,
      ],
    );
    return affected > 0;
  }

  @override
  Future<void> releaseUpload(String sessionId) async {
    await _db.update(
      'panorama_sync',
      <String, Object?>{
        'claimed_at': null,
        'status': PanoramaSyncStatus.pending.name,
        'updated_at': _clock().millisecondsSinceEpoch,
      },
      where: 'session_id = ? AND status = ?',
      whereArgs: <Object?>[sessionId, PanoramaSyncStatus.uploading.name],
    );
  }

  @override
  Future<List<String>> deleteSession(String sessionId) async {
    final paths = <String>[];
    await _db.transaction((txn) async {
      final frames = await txn.query(
        'captured_frames',
        columns: <String>['image_path'],
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
      );
      for (final row in frames) {
        final path = row['image_path'] as String?;
        if (path != null) paths.add(path);
      }
      final panorama = await txn.query(
        'capture_sessions',
        columns: <String>['local_panorama_path'],
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
        limit: 1,
      );
      if (panorama.isNotEmpty) {
        final path = panorama.first['local_panorama_path'] as String?;
        if (path != null) paths.add(path);
      }
      // The children go first so this works even if a caller opened the
      // database without `PRAGMA foreign_keys`.
      await txn.delete(
        'panorama_sync',
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
      );
      await txn.delete(
        'captured_frames',
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
      );
      await txn.delete(
        'capture_sessions',
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
      );
    });
    debugPrint('SITEWISE_DB: deleted session $sessionId (${paths.length} files)');
    return paths;
  }
}
