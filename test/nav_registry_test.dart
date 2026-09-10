import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:helloworld/core/nav_registry.dart';
import 'package:helloworld/core/theme.dart';
import 'package:helloworld/models/college_settings.dart';
import 'package:helloworld/core/permissions.dart';
import 'package:helloworld/core/session.dart';
import 'package:helloworld/models/app_role.dart';
import 'package:helloworld/models/app_user.dart';

/// The one architectural rule: there is a single dashboard, and the only
/// difference between what two people see is which nav entries survive the
/// permission filter.
///
/// Worth locking down in a test because it is the rule most likely to be
/// broken by accident — one `if (role == 'Warden')` slipped into a page and
/// the whole design quietly stops holding. These assertions fail loudly if
/// permissions stop driving navigation.

AppUser _user({bool superAdmin = false}) => AppUser(
  uid: 'u1',
  name: 'Test Person',
  email: 'test@example.com',
  collegeId: 'c1',
  isSuperAdmin: superAdmin,
);

Session _session(List<String> perms, {bool superAdmin = false}) => Session(
  user: _user(superAdmin: superAdmin),
  role: AppRole(id: 'r1', name: 'Test Role', permissions: perms.toSet()),
  collegeName: 'Test College',
);

Set<String> _ids(Session s) =>
    navigationFor(s).expand((sec) => sec.items).map((i) => i.id).toSet();

void main() {
  group('navigationFor', () {
    test('a user with no permissions still gets the unguarded entries', () {
      final ids = _ids(_session([]));
      // Dashboard and My Profile declare no `requires`, so they are always on.
      expect(ids, containsAll(<String>['overview', 'profile']));
      expect(ids, isNot(contains('users')));
      expect(ids, isNot(contains('fines')));
    });

    test('a Super Admin sees every entry', () {
      final ids = _ids(_session(const [], superAdmin: true));
      // can() short-circuits on isSuperAdmin, so an empty role still opens
      // everything. This is exactly why testing as Super Admin never
      // exercises the permission branches.
      expect(ids, contains('users'));
      expect(ids, contains('fines'));
      expect(ids, contains('office-orders'));
      expect(ids, contains('settings'));
    });

    test('a permission opens exactly its own entry and nothing else', () {
      final ids = _ids(_session([Perm.hostelsView]));
      expect(ids, contains('hostels'));
      expect(ids, isNot(contains('allotment')));
      expect(ids, isNot(contains('users')));
    });

    test('an entry listing several permissions needs only one of them', () {
      // Fines declares [finesViewAll, finesViewOwn]; a student holding just
      // viewOwn must still reach the page.
      expect(_ids(_session([Perm.finesViewOwn])), contains('fines'));
      expect(_ids(_session([Perm.finesViewAll])), contains('fines'));
    });

    test('a self-service entry hides from the people who manage it', () {
      // My Room is for residents. A Super Admin's can() short-circuits to
      // true for self.room, so without `excludes` the workspace owner was
      // shown a room they will never be allotted.
      expect(_ids(_session([Perm.selfRoom])), contains('my-room'));
      expect(
        _ids(_session([Perm.selfRoom, Perm.allotmentManage])),
        isNot(contains('my-room')),
      );
      expect(
        _ids(_session(const [], superAdmin: true)),
        isNot(contains('my-room')),
      );
    });

    test('excluding an entry does not disturb its neighbours', () {
      final ids = _ids(_session([Perm.selfRoom, Perm.allotmentManage]));
      expect(ids, contains('allotment'));
      expect(ids, contains('overview'));
    });

    test('a section disappears when none of its entries survive', () {
      final sections = navigationFor(_session([Perm.selfRoom]));
      final titles = sections.map((s) => s.title).toSet();
      expect(titles, isNot(contains('People')));
      // The Hostel section survives, because My Room is in it.
      expect(titles, contains('Hostel'));
    });

    test('a student role sees residents\' entries, not staff ones', () {
      final ids = _ids(_session(kRoleTemplates['Student']!));
      expect(
        ids,
        containsAll(<String>['my-room', 'mess', 'notices', 'requests', 'fines']),
      );
      expect(ids, isNot(contains('users')));
      expect(ids, isNot(contains('roles')));
      expect(ids, isNot(contains('allotment')));
      expect(ids, isNot(contains('settings')));
    });

    test('a warden role sees staff entries but not the workspace settings', () {
      final ids = _ids(_session(kRoleTemplates['Warden']!));
      expect(
        ids,
        containsAll(<String>['users', 'allotment', 'fines', 'office-orders']),
      );
      expect(ids, isNot(contains('settings')));
    });

    test('renaming a role changes nothing — only its permissions matter', () {
      // Same permissions, wildly different role names. If any page ever
      // branches on the name, these two stop matching.
      final asWarden = _ids(
        Session(
          user: _user(),
          role: AppRole(
            id: 'r1',
            name: 'Warden',
            permissions: kRoleTemplates['Warden']!.toSet(),
          ),
          collegeName: 'c',
        ),
      );
      final asSomethingElse = _ids(
        Session(
          user: _user(),
          role: AppRole(
            id: 'r2',
            name: 'Assistant Hostel Superintendent',
            permissions: kRoleTemplates['Warden']!.toSet(),
          ),
          collegeName: 'c',
        ),
      );
      expect(asWarden, asSomethingElse);
    });
  });

  group('palette', () {
    tearDown(() {
      // Tokens are global mutable state — leaving a test in dark mode would
      // silently change what every later test sees.
      AppColors.apply(accent: kThemePresets.first.color, dark: false);
    });

    test('light and dark produce genuinely different surfaces', () {
      AppColors.apply(accent: kThemePresets.first.color, dark: false);
      final lightCanvas = AppColors.canvas;
      final lightText = AppColors.textStrong;

      AppColors.apply(accent: kThemePresets.first.color, dark: true);
      expect(AppColors.canvas, isNot(lightCanvas));
      expect(AppColors.textStrong, isNot(lightText));
      expect(AppColors.isDark, isTrue);
    });

    test('dark mode inverts the text/background relationship', () {
      AppColors.apply(accent: kThemePresets.first.color, dark: true);
      // Text must be lighter than the card it sits on, or it is invisible.
      expect(
        AppColors.textStrong.computeLuminance(),
        greaterThan(AppColors.card.computeLuminance()),
      );

      AppColors.apply(accent: kThemePresets.first.color, dark: false);
      expect(
        AppColors.textStrong.computeLuminance(),
        lessThan(AppColors.card.computeLuminance()),
      );
    });

    test('the accent actually reaches the primary token', () {
      for (final p in kThemePresets) {
        AppColors.apply(accent: p.color, dark: false);
        expect(AppColors.primary, p.color, reason: p.label);
      }
    });

    test('every preset stays readable against white text', () {
      // The reason presets exist instead of a free colour picker.
      for (final p in kThemePresets) {
        expect(
          p.color.computeLuminance(),
          lessThan(0.5),
          reason: '${p.label} is too light to carry white button text',
        );
      }
    });
  });

  group('AppBrightness', () {
    test('system follows the device, the others do not', () {
      expect(AppBrightness.system.isDark(Brightness.dark), isTrue);
      expect(AppBrightness.system.isDark(Brightness.light), isFalse);
      expect(AppBrightness.dark.isDark(Brightness.light), isTrue);
      expect(AppBrightness.light.isDark(Brightness.dark), isFalse);
    });

    test('round-trips through the stored string', () {
      for (final b in AppBrightness.values) {
        expect(AppBrightnessX.parse(b.name), b);
      }
      expect(AppBrightnessX.parse(null), AppBrightness.light);
      expect(AppBrightnessX.parse('nonsense'), AppBrightness.light);
    });
  });

  group('permission catalogue', () {
    test('every permission a nav entry requires actually exists', () {
      final known = Perm.all.toSet();
      for (final section in navigationFor(
        _session(const [], superAdmin: true),
      )) {
        for (final item in section.items) {
          for (final perm in item.requires) {
            expect(
              known,
              contains(perm),
              reason:
                  'Nav entry "${item.id}" requires "$perm", which is not in '
                  'Perm.catalogue — it can never be granted to a role.',
            );
          }
        }
      }
    });

    test('no permission key is defined twice', () {
      final all = Perm.all;
      expect(all.toSet().length, all.length);
    });

    test('every role template grants only real permissions', () {
      final known = Perm.all.toSet();
      kRoleTemplates.forEach((role, perms) {
        for (final p in perms) {
          expect(known, contains(p), reason: '$role grants unknown "$p"');
        }
      });
    });
  });

  group('Perm.managesHostels', () {
    test('is true for every starter role that runs hostel operations', () {
      for (final role in ['Chief Warden', 'Warden', 'Caretaker', 'BHS']) {
        expect(
          Perm.managesHostels(kRoleTemplates[role]!.toSet()),
          isTrue,
          reason: '$role should be treated as a hostel-managing role',
        );
      }
    });

    test('is false for Student — residents don\'t manage hostels', () {
      expect(
        Perm.managesHostels(kRoleTemplates['Student']!.toSet()),
        isFalse,
      );
    });

    test('is a permission check, not a name check', () {
      // A custom role with none of the literal starter names, but holding
      // the same permission, must be treated identically — this is the
      // whole point of not branching on role.name in the user-creation form.
      expect(Perm.managesHostels({Perm.hostelsManage}), isTrue);
      expect(Perm.managesHostels({Perm.allotmentManage}), isTrue);
      expect(Perm.managesHostels({Perm.hostelsView}), isFalse);
      expect(Perm.managesHostels({}), isFalse);
    });
  });
}
