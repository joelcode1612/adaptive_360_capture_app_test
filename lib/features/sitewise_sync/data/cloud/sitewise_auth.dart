import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:adaptive_360_capture_app/core/config/sitewise_environment.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/app_role.dart';

/// The signed-in account, as the sync layer needs to see it.
class SitewiseAccount {
  const SitewiseAccount({
    required this.userId,
    this.email,
    this.expiresAt,
    this.role,
  });

  /// `auth.users.id`, as a string (Supabase returns a UUID).
  final String userId;

  final String? email;

  /// When the access token expires, if known.
  final DateTime? expiresAt;

  /// The role from `public.users`, when it could be read.
  final AppRole? role;

  /// Whether the token is expired or about to be.
  ///
  /// A 30-second margin is applied because an upload takes longer than a
  /// round trip: a token with five seconds left would pass a naive check and
  /// then fail mid-upload with a 401, which the user would read as "sync is
  /// broken" rather than "sign in again".
  bool get isExpired {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return DateTime.now().toUtc().isAfter(
      expiry.toUtc().subtract(const Duration(seconds: 30)),
    );
  }

  SitewiseAccount withRole(AppRole? role) => SitewiseAccount(
    userId: userId,
    email: email,
    expiresAt: expiresAt,
    role: role,
  );
}

/// Supabase Auth remains the authoritative authentication provider.
///
/// This interface exists so the sync service can be tested without a network
/// and so the app can run with no Supabase project configured at all — in which
/// case [UnconfiguredSitewiseAuth] reports "nobody is signed in" and everything
/// stays local. It is **not** a second authentication system: the only
/// implementation that talks to anything is [SupabaseSitewiseAuth], which is a
/// thin wrapper over `GoTrueClient`.
abstract class SitewiseAuth {
  /// The current session's account, or `null` when signed out or expired.
  Future<SitewiseAccount?> currentAccount();

  /// Emits on sign-in, sign-out and token refresh.
  Stream<SitewiseAccount?> get changes;

  Future<SitewiseAccount> signInWithPassword({
    required String email,
    required String password,
  });

  Future<void> signOut();

  /// Reads the account's role from `public.users`.
  ///
  /// Returns `null` when the row cannot be read — the caller then treats the
  /// account as least-privileged rather than assuming anything.
  Future<AppRole?> fetchRole(String userId);
}

/// The no-cloud implementation: nobody is ever signed in.
class UnconfiguredSitewiseAuth implements SitewiseAuth {
  const UnconfiguredSitewiseAuth();

  @override
  Future<SitewiseAccount?> currentAccount() async => null;

  @override
  Stream<SitewiseAccount?> get changes => const Stream<SitewiseAccount?>.empty();

  @override
  Future<SitewiseAccount> signInWithPassword({
    required String email,
    required String password,
  }) async {
    throw const SitewiseAuthException(
      'This build has no Supabase project configured, so signing in is not '
      'available. Capture and stitching work offline.',
    );
  }

  @override
  Future<void> signOut() async {}

  @override
  Future<AppRole?> fetchRole(String userId) async => null;
}

class SitewiseAuthException implements Exception {
  const SitewiseAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Initialises the Supabase client exactly once, and only when configured.
abstract final class SitewiseSupabase {
  static bool _initialised = false;

  static bool get isInitialised => _initialised;

  /// Returns whether a client is available.
  ///
  /// Safe to call from `main()` and from a widget: a second call is a no-op, and
  /// a missing configuration is reported as `false` rather than thrown, because
  /// an offline-only build is a supported configuration.
  static Future<bool> ensureInitialised() async {
    if (_initialised) return true;
    if (!SitewiseEnvironment.isSupabaseConfigured) {
      debugPrint(
        'SITEWISE_SUPABASE: not configured; running offline-only. '
        'Pass --dart-define=SITEWISE_SUPABASE_URL and '
        '--dart-define=SITEWISE_SUPABASE_KEY to enable cloud sync.',
      );
      return false;
    }
    try {
      await Supabase.initialize(
        url: SitewiseEnvironment.supabaseUrl,
        // Publishable key only. A service-role key here would ship a
        // RLS-bypassing credential to every installed copy of the app.
        publishableKey: SitewiseEnvironment.supabasePublishableKey,
        debug: kDebugMode,
      );
      _initialised = true;
      debugPrint('SITEWISE_SUPABASE: ${SitewiseEnvironment.describe()}');
      return true;
    } catch (error) {
      // A malformed URL or key must not stop the capture app from starting.
      debugPrint('SITEWISE_SUPABASE: initialisation failed: $error');
      return false;
    }
  }

  static SupabaseClient? get clientOrNull =>
      _initialised ? Supabase.instance.client : null;
}

/// The real authentication gateway: Supabase Auth, unmodified.
class SupabaseSitewiseAuth implements SitewiseAuth {
  SupabaseSitewiseAuth(
    this._client, {
    this.usersTable = 'users',
    this.userIdColumn = 'user_id',
    this.roleColumn = 'role',
  });

  final SupabaseClient _client;

  /// The profile table and columns the role is read from.
  ///
  /// Defaults match the SiteWise schema; they are constructor parameters because
  /// the live database is the authority and a column rename must be a one-line
  /// change here, not a rewrite.
  final String usersTable;
  final String userIdColumn;
  final String roleColumn;

  @override
  Future<SitewiseAccount?> currentAccount() async {
    final session = _client.auth.currentSession;
    if (session == null) return null;
    return SitewiseAccount(
      userId: session.user.id,
      email: session.user.email,
      expiresAt: session.expiresAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              session.expiresAt! * 1000,
              isUtc: true,
            ),
    );
  }

  @override
  Stream<SitewiseAccount?> get changes => _client.auth.onAuthStateChange.map((
    AuthState state,
  ) {
    final session = state.session;
    if (session == null) return null;
    return SitewiseAccount(
      userId: session.user.id,
      email: session.user.email,
      expiresAt: session.expiresAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              session.expiresAt! * 1000,
              isUtc: true,
            ),
    );
  });

  @override
  Future<SitewiseAccount> signInWithPassword({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      final user = response.user;
      if (user == null) {
        throw const SitewiseAuthException(
          'The sign-in did not return an account. Check the email and password.',
        );
      }
      final account = SitewiseAccount(
        userId: user.id,
        email: user.email,
        expiresAt: response.session?.expiresAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                response.session!.expiresAt! * 1000,
                isUtc: true,
              ),
      );
      return account.withRole(await fetchRole(user.id));
    } on AuthException catch (error) {
      throw SitewiseAuthException(error.message);
    }
  }

  @override
  Future<void> signOut() => _client.auth.signOut();

  @override
  Future<AppRole?> fetchRole(String userId) async {
    try {
      // RLS decides whether this row is readable. A user may read their own
      // profile; an administrator may read anyone's. Anything else returns no
      // row, and "no role" is handled as least privilege, never as admin.
      final row = await _client
          .from(usersTable)
          .select(roleColumn)
          .eq(userIdColumn, userId)
          .maybeSingle();
      if (row == null) return null;
      return AppRole.fromWire(row[roleColumn] as String?);
    } catch (error) {
      debugPrint('SITEWISE_AUTH: role lookup failed: $error');
      return null;
    }
  }
}
