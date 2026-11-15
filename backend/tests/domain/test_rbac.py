"""Four-role authorisation tests.

These are the backend half of the same contract the Flutter tests cover in
``test/sitewise_sync/app_role_test.dart``. Both sides must agree, because the
client decides what to offer and the server decides what to allow — a divergence
shows up as a control that always fails, or worse, one that never does.

Nothing here touches a database: this is the decision procedure. The SQL side of
the same rules lives in ``supabase/migrations`` and is exercised separately.
"""

from __future__ import annotations

import pytest

from sitesense.domain.rbac import (
    ROLE_PERMISSIONS,
    AccessDecision,
    Permission,
    PermissionDenied,
    PropertyRelationship,
    Role,
    can,
    can_capture_panorama,
    can_change_role,
    can_manage_agent_accounts,
    can_manage_property,
    can_upload_panorama,
    normalize_role,
    permissions_for,
    require_permission,
    require_property_access,
    resolve_effective_role,
    resolve_relationship,
)


class TestRoleModel:
    def test_there_are_exactly_four_roles(self) -> None:
        assert [role.value for role in Role] == [
            "admin",
            "owner",
            "agent",
            "entrepreneur",
        ]

    def test_property_owner_is_displayed_as_property_owner(self) -> None:
        assert Role.owner.display_name == "Property Owner"
        assert Role.owner.value == "owner"

    def test_owner_and_entrepreneur_are_not_staff(self) -> None:
        assert Role.admin.is_staff
        assert Role.agent.is_staff
        assert not Role.owner.is_staff
        assert not Role.entrepreneur.is_staff

    @pytest.mark.parametrize(
        ("raw", "expected"),
        [
            ("admin", Role.admin),
            ("owner", Role.owner),
            ("agent", Role.agent),
            ("entrepreneur", Role.entrepreneur),
            ("ADMIN", Role.admin),
            (" owner ", Role.owner),
            (Role.agent, Role.agent),
        ],
    )
    def test_canonical_values_parse(self, raw: object, expected: Role) -> None:
        assert normalize_role(raw) is expected

    def test_property_owner_normalises_to_owner_not_entrepreneur(self) -> None:
        # The legacy three-role model folded this spelling onto entrepreneur.
        # Leaving that in place would make the new role unreachable from every
        # legacy account and strip real owners of their property rights.
        assert normalize_role("property_owner") is Role.owner
        assert normalize_role("property-owner") is Role.owner
        assert normalize_role("Property Owner") is Role.owner

    def test_unknown_roles_are_none_not_a_privileged_guess(self) -> None:
        assert normalize_role("superuser") is None
        assert normalize_role("") is None
        assert normalize_role(None) is None


class TestRolePermissions:
    def test_only_admin_may_change_a_role(self) -> None:
        for role in Role:
            assert can(role, Permission.change_user_role) is (role is Role.admin)
            assert can_change_role(role) is (role is Role.admin)

    def test_only_admin_may_manage_agent_accounts(self) -> None:
        for role in Role:
            assert can_manage_agent_accounts(role) is (role is Role.admin)

    def test_every_role_may_view_its_own_profile(self) -> None:
        for role in Role:
            assert can(role, Permission.view_own_profile)

    def test_every_role_may_view_published_panoramas(self) -> None:
        for role in Role:
            assert can(role, Permission.view_published_panorama)

    def test_entrepreneur_has_no_role_level_property_management(self) -> None:
        assert not can(Role.entrepreneur, Permission.manage_own_property)
        # ...but capture and upload exist as *permissions*, gated per property.
        assert can(Role.entrepreneur, Permission.capture_panorama)
        assert can(Role.entrepreneur, Permission.upload_panorama)

    def test_every_role_has_a_permission_set(self) -> None:
        assert set(ROLE_PERMISSIONS) == set(Role)
        for role in Role:
            assert permissions_for(role) == ROLE_PERMISSIONS[role]

    def test_require_permission_raises_with_a_safe_reason(self) -> None:
        with pytest.raises(PermissionDenied) as excinfo:
            require_permission(Role.owner, Permission.change_user_role)
        assert "Property Owner" in str(excinfo.value)
        # A refusal must not name ids or tokens.
        assert "uuid" not in str(excinfo.value).lower()


class TestPropertyAuthorisation:
    def test_a_role_alone_never_grants_an_unrelated_property(self) -> None:
        for role in (Role.owner, Role.agent, Role.entrepreneur, Role.admin):
            decision = can_manage_property(role, PropertyRelationship.none)
            assert decision.allowed is False
            assert not decision

    def test_owner_manages_only_owned_properties(self) -> None:
        assert can_manage_property(Role.owner, PropertyRelationship.owned).allowed
        assert not can_manage_property(
            Role.owner, PropertyRelationship.assigned_agent
        ).allowed
        assert not can_manage_property(
            Role.owner, PropertyRelationship.explicit_grant
        ).allowed

    def test_agent_requires_a_verified_assignment(self) -> None:
        assert can_manage_property(
            Role.agent, PropertyRelationship.assigned_agent
        ).allowed
        assert not can_manage_property(Role.agent, PropertyRelationship.owned).allowed
        assert not can_manage_property(Role.agent, PropertyRelationship.none).allowed

    def test_entrepreneur_requires_an_explicit_grant(self) -> None:
        assert can_manage_property(
            Role.entrepreneur, PropertyRelationship.explicit_grant
        ).allowed
        assert not can_manage_property(
            Role.entrepreneur, PropertyRelationship.owned
        ).allowed
        assert not can_manage_property(
            Role.entrepreneur, PropertyRelationship.assigned_agent
        ).allowed

    def test_administrator_relationship_is_admin_only(self) -> None:
        assert can_manage_property(
            Role.admin, PropertyRelationship.administrator
        ).allowed
        for role in (Role.owner, Role.agent, Role.entrepreneur):
            assert not can_manage_property(
                role, PropertyRelationship.administrator
            ).allowed

    def test_cross_property_access_is_refused(self) -> None:
        # The concrete scenario: an owner of property 12 tries to upload a
        # panorama for property 99, for which they have no relationship.
        decision = can_upload_panorama(Role.owner, PropertyRelationship.none)
        assert decision.allowed is False
        assert "not registered to your account" not in decision.reason
        with pytest.raises(PermissionDenied):
            require_property_access(Role.owner, PropertyRelationship.none)

    def test_upload_is_stricter_than_capture_for_unassociated_captures(self) -> None:
        # Capture of an unassociated panorama is a local act; uploading one is
        # not, because there is no folder it is legitimately allowed to occupy.
        assert (
            can_upload_panorama(Role.owner, PropertyRelationship.none).allowed is False
        )
        assert can_capture_panorama(Role.owner, PropertyRelationship.owned).allowed

    def test_every_uploadable_relationship_is_also_capturable(self) -> None:
        for role in Role:
            for relationship in PropertyRelationship:
                if can_upload_panorama(role, relationship).allowed:
                    assert can_capture_panorama(role, relationship).allowed


class TestRelationshipResolution:
    def test_admin_resolves_to_the_administrative_relationship(self) -> None:
        assert (
            resolve_relationship(role=Role.admin) is PropertyRelationship.administrator
        )

    def test_ownership_is_never_inferred_from_the_role(self) -> None:
        # An owner with no ownership record resolves to `none`, not `owned`.
        assert resolve_relationship(role=Role.owner) is PropertyRelationship.none

    def test_verified_facts_build_the_relationship(self) -> None:
        assert (
            resolve_relationship(role=Role.owner, owns_property=True)
            is PropertyRelationship.owned
        )
        assert (
            resolve_relationship(role=Role.agent, is_assigned_agent=True)
            is PropertyRelationship.assigned_agent
        )
        assert (
            resolve_relationship(role=Role.entrepreneur, has_explicit_grant=True)
            is PropertyRelationship.explicit_grant
        )


class TestClientRoleChanges:
    def test_a_cached_privileged_role_never_wins(self) -> None:
        assert (
            resolve_effective_role(server_role="entrepreneur", cached_role="admin")
            is Role.entrepreneur
        )

    def test_a_missing_server_role_falls_back_to_the_least_privileged(self) -> None:
        assert (
            resolve_effective_role(server_role=None, cached_role="admin")
            is Role.entrepreneur
        )
        assert (
            resolve_effective_role(server_role="nonsense", cached_role="owner")
            is Role.entrepreneur
        )

    def test_the_server_role_is_used_when_the_cache_is_silent(self) -> None:
        assert (
            resolve_effective_role(server_role="owner", cached_role=None) is Role.owner
        )

    def test_the_effective_role_never_exceeds_the_server_role(self) -> None:
        for server in Role:
            for cached in Role:
                effective = resolve_effective_role(
                    server_role=server.value, cached_role=cached.value
                )
                # Admin is reachable only when the server itself says admin.
                if effective is Role.admin:
                    assert server is Role.admin
                if server is Role.admin and cached is Role.admin:
                    assert effective is Role.admin


class TestAccountProvisioning:
    def test_ordinary_registration_defaults_to_entrepreneur(self) -> None:
        # The migration keeps the database default at `entrepreneur`; a new
        # account has no verified property, so it must not arrive as an owner.
        assert resolve_effective_role(server_role=None) is Role.entrepreneur

    def test_legacy_entrepreneur_rows_are_not_promoted(self) -> None:
        assert normalize_role("entrepreneur") is Role.entrepreneur

    def test_access_decisions_are_truthy_when_allowed(self) -> None:
        assert AccessDecision.allow("ok")
        assert not AccessDecision.deny("no")
