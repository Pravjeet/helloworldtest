import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/screens/pages/hostel_editor_dialog.dart';

/// Drives the hostel editor's room planner.
///
/// Nothing here saves, so no Firebase is touched — `HostelService.instance` is
/// a lazily-initialised static and is only reached from `_save`.
void main() {
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: HostelEditorDialog(collegeId: 'test-college'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('starts on one room type applied to every floor', (tester) async {
    await open(tester);

    expect(find.text('Every floor is laid out the same'), findsOneWidget);
    expect(find.text('Rooms on each floor'), findsOneWidget);

    // 4 floors x 25 two-seater rooms.
    expect(find.textContaining('Will create 100 rooms'), findsOneWidget);
    expect(find.textContaining('200 beds'), findsOneWidget);
    expect(
      find.text('Floors 1–4: 25 rooms (25 2 Seater)'),
      findsOneWidget,
    );
  });

  testWidgets('two room types can share one floor', (tester) async {
    await open(tester);

    // The case the old model could not express: one corridor, two seater
    // types. Adding a type picks the first capacity not already in use.
    await tester.ensureVisible(find.text('Add room type'));
    await tester.tap(find.text('Add room type'));
    await tester.pumpAndSettle();

    // Both types now sit on the SAME floor rather than each claiming floors
    // of their own — 50 rooms per floor, across 4 floors.
    expect(
      find.text('Floors 1–4: 50 rooms (25 2 Seater + 25 Single)'),
      findsOneWidget,
    );
    expect(find.textContaining('Will create 200 rooms'), findsOneWidget);
    // 4 x (25*2 + 25*1)
    expect(find.textContaining('300 beds'), findsOneWidget);
  });

  testWidgets('turning off "same every floor" seeds one card per floor',
      (tester) async {
    await open(tester);

    expect(find.text('Floor 1'), findsNothing);

    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    // One editor per floor, each seeded from the shared layout so nothing
    // has to be retyped.
    for (final label in ['Floor 1', 'Floor 2', 'Floor 3', 'Floor 4']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Rooms on each floor'), findsNothing);

    // The layout is unchanged by the switch itself.
    expect(
      find.text('Floors 1–4: 25 rooms (25 2 Seater)'),
      findsOneWidget,
    );
  });

  testWidgets('editing one floor leaves the others alone', (tester) async {
    await open(tester);

    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    // Ground floor loses rooms to the warden's office and common room — the
    // reason per-floor editing exists at all.
    final firstRoomsField = find.widgetWithText(TextFormField, '25').first;
    await tester.ensureVisible(firstRoomsField);
    await tester.enterText(firstRoomsField, '10');
    await tester.pumpAndSettle();

    // Floor 1 breaks out of the range; floors 2-4 stay together.
    expect(
      find.text(
        'Floor 1: 10 rooms (10 2 Seater), Floors 2–4: 25 rooms (25 2 Seater)',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Will create 85 rooms'), findsOneWidget);
  });
}
