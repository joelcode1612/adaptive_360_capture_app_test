/// Where the Supabase configuration comes from.
///
/// ## Build-time, not baked in
///
/// The project already configures the device through `--dart-define`
/// (`sphereVerticalFovDeg`, `sphere_diagnostics`), so the Supabase coordinates
/// use the same mechanism rather than a checked-in constants file:
///
/// ```sh
/// flutter run \
///   --dart-define=SITEWISE_SUPABASE_URL=https://<project>.supabase.co \
///   --dart-define=SITEWISE_SUPABASE_KEY=<publishable-anon-key>
/// ```
///
/// ## What may live here
///
/// Only the URL and the **publishable** key. Both are safe to ship in a client
/// — they identify the project and are constrained by RLS. The service-role key
/// bypasses RLS and must never appear in this app, in `--dart-define`, or in any
/// file under `lib/`; it belongs to trusted server-side code only.
///
/// With nothing configured the app is fully functional offline: capture,
/// stitching and local viewing all work, and the sync queue simply reports that
/// cloud sync is not configured instead of failing.
library;

abstract final class SitewiseEnvironment {
  /// Backend API used for authenticated panorama uploads. Empty = offline only.
  /// Example physical device (with adb reverse): http://127.0.0.1:8090
  static const String apiBaseUrl = String.fromEnvironment(
    'SITEWISE_API_BASE_URL',
  );

  /// `https://<project>.supabase.co`, or empty when unset.
  static const String supabaseUrl = String.fromEnvironment(
    'SITEWISE_SUPABASE_URL',
  );

  /// The publishable/anon key, or empty when unset.
  static const String supabasePublishableKey = String.fromEnvironment(
    'SITEWISE_SUPABASE_KEY',
    defaultValue: String.fromEnvironment('SITEWISE_SUPABASE_ANON_KEY'),
  );

  /// The private Storage bucket completed panoramas are written to.
  static const String panoramaBucket = String.fromEnvironment(
    'SITEWISE_PANORAMA_BUCKET',
    defaultValue: 'property-panoramas',
  );

  /// Whether both coordinates are present.
  static bool get isSupabaseConfigured =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;

  /// A short, non-secret description for the UI and logs.
  static String describe() {
    if (!isSupabaseConfigured) return 'Supabase is not configured';
    final uri = Uri.tryParse(supabaseUrl);
    return 'Supabase ${uri?.host ?? supabaseUrl} · bucket $panoramaBucket';
  }
}
