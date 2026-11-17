"""The authoritative four-role model for SiteWise.

## Why this module exists

The backend previously knew three roles and normalised the legacy spelling
``property_owner`` onto ``entrepreneur``. Property Owner is now its own role, so
that mapping had to go: an owner folded into ``entrepreneur`` has no property
authority at all, and the two roles have completely different rights.

The canonical database values are ``admin``, ``owner``, ``agent`` and
``entrepreneur``. ``owner`` matches the shared Dart ``AppRole.owner``; the UI
calls it "Property Owner".

## The rule that matters

**A role never grants access to a property on its own.** Every property-level
decision takes the role *and* the verified relationship, because
"owner" means nothing without an ownership record and "agent" means nothing
without an assignment. Passing only the role is the bug this module is shaped to
prevent — there is no overload that accepts a role alone.

## Where it is used

``backend/src/sitewise/domain/rbac.py`` in the FYP repository is the same module;
this copy lives beside the capture backend so it can be imported, tested and
reviewed in this repository. The two must not diverge: the permission names are
also written into the Flutter client's ``SitewisePermission`` enum, and a rename
in one place is a silent authorisation change in the other.

## Not executed here

Nothing in this module talks to a database. It is the decision procedure; the
repository layer resolves ``PropertyRelationship`` from real rows, and the RLS
policies in ``supabase/migrations`` enforce the same rules a second time, in the
database, for clients that never call this API.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass

__all__ = [
    "AccessDecision",
    "Permission",
    "PropertyRelationship",
    "Role",
    "can",
    "can_capture_panorama",
    "can_change_role",
    "can_manage_agent_accounts",
    "can_manage_property",
    "can_upload_panorama",
    "normalize_role",
    "permissions_for",
    "require_permission",
    "require_property_access",
    "resolve_effective_role",
    "resolve_relationship",
]


class Role(enum.StrEnum):
    """The four authoritative roles.

    ``StrEnum`` so a value can be compared with a database string directly
    without an ``.value`` dance that someone will eventually forget.
    """

    admin = "admin"
    owner = "owner"
    agent = "agent"
    entrepreneur = "entrepreneur"

    @property
    def display_name(self) -> str:
        """The name the UI shows. Never the database value."""
        return _DISPLAY_NAMES[self]

    @property
    def is_staff(self) -> bool:
        """Whether the role belongs to the staff surface (MFA applies).

        Owners and entrepreneurs are deliberately excluded: they must not
        inherit staff administrative permissions.
        """
        return self in (Role.admin, Role.agent)


_DISPLAY_NAMES: dict[Role, str] = {
    Role.admin: "Administrator",
    Role.owner: "Property Owner",
    Role.agent: "Property Agent",
    Role.entrepreneur: "F&B Entrepreneur",
}

#: Spellings that older clients, migrations or imports may still send.
#:
#: ``property_owner`` is the one that matters: it always meant the owner of a
#: property, and it used to be folded onto ``entrepreneur``. It now resolves to
#: :attr:`Role.owner`. This is *parsing*, not promotion — no account is
#: reclassified by reading its own value back.
LEGACY_ROLE_ALIASES: dict[str, Role] = {
    "property_owner": Role.owner,
    "propertyowner": Role.owner,
    "property owner": Role.owner,
    "landlord": Role.owner,
    "administrator": Role.admin,
    "property_agent": Role.agent,
    "f&b_entrepreneur": Role.entrepreneur,
    "fb_entrepreneur": Role.entrepreneur,
}


def normalize_role(value: object) -> Role | None:
    """Parse a stored or transmitted role, or ``None`` when it is not one.

    ``None`` rather than a default is deliberate: a caller that receives an
    unreadable role must decide explicitly what to do, and the only safe answer
    is the least privileged one (see :func:`resolve_effective_role`). Coercing an
    unknown string to ``admin`` — or to ``entrepreneur`` — inside this function
    would hide the problem at the point where it is cheapest to notice.
    """
    if value is None:
        return None
    if isinstance(value, Role):
        return value
    text = str(value).strip().lower().replace("-", "_")
    if not text:
        return None
    try:
        return Role(text)
    except ValueError:
        return LEGACY_ROLE_ALIASES.get(text)


class Permission(enum.StrEnum):
    """What a role may attempt. Mirrors the Flutter ``SitewisePermission``."""

    view_own_profile = "view_own_profile"
    manage_own_property = "manage_own_property"
    capture_panorama = "capture_panorama"
    upload_panorama = "upload_panorama"
    view_published_panorama = "view_published_panorama"
    change_user_role = "change_user_role"
    manage_agent_accounts = "manage_agent_accounts"


_COMMON = frozenset(
    {
        Permission.view_own_profile,
        Permission.view_published_panorama,
    }
)

ROLE_PERMISSIONS: dict[Role, frozenset[Permission]] = {
    Role.admin: _COMMON
    | {
        Permission.manage_own_property,
        Permission.capture_panorama,
        Permission.upload_panorama,
        Permission.change_user_role,
        Permission.manage_agent_accounts,
    },
    Role.owner: _COMMON
    | {
        Permission.manage_own_property,
        Permission.capture_panorama,
        Permission.upload_panorama,
    },
    Role.agent: _COMMON
    | {
        Permission.manage_own_property,
        Permission.capture_panorama,
        Permission.upload_panorama,
    },
    # An entrepreneur may capture and upload only for a property they are
    # explicitly authorised for, which is a property-level decision. At the role
    # level they are therefore *not* granted `manage_own_property`: that
    # permission means "this role may manage a property it is entitled to",
    # and an entrepreneur's entitlement is never implied.
    Role.entrepreneur: _COMMON
    | {
        Permission.capture_panorama,
        Permission.upload_panorama,
    },
}


def permissions_for(role: Role) -> frozenset[Permission]:
    """The role-level permission set."""
    return ROLE_PERMISSIONS[role]


def can(role: Role, permission: Permission) -> bool:
    """Whether ``role`` holds ``permission`` at the role level."""
    return permission in ROLE_PERMISSIONS[role]


class PermissionDenied(PermissionError):
    """Raised when a decision is a refusal.

    Carries the user-safe reason so the API layer can turn it into a 403 without
    inventing a message, and without leaking ids.
    """

    def __init__(self, decision: AccessDecision) -> None:
        super().__init__(decision.reason)
        self.decision = decision


class PropertyRelationship(enum.StrEnum):
    """How the signed-in account relates to one specific property.

    Resolved from real rows by the repository layer. Never inferred from a
    session id, a query parameter or a client-supplied property id.
    """

    none = "none"
    owned = "owned"
    assigned_agent = "assigned_agent"
    explicit_grant = "explicit_grant"
    administrator = "administrator"


@dataclass(frozen=True, slots=True)
class AccessDecision:
    """The result of an authorisation question, with a reason."""

    allowed: bool
    reason: str

    def __bool__(self) -> bool:
        return self.allowed

    @classmethod
    def allow(cls, reason: str) -> AccessDecision:
        return cls(True, reason)

    @classmethod
    def deny(cls, reason: str) -> AccessDecision:
        return cls(False, reason)


def resolve_relationship(
    *,
    role: Role,
    owns_property: bool = False,
    is_assigned_agent: bool = False,
    has_explicit_grant: bool = False,
) -> PropertyRelationship:
    """Build the relationship from verified repository facts.

    The order encodes precedence, not preference: an administrator acting
    administratively is recorded as such even if they also happen to own the
    property, because the audit trail should say which capacity was used.
    """
    if role is Role.admin:
        return PropertyRelationship.administrator
    if owns_property:
        return PropertyRelationship.owned
    if is_assigned_agent:
        return PropertyRelationship.assigned_agent
    if has_explicit_grant:
        return PropertyRelationship.explicit_grant
    return PropertyRelationship.none


def can_manage_property(
    role: Role, relationship: PropertyRelationship
) -> AccessDecision:
    """Whether ``role`` may manage a property with this verified relationship.

    This is the function every property-scoped endpoint must call. It is the same
    matrix the database enforces in
    ``public.sitewise_can_manage_property(bigint)``.
    """
    if relationship is PropertyRelationship.administrator:
        if role is Role.admin:
            return AccessDecision.allow("Administrator access.")
        # Someone claiming the administrative relationship without being an
        # administrator is not an administrator.
        return AccessDecision.deny(
            "Only an administrator may act administratively on a property."
        )

    if role is Role.admin:
        # An administrator with no verified relationship: refuse rather than
        # assume. The relationship is the proof, not the role.
        return AccessDecision.deny(
            "No verified administrative relationship with this property."
        )

    if role is Role.owner:
        if relationship is PropertyRelationship.owned:
            return AccessDecision.allow("You own this property.")
        return AccessDecision.deny("This property is not registered to your account.")

    if role is Role.agent:
        if relationship is PropertyRelationship.assigned_agent:
            return AccessDecision.allow("You are assigned to this property.")
        return AccessDecision.deny("You are not assigned to this property.")

    # Entrepreneur.
    if relationship is PropertyRelationship.explicit_grant:
        return AccessDecision.allow("You are authorised for this property.")
    return AccessDecision.deny(
        "An entrepreneur needs an explicit authorisation for this property."
    )


def can_capture_panorama(
    role: Role, relationship: PropertyRelationship
) -> AccessDecision:
    """Capture follows the property rules exactly."""
    return can_manage_property(role, relationship)


def can_upload_panorama(
    role: Role, relationship: PropertyRelationship
) -> AccessDecision:
    """Upload is the strictest of the three.

    It is the operation the Storage policy enforces, and the one that puts bytes
    in a folder. An unassociated panorama is never uploaded: there is no folder
    that is legitimately its own.
    """
    if relationship is PropertyRelationship.none:
        return AccessDecision.deny(
            "This capture is not linked to a property you may write to."
        )
    return can_manage_property(role, relationship)


def can_change_role(actor: Role) -> bool:
    """Only an administrator may change a role."""
    return can(actor, Permission.change_user_role)


def can_manage_agent_accounts(actor: Role) -> bool:
    """Only an administrator may manage agent accounts."""
    return can(actor, Permission.manage_agent_accounts)


def require_permission(role: Role, permission: Permission) -> None:
    """Raise :class:`PermissionDenied` unless ``role`` holds ``permission``."""
    if not can(role, permission):
        raise PermissionDenied(
            AccessDecision.deny(
                f"The {role.display_name} role may not perform this action."
            )
        )


def require_property_access(role: Role, relationship: PropertyRelationship) -> None:
    """Raise :class:`PermissionDenied` unless the property decision allows it."""
    decision = can_manage_property(role, relationship)
    if not decision.allowed:
        raise PermissionDenied(decision)


def resolve_effective_role(
    *,
    server_role: object,
    cached_role: object = None,
) -> Role:
    """The role to act on when a client also holds a cached one.

    The rule is **never escalate**: the effective role is the less privileged of
    the server's answer and the cached one, and a missing server answer yields
    the least privileged role. A stale cache can therefore cost a user controls
    they do have, but can never grant one they do not.
    """
    server = normalize_role(server_role)
    if server is None:
        return Role.entrepreneur
    cached = normalize_role(cached_role)
    if cached is None:
        return server
    return min(cached, server, key=_administrative_breadth)


def _administrative_breadth(role: Role) -> int:
    """How much administrative reach a role has.

    Not a statement about property authority — an owner outranks an agent over
    their own building — only about which role does more damage if it is wrong.
    """
    return {
        Role.entrepreneur: 0,
        Role.owner: 1,
        Role.agent: 2,
        Role.admin: 3,
    }[role]
