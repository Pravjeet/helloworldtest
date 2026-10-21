import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/core/session.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/models/college_settings.dart';

/// [Session.viewingSession] is a per-viewer lens, deliberately separate from
/// `settings.session.current` — the workspace's real operational session,
/// which Backfill and Promotion read. These pin the arithmetic that keeps
/// the two from ever being confused for one another.
void main() {
  AppUser user() => const AppUser(
    uid: 'u1',
    name: 'Test Admin',
    email: 'admin@x.test',
    collegeId: 'c1',
    isSuperAdmin: true,
  );

  Session sessionWith({String? current, String? viewing}) => Session(
    user: user(),
    collegeName: 'Test College',
    settings: CollegeSettings(
      session: AcademicSession(current: current),
    ),
    viewingSession: viewing,
  );

  group('effectiveSession', () {
    test('is the live session when nothing is being viewed', () {
      final s = sessionWith(current: '2026-27');
      expect(s.effectiveSession, '2026-27');
      expect(s.viewingSession, isNull);
    });

    test('is the viewed session when one is set', () {
      final s = sessionWith(current: '2026-27', viewing: '2025-26');
      expect(s.effectiveSession, '2025-26');
    });

    test('falls back to the live session when neither is set', () {
      final s = sessionWith();
      expect(s.effectiveSession, isNull);
    });
  });

  group('isViewingHistory', () {
    test('false when viewing nothing in particular', () {
      expect(sessionWith(current: '2026-27').isViewingHistory, isFalse);
    });

    test('false when the "viewed" session equals the live one', () {
      // The exact case the login screen's picker guards against: reselecting
      // the current session must read as "back to live", not as history.
      expect(
        sessionWith(
          current: '2026-27',
          viewing: '2026-27',
        ).isViewingHistory,
        isFalse,
      );
    });

    test('true when genuinely looking at a different session', () {
      expect(
        sessionWith(
          current: '2026-27',
          viewing: '2025-26',
        ).isViewingHistory,
        isTrue,
      );
    });
  });

  group('the lens never substitutes for the operational session', () {
    test('settings.session.current is unaffected by viewingSession', () {
      // This is the property the whole feature depends on: Backfill and
      // Promotion read settings.session.current directly, never
      // effectiveSession, so switching the lens must never move it.
      final s = sessionWith(current: '2026-27', viewing: '2025-26');
      expect(s.settings.session.current, '2026-27');
    });
  });
}
