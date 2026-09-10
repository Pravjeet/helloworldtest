import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/core/session.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/screens/pages/profile_page.dart';

/// Guards the button row this session's fix touched: moving "Change email"
/// out of the (disabled) email field's suffixIcon and into the button row
/// alongside "Change password" and "Email me a reset link" means that row
/// now holds four buttons instead of three — exactly the kind of Row that
/// has quietly overflowed twice already in this codebase this session (the
/// import dialog's paste-step buttons, and its own tally row).
void main() {
  Future<void> pump(WidgetTester tester, AppUser user, {double width = 900}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionScope(
            session: Session(user: user, collegeName: 'Test College'),
            child: const ProfilePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const superAdmin = AppUser(
    uid: 'admin1',
    name: 'Test Admin',
    email: 'admin@realcollege.edu',
    collegeId: 'test-college',
    isSuperAdmin: true,
  );

  const student = AppUser(
    uid: 'student1',
    name: 'Test Student',
    email: '24052@homihostel.local',
    collegeId: 'test-college',
  );

  testWidgets(
    'Change email is a standalone button, not tucked into the disabled field',
    (tester) async {
      await pump(tester, superAdmin);

      // The old placement (a TextButton inside the email field's suffixIcon,
      // labelled just "Change") is gone.
      expect(find.text('Change'), findsNothing);

      // All four actions render as their own buttons.
      expect(find.widgetWithText(ElevatedButton, 'Save changes'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Change password'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Change email'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Email me a reset link'),
        findsOneWidget,
      );

      // No layout overflow at a realistic dashboard content width.
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the new button row does not overflow at 900px', (tester) async {
    await pump(tester, superAdmin, width: 900);
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not overflow at the narrower 700px the page constrains itself to',
      (tester) async {
    await pump(tester, superAdmin, width: 700);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a synthetic (registration-number) login sees no email-change controls',
    (tester) async {
      await pump(tester, student);

      expect(find.widgetWithText(OutlinedButton, 'Change email'), findsNothing);
      expect(
        find.widgetWithText(OutlinedButton, 'Email me a reset link'),
        findsNothing,
      );
      // Still gets to change their password, and the field explains why
      // there's no email to change.
      expect(find.widgetWithText(OutlinedButton, 'Change password'), findsOneWidget);
      expect(
        find.textContaining('don\'t have an email to change'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the Change email button actually opens the dialog', (tester) async {
    await pump(tester, superAdmin);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Change email'));
    await tester.pumpAndSettle();

    expect(find.text('Change your email'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'New email'), findsOneWidget);
  });
}
