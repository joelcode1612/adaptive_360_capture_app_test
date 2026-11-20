import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:adaptive_360_capture_app/features/sitewise_sync/data/cloud/panorama_cloud_gateway.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';

/// FastAPI transport for the existing local-first panorama synchronization.
///
/// Server endpoints are defined by backend/src/sitesense/api/v1/panorama_sync.py.
/// Supabase Auth still supplies the identity; the backend verifies the access
/// token and is solely responsible for writing protected Storage/database rows.
class FastApiPanoramaGateway implements PanoramaCloudGateway {
  FastApiPanoramaGateway({
    required this.baseUri,
    required this.supabase,
    http.Client? client,
    this.timeout = const Duration(seconds: 120),
  }) : _client = client ?? http.Client();

  final Uri baseUri;
  final SupabaseClient supabase;
  final Duration timeout;
  final http.Client _client;

  Uri _endpoint(String path, [Map<String, String>? query]) =>
      baseUri.resolve(path).replace(queryParameters: query);

  String _token() {
    final token = supabase.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const PanoramaCloudException(
        PanoramaUploadFailure.unauthenticated,
        'Sign in to SiteWise before uploading the panorama.',
      );
    }
    return token;
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
    final uri = _endpoint('/api/v1/panoramas/jobs');
    final body = jsonEncode(<String, Object?>{
      'id': jobId,
      'session_id': sessionId,
      'user_id': userId,
      'property_id': propertyId,
      'status': status.wireName,
      'frames': frames,
      'panorama_path': panoramaPath,
      'error': error,
    });
    await _send(http.Request('POST', uri)
      ..headers.addAll(<String, String>{
        'Authorization': 'Bearer ${_token()}',
        'Content-Type': 'application/json',
      })
      ..body = body);
  }

  @override
  Future<void> uploadPanoramaObject({
    required String objectPath,
    required File file,
  }) async {
    if (!await file.exists()) {
      throw const PanoramaCloudException(
        PanoramaUploadFailure.missingLocalFile,
        'The local panorama file is missing.',
      );
    }
    final request = http.MultipartRequest(
      'POST', _endpoint('/api/v1/panoramas/upload'),
    )
      ..headers['Authorization'] = 'Bearer ${_token()}'
      ..fields['object_path'] = objectPath;
    request.files.add(await http.MultipartFile.fromPath(
      'image', file.path, filename: 'panorama.jpg',
      contentType: MediaType('image', 'jpeg'),
    ));
    await _send(request);
  }

  @override
  Future<String?> createSignedUrl({
    required String objectPath,
    Duration ttl = const Duration(minutes: 10),
  }) async {
    try {
      final response = await _send(http.Request(
        'GET',
        _endpoint('/api/v1/panoramas/signed-url', <String, String>{
          'object_path': objectPath,
          'ttl_seconds': '${ttl.inSeconds}',
        }),
      )..headers['Authorization'] = 'Bearer ${_token()}');
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final url = data['signed_url'];
      return url is String && url.startsWith('https://') ? url : null;
    } on Exception {
      // Match the gateway contract: a viewer URL failure does not erase a
      // locally saved panorama or crash the property detail screen.
      return null;
    }
  }

  Future<http.Response> _send(http.BaseRequest request) async {
    try {
      final streamed = await _client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = response.statusCode;
        String reason = response.body;
        try {
          final parsed = jsonDecode(response.body);
          if (parsed is Map && parsed['detail'] != null) {
            reason = parsed['detail'].toString();
          }
        } on FormatException {
          // Keep the server's text response.
        }
        if (reason.length > 250) reason = reason.substring(0, 250);
        final failure = switch (code) {
          401 => PanoramaUploadFailure.sessionExpired,
          403 => PanoramaUploadFailure.propertyNotAuthorized,
          404 => PanoramaUploadFailure.propertyNotAssociated,
          400 || 413 || 415 || 422 => PanoramaUploadFailure.unreadableLocalFile,
          408 || 429 => PanoramaUploadFailure.network,
          _ => PanoramaUploadFailure.jobRecord,
        };
        throw PanoramaCloudException(
          failure, 'FastAPI returned HTTP $code: $reason',
        );
      }
      return response;
    } on PanoramaCloudException {
      rethrow;
    } on TimeoutException {
      throw const PanoramaCloudException(
        PanoramaUploadFailure.network,
        'FastAPI timed out; the panorama remains on this device.',
      );
    } on SocketException {
      throw const PanoramaCloudException(
        PanoramaUploadFailure.network,
        'FastAPI is unreachable; the panorama remains on this device.',
      );
    } on http.ClientException {
      throw const PanoramaCloudException(
        PanoramaUploadFailure.network,
        'The network interrupted the upload; the panorama is saved locally.',
      );
    }
  }
}
