import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/hostel.dart';
import 'package:helloworld/screens/pages/room_detail_dialog.dart';

/// A dialog is pushed onto the root Navigator, so its context sits *above*
/// SessionScope. Anything reading `Session.of` in its build throws the moment
/// it opens — and `flutter analyze` cannot see it, because the lookup fails at
/// runtime, not compile time. This dialog shipped with exactly that bug: the
/// room tile turned into a red error screen on tap.
///
/// So the invariant is pinned here: it must build with no SessionScope anywhere
/// above it. Permissions arrive as constructor arguments, read by the calling
/// page where the scope does exist.
///
/// Pumped with `canSeeRoster: false` deliberately. That is the branch which
/// never touches `DataService.instance`, so no Firebase is needed — and it is
/// still enough to prove the widget does not depend on an inherited Session.
void main() {
  const hostel = Hostel(
    id: 'h1',
    name: 'Meghraj Goyal House',
    code: 'BH-9',
    gender: HostelGender.boys,
  );

  const room = Room(
    id: '129',
    number: '129',
    floor: 1,
    capacity: 3,
    features: ['Ceiling Fan', 'Study Table'],
  );

  Widget host({bool canAllot = true, VoidCallback? onEdit}) => MaterialApp(
    home: Scaffold(
      body: RoomDetailDialog(
        collegeId: 'c1',
        hostel: hostel,
        room: room,
        canAllot: canAllot,
        canSeeRoster: false,
        onEditRoom: onEdit,
      ),
    ),
  );

  testWidgets('opens without a SessionScope above it', (tester) async {
    await tester.pumpWidget(host());

    // The regression: this used to throw before painting a frame.
    expect(tester.takeException(), isNull);
    expect(find.text('Room 129'), findsOneWidget);
  });

  testWidgets('shows the room facts it was given', (tester) async {
    await tester.pumpWidget(host());

    expect(find.text('3 Seater'), findsOneWidget);
    expect(find.text('0 / 3'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('says so plainly when the roster cannot be read', (tester) async {
    // Rather than showing an empty room, which would read as "nobody lives
    // here" when the truth is "you are not allowed to know".
    await tester.pumpWidget(host());

    expect(
      find.text('You don\'t have permission to see who lives here.'),
      findsOneWidget,
    );
  });

  testWidgets('hides Edit room when the caller passed no callback', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    expect(find.text('Edit room'), findsNothing);

    await tester.pumpWidget(host(onEdit: () {}));
    expect(find.text('Edit room'), findsOneWidget);
  });
}
