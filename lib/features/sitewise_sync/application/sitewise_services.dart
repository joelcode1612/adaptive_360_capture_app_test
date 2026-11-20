import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/application/panorama_sync_service.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/cloud/sitewise_auth.dart';
import 'package:adaptive_360_capture_app/core/config/sitewise_environment.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/cloud/fastapi_panorama_gateway.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/capture_session_store.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/legacy_session_importer.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/sitewise_database.dart';

/// The local and cloud dependencies the capture screens need, assembled once.
///
/// ## Degrading, not failing
///
/// Three independent things can be unavailable, and each is handled separately
/// rather than as one "app is broken" state:
///
/// * **SQLite** — if the database cannot be opened, [store] is `null` and the
///   capture flow runs exactly as it did before this change (JSON records plus
///   JPEGs). Losing metadata bookkeeping must not cost a photograph.
/// * **Supabase configuration** — if the build has no project URL/key, [auth]
///   reports nobody signed in and [sync] is `null`. Capture, stitching and the
///   local viewer all still work.
/// * **Supabase availability** — the client exists but the network does not;
///   [sync] is present and simply records a queued row.
class SitewiseServices {
  SitewiseServices({
    required this.store,
    required this.auth,
    required this.sync,
    required this.client,
  });

  final CaptureSessionStore? store;
  final SitewiseAuth auth;
  final PanoramaSyncService? sync;
  final SupabaseClient? client;

  /// Whether a panorama can be uploaded at all in this build.
  bool get canSync => sync != null && client != null;

  /// Whether Supabase was configured, regardless of whether anyone is signed in.
  bool get hasCloud => client != null;

  static bool _legacyImportRan = false;

  /// Builds the services, tolerating any of them being unavailable.
  ///
  /// Also runs the one-time import of pre-SQLite station directories. That is
  /// deliberately here rather than in a migration screen: it is idempotent, it
  /// reads the old files without touching them, and doing it on first launch
  /// means a user who updates the app sees their earlier captures in the resume
  /// list without doing anything.
  static Future<SitewiseServices> create() async {
    SitewiseAuth auth = const UnconfiguredSitewiseAuth();
    SupabaseClient? client;

    if (await SitewiseSupabase.ensureInitialised()) {
      client = SitewiseSupabase.clientOrNull;
      if (client != null) auth = SupabaseSitewiseAuth(client);
    }

    CaptureSessionStore? store;
    PanoramaSyncService? sync;
    try {
      final database = await SitewiseDatabase.open();
      store = SqliteCaptureSessionStore(database);
      // Only the backend writes protected panorama metadata and Storage bytes.
      // Without an API URL, keep capturing/stitching offline; do not silently
      // fall back to the legacy direct `public.pano_jobs` upload path.
      if (client != null && SitewiseEnvironment.apiBaseUrl.trim().isNotEmpty) {
        final apiUri = Uri.tryParse(SitewiseEnvironment.apiBaseUrl.trim());
        if (apiUri == null || !apiUri.hasScheme || apiUri.host.isEmpty) {
          throw StateError('Invalid SITEWISE_API_BASE_URL');
        }
        sync = PanoramaSyncService(
          store: store,
          gateway: FastApiPanoramaGateway(baseUri: apiUri, supabase: client),
          auth: auth,
        );
      }
      if (!_legacyImportRan) {
        _legacyImportRan = true;
        try {
          final repository = await FileCaptureRepository.create();
          await LegacySessionImporter(
            repository: repository,
            store: store,
          ).importAll();
        } catch (error) {
          debugPrint('SITEWISE_IMPORT: skipped: $error');
        }
      }
    } catch (error) {
      // The capture flow is designed to work without this. Say so once, loudly
      // enough to diagnose, and continue.
      debugPrint(
        'SITEWISE_DB: local database unavailable, continuing with file-only '
        'persistence: $error',
      );
    }

    return SitewiseServices(
      store: store,
      auth: auth,
      sync: sync,
      client: client,
    );
  }
}
