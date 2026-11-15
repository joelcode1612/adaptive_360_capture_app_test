/// The four authoritative SiteWise roles.
///
/// ## Why this file exists in the capture app
///
/// The capture app has to answer one question before it uploads anything:
/// *may this account manage this property?* It must answer it with the same
/// vocabulary the database uses, or the two will disagree exactly where it
/// matters. The canonical values here are the database's values —
/// `admin`, `owner`, `agent`, `entrepreneur` — and [AppRole.wireName] is the
/// only string that may ever be written to `public.users.role`.
///
/// ## The legacy mapping that must not survive
///
/// The old three-role model had no Property Owner. It normalised
/// `property_owner` onto `entrepreneur`, which is now wrong twice over: it
/// demotes a real owner to a role that has no property rights, and it makes a
/// distinct role indistinguishable from an F&B entrepreneur. [AppRole.fromWire]
/// therefore resolves `property_owner` to [AppRole.owner]. The backend and the
/// database CHECK constraint were changed in the same change set; see
/// `supabase/migrations/20261116120000_sitewise_four_role_model.sql`.
///
/// This is *parsing*, not promotion. Nothing here converts an existing account:
/// an account whose stored value is `entrepreneur` stays an entrepreneur until
/// an administrator changes it.
library;

enum AppRole {
  admin(
    wireName: 'admin',
    displayName: 'Administrator',
    isStaff: true,
    description: 'Full administrative control, including roles and agents.',
  ),
  owner(
    wireName: 'owner',
    displayName: 'Property Owner',
    description: 'Manages the properties they own and their panoramas.',
  ),
  agent(
    wireName: 'agent',
    displayName: 'Property Agent',
    isStaff: true,
    description: 'Manages only the properties they are verifiably assigned to.',
  ),
  entrepreneur(
    wireName: 'entrepreneur',
    displayName: 'F&B Entrepreneur',
    description: 'Views published panoramas; writes only when explicitly '
        'authorised for a property.',
  );

  const AppRole({
    required this.wireName,
    required this.displayName,
    required this.description,
    this.isStaff = false,
  });

  /// The canonical database value. Never a display name.
  final String wireName;

  /// What the UI calls this role. `Property Owner`, not `owner`.
  final String displayName;

  final String description;

  /// Whether the role belongs to the staff surface (admin/agent MFA applies).
  ///
  /// [AppRole.owner] and [AppRole.entrepreneur] are deliberately **not** staff:
  /// they must never inherit staff administrative permissions, which is why
  /// this flag exists rather than a "not entrepreneur" test scattered around.
  final bool isStaff;

  /// The role's default landing surface after sign-in.
  bool get isAdministrator => this == AppRole.admin;

  /// Parses a stored or transmitted role value.
  ///
  /// Accepts the canonical values, the legacy `property_owner` alias, and the
  /// display spellings that older Jaspr/Flutter builds may still send. Returns
  /// `null` for anything unrecognised — an unknown role must never be silently
  /// coerced into a privileged one.
  static AppRole? fromWire(String? value) {
    if (value == null) return null;
    final normalised = value.trim().toLowerCase().replaceAll('-', '_');
    if (normalised.isEmpty) return null;
    for (final role in AppRole.values) {
      if (role.wireName == normalised) return role;
    }
    switch (normalised) {
      // The pre-four-role spelling. It always meant "the owner of the
      // property", never "an entrepreneur", so it maps to [owner].
      case 'property_owner':
      case 'propertyowner':
      case 'property owner':
      case 'landlord':
        return AppRole.owner;
      case 'administrator':
        return AppRole.admin;
      case 'property_agent':
        return AppRole.agent;
      case 'f&b_entrepreneur':
      case 'fb_entrepreneur':
        return AppRole.entrepreneur;
      default:
        return null;
    }
  }

  /// The wire value to persist for a role chosen in a UI.
  ///
  /// Exists so callers cannot accidentally send [displayName] to the database.
  String toWire() => wireName;

  static AppRole parseOrDefault(String? value) =>
      fromWire(value) ?? AppRole.entrepreneur;
}

/// What a caller is allowed to do. Mirrors `Permission` in the FastAPI RBAC
/// module so the two layers cannot drift apart in naming.
enum SitewisePermission {
  viewOwnProfile('view_own_profile'),
  manageOwnProperty('manage_own_property'),
  capturePanorama('capture_panorama'),
  uploadPanorama('upload_panorama'),
  viewPublishedPanorama('view_published_panorama'),
  changeUserRole('change_user_role'),
  manageAgentAccounts('manage_agent_accounts');

  const SitewisePermission(this.wireName);

  final String wireName;
}

/// How the signed-in account relates to one specific property.
///
/// This is the *verified* relationship, resolved server-side (or from a
/// server-provided row). It is never inferred from the presence of a session id
/// or a client-supplied property id.
enum PropertyRelationship {
  /// No verified link between this account and this property.
  none,

  /// `public.property.owner_id` (or equivalent) names this account.
  owned,

  /// An existing verified agent assignment covers this property.
  assignedAgent,

  /// An explicit, per-property grant to an entrepreneur or other account.
  explicitGrant,

  /// The account is an administrator acting in an administrative capacity.
  administrator,
}

/// The outcome of an authorization question, with a reason for the UI and logs.
class PropertyAccessDecision {
  const PropertyAccessDecision.allow(this.reason) : allowed = true;

  const PropertyAccessDecision.deny(this.reason) : allowed = false;

  final bool allowed;

  /// A short, user-safe sentence. Never contains ids or tokens.
  final String reason;

  @override
  String toString() => '${allowed ? 'allow' : 'deny'}: $reason';
}

/// The client-side half of the four-role model.
///
/// The database and FastAPI remain authoritative — this only decides what the
/// app offers, so a stale client cannot present a control the server would
/// refuse, and a permissive client gains nothing by trying.
abstract final class SitewiseAuthorizer {
  /// The role-level permission set, exactly as the backend defines it.
  static Set<SitewisePermission> permissionsFor(AppRole role) {
    switch (role) {
      case AppRole.admin:
        return const <SitewisePermission>{
          SitewisePermission.viewOwnProfile,
          SitewisePermission.manageOwnProperty,
          SitewisePermission.capturePanorama,
          SitewisePermission.uploadPanorama,
          SitewisePermission.viewPublishedPanorama,
          SitewisePermission.changeUserRole,
          SitewisePermission.manageAgentAccounts,
        };
      case AppRole.owner:
        return const <SitewisePermission>{
          SitewisePermission.viewOwnProfile,
          SitewisePermission.manageOwnProperty,
          SitewisePermission.capturePanorama,
          SitewisePermission.uploadPanorama,
          SitewisePermission.viewPublishedPanorama,
        };
      case AppRole.agent:
        return const <SitewisePermission>{
          SitewisePermission.viewOwnProfile,
          SitewisePermission.manageOwnProperty,
          SitewisePermission.capturePanorama,
          SitewisePermission.uploadPanorama,
          SitewisePermission.viewPublishedPanorama,
        };
      case AppRole.entrepreneur:
        return const <SitewisePermission>{
          SitewisePermission.viewOwnProfile,
          SitewisePermission.capturePanorama,
          SitewisePermission.uploadPanorama,
          SitewisePermission.viewPublishedPanorama,
        };
    }
  }

  static bool can(AppRole role, SitewisePermission permission) =>
      permissionsFor(role).contains(permission);

  /// Whether [role] may manage (and therefore attach a panorama to) a property
  /// with the verified [relationship].
  ///
  /// A role never grants access on its own: `owner` with
  /// [PropertyRelationship.none] is denied, and so is `agent` without an
  /// assignment. That is the whole point of passing the relationship in.
  static PropertyAccessDecision canManageProperty({
    required AppRole role,
    required PropertyRelationship relationship,
  }) {
    if (relationship == PropertyRelationship.administrator) {
      return role == AppRole.admin
          ? const PropertyAccessDecision.allow('Administrator access.')
          : const PropertyAccessDecision.deny(
              'Only an administrator may act administratively on a property.',
            );
    }
    switch (role) {
      case AppRole.admin:
        // An administrator acting on a property with no verified link still
        // needs the administrative relationship; the caller resolves that.
        return const PropertyAccessDecision.deny(
          'No verified administrative relationship with this property.',
        );
      case AppRole.owner:
        return relationship == PropertyRelationship.owned
            ? const PropertyAccessDecision.allow('You own this property.')
            : const PropertyAccessDecision.deny(
                'This property is not registered to your account.',
              );
      case AppRole.agent:
        return relationship == PropertyRelationship.assignedAgent
            ? const PropertyAccessDecision.allow(
                'You are assigned to this property.',
              )
            : const PropertyAccessDecision.deny(
                'You are not assigned to this property.',
              );
      case AppRole.entrepreneur:
        return relationship == PropertyRelationship.explicitGrant
            ? const PropertyAccessDecision.allow(
                'You are authorised for this property.',
              )
            : const PropertyAccessDecision.deny(
                'An entrepreneur needs an explicit authorisation for this '
                'property.',
              );
    }
  }

  /// Capture follows the same property rules as management: the shutter may
  /// run for a property the account is allowed to write to, and only that one.
  static PropertyAccessDecision canCapturePanorama({
    required AppRole role,
    required PropertyRelationship relationship,
  }) => canManageProperty(role: role, relationship: relationship);

  /// Upload is the operation the Storage policy enforces, so it is the strictest
  /// of the three: an unassociated panorama is never uploaded into a property
  /// folder.
  static PropertyAccessDecision canUploadPanorama({
    required AppRole role,
    required PropertyRelationship relationship,
  }) => canManageProperty(role: role, relationship: relationship);

  /// Only an administrator may change a role, and never through this client:
  /// the app has no write path to `public.users.role` at all. This predicate
  /// exists so the UI can hide the control rather than fail at the server.
  static bool canChangeUserRole(AppRole actor) =>
      can(actor, SitewisePermission.changeUserRole);

  /// Rejects a role the client claims but the session does not support.
  ///
  /// Used when restoring a cached role from local storage. The rule is **never
  /// escalate**: the effective role is the less privileged of the server's
  /// answer and the cached one, and a missing server answer yields the least
  /// privileged role. A stale cache can therefore cost a user controls they do
  /// have, but can never hand them one they do not.
  static AppRole resolveEffectiveRole({
    required String? serverRole,
    required String? cachedRole,
  }) {
    final server = AppRole.fromWire(serverRole);
    if (server == null) {
      // No usable server answer. The cache is client-side state and must not be
      // the reason anyone sees administrative controls.
      return AppRole.entrepreneur;
    }
    final cached = AppRole.fromWire(cachedRole);
    if (cached == null) return server;
    return _administrativeBreadth(cached) < _administrativeBreadth(server)
        ? cached
        : server;
  }

  /// How much administrative reach a role has. Not a statement about property
  /// authority — an owner outranks an agent over their own building — only about
  /// which role can do more damage if it is wrong.
  static int _administrativeBreadth(AppRole role) => switch (role) {
    AppRole.entrepreneur => 0,
    AppRole.owner => 1,
    AppRole.agent => 2,
    AppRole.admin => 3,
  };
}
