import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/app_role.dart';

void main() {
  group('the four authoritative roles', () {
    test('are exactly admin, owner, agent and entrepreneur', () {
      expect(
        AppRole.values.map((AppRole r) => r.wireName).toList(),
        <String>['admin', 'owner', 'agent', 'entrepreneur'],
      );
    });

    test('parse from their canonical wire values', () {
      expect(AppRole.fromWire('admin'), AppRole.admin);
      expect(AppRole.fromWire('owner'), AppRole.owner);
      expect(AppRole.fromWire('agent'), AppRole.agent);
      expect(AppRole.fromWire('entrepreneur'), AppRole.entrepreneur);
    });

    test('display Property Owner, not the raw value', () {
      expect(AppRole.owner.displayName, 'Property Owner');
      expect(AppRole.entrepreneur.displayName, 'F&B Entrepreneur');
      expect(AppRole.agent.displayName, 'Property Agent');
      expect(AppRole.admin.displayName, 'Administrator');
    });

    test('canonical value for Property Owner is `owner`', () {
      // The shared Dart AppRole already spells it `owner`; the database had to
      // agree, which is what the migration changes.
      expect(AppRole.owner.toWire(), 'owner');
    });
  });

  group('legacy normalisation', () {
    test('property_owner maps to owner, never entrepreneur', () {
      // The old three-role backend folded `property_owner` onto `entrepreneur`.
      // Leaving that in place would make the new role unreachable from every
      // legacy account and silently strip owners of their property rights.
      expect(AppRole.fromWire('property_owner'), AppRole.owner);
      expect(AppRole.fromWire('property-owner'), AppRole.owner);
      expect(AppRole.fromWire('Property Owner'), AppRole.owner);
    });

    test('accepts display spellings from older web builds', () {
      expect(AppRole.fromWire('Administrator'), AppRole.admin);
      expect(AppRole.fromWire('property_agent'), AppRole.agent);
    });

    test('an unknown role is null, never a privileged guess', () {
      expect(AppRole.fromWire('superuser'), isNull);
      expect(AppRole.fromWire(''), isNull);
      expect(AppRole.fromWire(null), isNull);
      // The fallback used when reading a profile is the least privileged role.
      expect(AppRole.parseOrDefault('superuser'), AppRole.entrepreneur);
    });

    test('staff flags exclude owner and entrepreneur', () {
      expect(AppRole.admin.isStaff, isTrue);
      expect(AppRole.agent.isStaff, isTrue);
      // Owners and entrepreneurs must not inherit staff administration.
      expect(AppRole.owner.isStaff, isFalse);
      expect(AppRole.entrepreneur.isStaff, isFalse);
    });
  });

  group('role permissions', () {
    test('only an administrator may change a role or manage agents', () {
      for (final role in AppRole.values) {
        final allowed = SitewiseAuthorizer.can(
          role,
          SitewisePermission.changeUserRole,
        );
        expect(
          allowed,
          role == AppRole.admin,
          reason: '${role.wireName} changing roles',
        );
        expect(
          SitewiseAuthorizer.can(role, SitewisePermission.manageAgentAccounts),
          role == AppRole.admin,
        );
      }
    });

    test('every role may view its own profile and published panoramas', () {
      for (final role in AppRole.values) {
        expect(SitewiseAuthorizer.can(role, SitewisePermission.viewOwnProfile), isTrue);
        expect(
          SitewiseAuthorizer.can(role, SitewisePermission.viewPublishedPanorama),
          isTrue,
        );
      }
    });

    test('entrepreneur cannot manage a property by role alone', () {
      expect(
        SitewiseAuthorizer.can(
          AppRole.entrepreneur,
          SitewisePermission.manageOwnProperty,
        ),
        isFalse,
      );
    });
  });

  group('property-level authorisation', () {
    test('a role never grants an unrelated property', () {
      for (final role in <AppRole>[
        AppRole.owner,
        AppRole.agent,
        AppRole.entrepreneur,
      ]) {
        final decision = SitewiseAuthorizer.canManageProperty(
          role: role,
          relationship: PropertyRelationship.none,
        );
        expect(decision.allowed, isFalse, reason: '${role.wireName} with none');
      }
    });

    test('owner manages only owned properties', () {
      expect(
        SitewiseAuthorizer.canManageProperty(
          role: AppRole.owner,
          relationship: PropertyRelationship.owned,
        ).allowed,
        isTrue,
      );
      expect(
        SitewiseAuthorizer.canManageProperty(
          role: AppRole.owner,
          relationship: PropertyRelationship.assignedAgent,
        ).allowed,
        isFalse,
      );
    });

    test('agent needs a verified assignment', () {
      expect(
        SitewiseAuthorizer.canManageProperty(
          role: AppRole.agent,
          relationship: PropertyRelationship.assignedAgent,
        ).allowed,
        isTrue,
      );
      expect(
        SitewiseAuthorizer.canManageProperty(
          role: AppRole.agent,
          relationship: PropertyRelationship.owned,
        ).allowed,
        isFalse,
      );
    });

    test('entrepreneur needs an explicit grant', () {
      expect(
        SitewiseAuthorizer.canManageProperty(
          role: AppRole.entrepreneur,
          relationship: PropertyRelationship.explicitGrant,
        ).allowed,
        isTrue,
      );
      expect(
        SitewiseAuthorizer.canManageProperty(
          role: AppRole.entrepreneur,
          relationship: PropertyRelationship.owned,
        ).allowed,
        isFalse,
      );
    });

    test('administrator acts through the administrative relationship', () {
      expect(
        SitewiseAuthorizer.canManageProperty(
          role: AppRole.admin,
          relationship: PropertyRelationship.administrator,
        ).allowed,
        isTrue,
      );
      // Admin with no verified relationship is still refused: the label does
      // not create the link.
      expect(
        SitewiseAuthorizer.canManageProperty(
          role: AppRole.admin,
          relationship: PropertyRelationship.none,
        ).allowed,
        isFalse,
      );
      // And a non-admin cannot claim the administrative relationship.
      expect(
        SitewiseAuthorizer.canManageProperty(
          role: AppRole.owner,
          relationship: PropertyRelationship.administrator,
        ).allowed,
        isFalse,
      );
    });

    test('upload is at least as strict as capture', () {
      for (final role in AppRole.values) {
        for (final relationship in PropertyRelationship.values) {
          final capture = SitewiseAuthorizer.canCapturePanorama(
            role: role,
            relationship: relationship,
          );
          final upload = SitewiseAuthorizer.canUploadPanorama(
            role: role,
            relationship: relationship,
          );
          if (upload.allowed) {
            expect(
              capture.allowed,
              isTrue,
              reason: '${role.wireName}/${relationship.name}: upload implies '
                  'capture',
            );
          }
        }
      }
    });
  });

  group('cached roles', () {
    test('the server role wins over a cached one', () {
      expect(
        SitewiseAuthorizer.resolveEffectiveRole(
          serverRole: 'entrepreneur',
          cachedRole: 'admin',
        ),
        AppRole.entrepreneur,
      );
    });

    test('a cached privileged role is not used when the server is silent', () {
      // A stale local cache must never be the reason someone sees admin
      // controls; the fallback is the least privileged role.
      expect(
        SitewiseAuthorizer.resolveEffectiveRole(
          serverRole: null,
          cachedRole: 'admin',
        ),
        AppRole.entrepreneur,
      );
    });
  });
}
