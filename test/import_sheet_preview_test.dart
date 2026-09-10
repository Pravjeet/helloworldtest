import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/app_role.dart';
import 'package:helloworld/screens/pages/import_students_dialog.dart';

/// Drives the import dialog from paste through to the spreadsheet preview.
///
/// Nothing here touches Firebase — only the run step does, and this stops
/// before it. That is what makes the preview testable at all, and it is worth
/// keeping that way.
void main() {
  const roles = [
    AppRole(id: 'student', name: 'Student', permissions: {'self.room'}),
  ];

  // Deliberately includes a column the importer does not know ("houseNo"),
  // a quoted value containing a comma, and a row that must be skipped.
  const pasted =
      'name,registrationNo,course,batch,address,houseNo\n'
      'Aarav Sharma,230001,B.E.,2023-27,"Ambala, Haryana",12-B\n'
      'Nidhi Chopra,240052,M.Sc,2025-27,"Patna, Bihar",7\n'
      'X,,B.E.,2026-30,,\n';

  Future<void> openPreview(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ImportStudentsDialog(
            collegeId: 'test-college',
            existingUsers: [],
            roles: roles,
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, pasted);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Preview'));
    await tester.pumpAndSettle();
  }

  testWidgets('the sheet preview lays the file out as a grid', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await openPreview(tester);

    // Every column of the file, in the order the file had them.
    expect(find.text('name'), findsOneWidget);
    expect(find.text('registrationNo'), findsOneWidget);
    expect(find.text('course'), findsOneWidget);
    expect(find.text('batch'), findsOneWidget);
    expect(find.text('address'), findsOneWidget);

    // The unrecognised column is shown rather than silently dropped.
    expect(find.text('houseNo'), findsOneWidget);

    // Cell values land under their own headings, and a quoted field holding a
    // comma stayed in one cell instead of splitting across two.
    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.text('2023-27'), findsOneWidget);
    expect(find.text('Ambala, Haryana'), findsOneWidget);

    // Row status still renders in the grid.
    expect(find.text('NEW'), findsNWidgets(2));
    expect(find.text('SKIP'), findsOneWidget);
  });

  testWidgets('toggling to Details shows the per-row list instead',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await openPreview(tester);

    expect(find.byType(DataTable), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    expect(find.byType(DataTable), findsNothing);
    // The detail list explains *why* a row was skipped, which the grid only
    // colours in.
    expect(find.textContaining('registration number'), findsWidgets);
  });
}
