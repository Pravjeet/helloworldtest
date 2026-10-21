import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/app_role.dart';
import 'package:helloworld/screens/pages/import_students_dialog.dart';

/// Layout tests for the spreadsheet preview.
///
/// This grid puts an `Expanded` inside a `Column` inside a horizontal
/// `SingleChildScrollView` — the exact shape that has silently blanked a list
/// in this project before, because a vertical flex child in an unbounded
/// parent fails to lay out. The web preview device can't paint, so pumping
/// the widget here is the only way to know it renders at all.
void main() {
  const roles = [AppRole(id: 'r1', name: 'Student')];

  /// A sheet with more columns than fit, and a value long enough to force the
  /// auto-fit width to clamp.
  const sheet =
      'name,registrationNo,email,role,gender,phone,course,year,trade,batch,'
      'sem,state,hostel,room,dateOfBirth,bloodGroup,address\n'
      'Aarav Sharma,2110910,,Student,M,9876543210,B.Tech,2nd,GCS,2021-22,'
      '3,Punjab,BH-1,101,14/03/2004,O+,"Ludhiana, Punjab"\n'
      'Priya Singh,2110911,,Student,F,9876543211,B.Tech,2nd,GCS,2021-22,'
      '3,Punjab,BH-1,102,15/04/2004,B+,"Sangrur, Punjab"\n'
      ',,,Student,,,,,,,,,,,,,\n';

  /// Sets the window the dialog will size itself against.
  ///
  /// `setSurfaceSize` alone is not enough: MediaQuery reads the *view*, so
  /// without this the dialog kept seeing the default 800x600 and the width
  /// logic under test never ran.
  void useWindow(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// Pushed with `showDialog`, the way the app does it — an `AlertDialog`
  /// dropped straight into a body gets different constraints and would let a
  /// real overflow through untested.
  Future<void> openPreview(WidgetTester tester, String pasted) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const ImportStudentsDialog(
                  collegeId: 'c1',
                  existingUsers: [],
                  roles: roles,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, pasted);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Preview'));
    await tester.pumpAndSettle();
  }

  testWidgets('the grid lays out without overflowing', (tester) async {
    useWindow(tester, const Size(1400, 900));

    await openPreview(tester, sheet);

    // A layout failure here surfaces as an exception rather than a bad pixel,
    // so this assertion is the whole point of the test.
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the sheet\'s own columns as headers', (tester) async {
    useWindow(tester, const Size(1400, 900));

    await openPreview(tester, sheet);

    expect(find.text('name'), findsOneWidget);
    expect(find.text('registrationNo'), findsOneWidget);
    expect(find.text('#'), findsOneWidget);
    expect(find.text('Status'), findsOneWidget);
  });

  testWidgets('renders cell values from the pasted rows', (tester) async {
    useWindow(tester, const Size(1400, 900));

    await openPreview(tester, sheet);

    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.text('2110910'), findsOneWidget);
    // The verdict travels with the row.
    expect(find.text('NEW'), findsWidgets);
  });

  testWidgets('a bad row is marked SKIP with its reason', (tester) async {
    useWindow(tester, const Size(1400, 900));

    await openPreview(tester, sheet);

    expect(find.text('SKIP'), findsWidgets);
    expect(
      find.textContaining('Name is missing'),
      findsWidgets,
      reason: 'the skip reason must stay visible in grid form',
    );
  });

  testWidgets('an ignored column is still shown, not dropped', (tester) async {
    useWindow(tester, const Size(1400, 900));

    await openPreview(
      tester,
      'name,registrationNo,officeRoom\nAarav,2110910,Admin Block 12\n',
    );

    // officeRoom is no longer an import column, so it must appear in the grid
    // as an ignored header rather than vanish — that is how someone finds out
    // the app never read it.
    expect(find.text('officeRoom'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide sheet scrolls horizontally in a narrow window', (
    tester,
  ) async {
    useWindow(tester, const Size(900, 650));

    await openPreview(tester, sheet);

    expect(tester.takeException(), isNull);

    final scroller = find.byType(Scrollable).last;
    await tester.drag(scroller, const Offset(-400, 0));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty plan does not blow up the grid', (tester) async {
    useWindow(tester, const Size(1400, 900));

    // Header row only — a real thing to paste by accident.
    await openPreview(tester, 'name,registrationNo\n');

    expect(tester.takeException(), isNull);
  });
}
