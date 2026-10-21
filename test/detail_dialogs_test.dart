import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/fine.dart';
import 'package:helloworld/models/office_order.dart';
import 'package:helloworld/screens/pages/fine_detail_dialog.dart';
import 'package:helloworld/screens/pages/office_order_detail_dialog.dart';
import 'package:helloworld/services/photo_service.dart';

/// Same invariant as room_detail_dialog_test.dart: a dialog is pushed onto the
/// root Navigator, above SessionScope, so reading `Session.of` in its build
/// throws at runtime and `flutter analyze` cannot see it. Both of these are
/// opened from several pages, so they take their permissions as arguments —
/// pinned here by building them with no SessionScope anywhere.
///
/// No Firebase in tests: the photo read fails, which the photo widget treats
/// as "no photo" and paints initials — itself worth pinning, since that is
/// also what an offline guard's screen does.
void main() {
  const fine = Fine(
    id: 'f1',
    studentUid: 's1',
    studentName: 'Ravi Kumar',
    studentRegNo: '2110910',
    hostelName: 'BH-9',
    roomNumber: '129',
    trade: 'GCS',
    sem: 5,
    amount: 1000,
    category: 'Discipline',
    reason: 'Found outside the hostel after curfew.',
    officeOrderId: 'o1',
    officeOrderNo: 'SLIET/HM/2026/17',
    imposedByUid: 'w1',
    imposedByName: 'Warden Singh',
  );

  const order = OfficeOrder(
    id: 'o1',
    orderNo: 'SLIET/HM/2026/17',
    title: 'Curfew violation',
    postedByUid: 'w1',
    postedByName: 'Warden Singh',
    fineTotal: 1500,
    fineCategory: 'Discipline',
    students: [
      OrderStudent(
        uid: 's1',
        name: 'Ravi Kumar',
        regNo: '2110910',
        fineId: 'f1',
        fineAmount: 1000,
      ),
      OrderStudent(uid: 's2', name: 'Aman Gill', regNo: '2110911'),
    ],
  );

  // The photo cache is app-wide; one test's failed read must not leak into
  // the next.
  setUp(PhotoService.instance.clearCache);

  Widget host(Widget dialog) => MaterialApp(
    home: Scaffold(body: Center(child: dialog)),
  );

  testWidgets('fine detail opens without a SessionScope', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      host(
        const FineDetailDialog(
          fine: fine,
          collegeId: 'c1',
          canViewOrders: false,
          canSeeProfiles: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Ravi Kumar'), findsOneWidget);
    expect(find.text('BH-9 · Room 129'), findsOneWidget);
    expect(find.text('Found outside the hostel after curfew.'), findsOneWidget);
    // Without officeOrders.view it says why there is no scan, rather than
    // attempting a read the rules would refuse.
    expect(find.textContaining('permission to view office orders'), findsOne);
    // The unreadable photo falls back to initials.
    expect(find.text('RK'), findsOneWidget);
  });

  testWidgets('office order detail lists every student it names', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      host(
        const OfficeOrderDetailDialog(
          order: order,
          collegeId: 'c1',
          canSeeProfiles: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Students on this order (2, 1 fined)'), findsOneWidget);
    expect(find.text('Ravi Kumar'), findsOneWidget);
    expect(find.text('Aman Gill'), findsOneWidget);
    expect(find.text('₹1000 FINE'), findsOneWidget);
    expect(find.text('NO FINE'), findsOneWidget);
  });
}
