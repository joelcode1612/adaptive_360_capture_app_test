import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:adaptive_360_capture_app/core/config/sitewise_environment.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/cloud/panorama_cloud_gateway.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';

/// The Supabase implementation of the panorama cloud operations.
///
/// ## Reuses `public.pano_jobs`
///
/// No new job table. The row is keyed by [panoramaJobId], carries the Storage
/// object path in `panorama_path` (never a device path), and stores a minimal
/// target manifest in `frames`. Its `status` is always one of the four values the
/// existing CHECK constraint allows.
///
/// ## Errors are classified, not swallowed
///
/// Every Supabase failure is translated into a [PanoramaUploadFailure] so the
/// queue knows whether to retry on a timer or wait for the user. A `42501`
/// (insufficient privilege) from `pano_jobs` is the server saying "this account
/// may not attach a panorama to this property" — that is reported as
/// [PanoramaUploadFailure.propertyNotAuthorized] and is never retried blindly.
class SupabasePanoramaGateway implements PanoramaCloudGateway {
  SupabasePanoramaGateway(
    this._client, {
    String? bucket,
    this.jobsTable = 'pano_jobs',
  }) : bucket = bucket ?? SitewiseEnvironment.panoramaBucket;

  final SupabaseClient _client;
  final String bucket;
  final String jobsTable;

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
    try {
      await _client.from(jobsTable).upsert(
        <String, Object?>{
          'id': jobId,
          'session_id': sessionId,
          // `owner` is a uuid referencing auth.users. It is written from the
          // *verified* account id, and the RLS policy additionally requires it
          // to equal auth.uid(), so a client cannot forge another owner.
          'owner': userId,
          'property_id': propertyId,
          'status': status.wireName,
          'frames': frames,
          'panorama_path': panoramaPath,
          'error': error,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'id',
      );
    } catch (error) {
      throw _translate(error, operation: 'pano_jobs write');
    }
  }

  @override
  Future<void> uploadPanoramaObject({
    required String objectPath,
    required File file,
  }) async {
    try {
      await _client.storage.from(bucket).upload(
        objectPath,
        file,
        fileOptions: const FileOptions(
          contentType: 'image/jpeg',
          // Idempotent retry: the path is derived from property+session, so a
          // second attempt replaces its own object instead of creating one.
          upsert: true,
          cacheControl: '3600',
        ),
      );
    } catch (error) {
      throw _translate(error, operation: 'storage upload');
    }
  }

  @override
  Future<String?> createSignedUrl({
    required String objectPath,
    Duration ttl = const Duration(minutes: 10),
  }) async {
    try {
      return await _client.storage
          .from(bucket)
          .createSignedUrl(objectPath, ttl.inSeconds);
    } catch (error) {
      final translated = _translate(error, operation: 'signed url');
      debugPrint('SITEWISE_STORAGE: ${translated.message}');
      return null;
    }
  }

  /// Turns a Supabase exception into the queue's vocabulary.
  PanoramaCloudException _translate(Object error, {required String operation}) {
    if (error is PanoramaCloudException) return error;
    if (error is AuthException) {
      return PanoramaCloudException(
        PanoramaUploadFailure.sessionExpired,
        'The sign-in expired. Sign in again to finish uploading.',
      );
    }
    if (error is PostgrestException) {
      final code = error.code ?? '';
      final message = error.message;
      if (code == '42501' || code == 'PGRST301' || message.contains('row-level security')) {
        // RLS refused the write: either the account is not authorised for this
        // property, or it is not allowed to attach panoramas at all.
        return PanoramaCloudException(
          PanoramaUploadFailure.propertyNotAuthorized,
          'This account is not authorised to store a panorama for that '
          'property.',
        );
      }
      if (code == '23503') {
        // Foreign key: the property does not exist or is not visible.
        return PanoramaCloudException(
          PanoramaUploadFailure.propertyNotAuthorized,
          'That property is no longer available to this account.',
        );
      }
      if (code == '23514') {
        return PanoramaCloudException(
          PanoramaUploadFailure.jobRecord,
          'The panorama job was rejected by the database constraints: $message',
        );
      }
      return PanoramaCloudException(
        PanoramaUploadFailure.jobRecord,
        'The panorama job could not be recorded ($operation): $message',
      );
    }
    if (error is StorageException) {
      final status = error.statusCode;
      final message = error.message;
      if (status == '400' || status == '401' || status == '403') {
        return PanoramaCloudException(
          PanoramaUploadFailure.propertyNotAuthorized,
          'Storage refused the upload for this account ($status). $message',
        );
      }
      if (status == '404') {
        return PanoramaCloudException(
          PanoramaUploadFailure.storage,
          'The $bucket bucket does not exist. Create it as a private bucket and '
          'apply the storage policies.',
        );
      }
      return PanoramaCloudException(
        PanoramaUploadFailure.storage,
        'The panorama could not be stored ($status). $message',
      );
    }
    if (error is SocketException || error is TimeoutException || error is HttpException) {
      return PanoramaCloudException(
        PanoramaUploadFailure.network,
        'No connection to SiteWise. The panorama is saved and will upload when '
        'the device is back online.',
      );
    }
    if (error is ClientException) {
      return PanoramaCloudException(
        PanoramaUploadFailure.network,
        'The upload was interrupted by the network.',
      );
    }
    return PanoramaCloudException(
      PanoramaUploadFailure.unknown,
      'The upload failed ($operation): $error',
    );
  }
}
