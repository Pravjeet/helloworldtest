import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/office_order.dart';

/// One order, many students.
///
/// The shape carries two lists that must agree: `students` for display and a
/// flat `studentUids` for querying. If they drift, a student's own page stops
/// showing an order that names them — the failure is silent, which is why it
/// is pinned here.
void main() {
  OfficeOrder order({
    List<OrderStudent> students = const [],
    num? fineTotal,
    String? fineCategory,
  }) => OfficeOrder(
    id: 'o1',
    orderNo: 'SLIET/HM/2026/17',
    title: 'Hostel discipline',
    postedByUid: 'admin',
    postedByName: 'Admin',
    students: students,
    fineTotal: fineTotal,
    fineCategory: fineCategory,
  );

  const ravi = OrderStudent(uid: 'u1', name: 'Ravi Kumar', regNo: '2346001');
  const asha = OrderStudent(uid: 'u2', name: 'Asha Devi', regNo: '2346002');
  const bina = OrderStudent(uid: 'u3', name: 'Bina Rao');

  group('covered students', () {
    test('covers() finds every named student, not just the first', () {
      final o = order(students: const [ravi, asha, bina]);
      expect(o.covers('u1'), isTrue);
      expect(o.covers('u3'), isTrue);
      expect(o.covers('nobody'), isFalse);
    });

    test('isGroup only once more than one student is named', () {
      expect(order(students: const [ravi]).isGroup, isFalse);
      expect(order(students: const [ravi, asha]).isGroup, isTrue);
    });

    test('studentLabel names one, or counts the rest', () {
      expect(order(students: const [ravi]).studentLabel, 'Ravi Kumar');
      expect(
        order(students: const [ravi, asha]).studentLabel,
        'Ravi Kumar and 1 other',
      );
      expect(
        order(students: const [ravi, asha, bina]).studentLabel,
        'Ravi Kumar and 2 others',
      );
      expect(order().studentLabel, '');
    });
  });

  group('the queryable uid array', () {
    test('toMap writes studentUids alongside students', () {
      // array-contains cannot reach into students[].uid, so this flat array is
      // the only way "orders against this student" can be a query.
      final m = order(students: const [ravi, asha, bina]).toMap();
      expect(m['studentUids'], ['u1', 'u2', 'u3']);
      expect((m['students'] as List).length, 3);
    });

    test('the two lists never disagree, because one is derived', () {
      final m = order(students: const [ravi, asha]).toMap();
      final uids = (m['studentUids'] as List).cast<String>();
      final fromMaps = (m['students'] as List)
          .cast<Map<String, dynamic>>()
          .map((e) => e['uid'] as String)
          .toList();
      expect(uids, fromMaps);
    });

    test('an order naming nobody writes an empty array, not null', () {
      // A null would make the array-contains query error rather than miss.
      expect(order().toMap()['studentUids'], isEmpty);
    });
  });

  group('fines are optional', () {
    test('hasFine is false for a warning with no fine ids', () {
      final o = order(students: const [ravi, asha]);
      expect(o.hasFine, isFalse);
      expect(o.fineTotal, isNull);
    });

    test('hasFine is true once any student carries a fine', () {
      final o = order(
        students: const [
          OrderStudent(
            uid: 'u1',
            name: 'Ravi Kumar',
            fineId: 'f1',
            fineAmount: 1000,
          ),
          OrderStudent(
            uid: 'u2',
            name: 'Asha Devi',
            fineId: 'f2',
            fineAmount: 500,
          ),
        ],
        fineTotal: 1500,
        fineCategory: 'Misconduct',
      );
      expect(o.hasFine, isTrue);
    });

    test('each student keeps their own fine id', () {
      // Five students on a ₹1000 order owe ₹1000 each, and each fine has to be
      // settled and counted separately — so the id is per student, not per
      // order.
      final o = order(
        students: const [
          OrderStudent(
            uid: 'u1',
            name: 'A',
            fineId: 'fine-a',
            fineAmount: 1000,
          ),
          OrderStudent(uid: 'u2', name: 'B', fineId: 'fine-b', fineAmount: 250),
        ],
        fineTotal: 1250,
      );
      expect(o.students.map((s) => s.fineId), ['fine-a', 'fine-b']);
      expect(o.students.map((s) => s.fineAmount), [1000, 250]);
    });
  });

  group('search', () {
    test('finds an order by any named student, not only the first', () {
      final o = order(students: const [ravi, asha, bina]);
      expect(o.matches('bina'), isTrue);
      expect(o.matches('2346002'), isTrue);
      expect(o.matches('someone else'), isFalse);
    });

    test('still matches on order number ignoring punctuation', () {
      expect(order().matches('hm 2026 17'), isTrue);
    });
  });

  group('reading documents', () {
    test('round-trips the new shape', () {
      final m = order(
        students: const [ravi, asha],
        fineTotal: 500,
        fineCategory: 'Ragging',
      ).toMap();

      final back = OfficeOrder.fromMap('o1', m);
      expect(back.students.length, 2);
      expect(back.students.first.name, 'Ravi Kumar');
      expect(back.students.first.regNo, '2346001');
      expect(back.fineTotal, 500);
      expect(back.covers('u2'), isTrue);
    });

    test('reads a pre-group document as a one-student order', () {
      // No such document exists in this project, but a restored backup must
      // not render as an order with nobody named on it.
      final back = OfficeOrder.fromMap('o1', {
        'orderNo': 'OLD/1',
        'title': 'Legacy',
        'postedByUid': 'admin',
        'postedByName': 'Admin',
        'studentUid': 'u9',
        'studentName': 'Old Student',
        'studentRegNo': '1234',
        'fineId': 'f9',
        'fineAmount': 200,
      });

      expect(back.students.length, 1);
      expect(back.students.first.uid, 'u9');
      expect(back.students.first.fineId, 'f9');
      expect(back.covers('u9'), isTrue);
      expect(back.hasFine, isTrue);
      expect(back.isGroup, isFalse);
    });

    test('an unlinked legacy order yields no students rather than a ghost', () {
      final back = OfficeOrder.fromMap('o1', {
        'orderNo': 'OLD/2',
        'title': 'Unlinked',
        'postedByUid': 'admin',
        'postedByName': 'Admin',
      });
      expect(back.students, isEmpty);
      expect(back.hasFine, isFalse);
      expect(back.studentLabel, '');
    });

    test('the new shape wins when both are somehow present', () {
      final back = OfficeOrder.fromMap('o1', {
        'orderNo': 'X',
        'title': 'X',
        'postedByUid': 'a',
        'postedByName': 'A',
        'students': [
          {'uid': 'new1', 'name': 'New One'},
          {'uid': 'new2', 'name': 'New Two'},
        ],
        'studentUid': 'legacy',
        'studentName': 'Legacy',
      });
      expect(back.students.map((s) => s.uid), ['new1', 'new2']);
      expect(back.covers('legacy'), isFalse);
    });

    test('malformed entries are dropped, not crashed on', () {
      final back = OfficeOrder.fromMap('o1', {
        'orderNo': 'X',
        'title': 'X',
        'postedByUid': 'a',
        'postedByName': 'A',
        'students': [
          {'uid': 'ok', 'name': 'Fine'},
          {'name': 'No uid at all'},
          'not a map',
        ],
      });
      expect(back.students.map((s) => s.uid), ['ok']);
    });
  });

  group('amounts differ per student', () {
    // The point of the whole shape: one order, different penalties, and some
    // students named but not fined at all.
    final mixed = order(
      students: const [
        OrderStudent(
          uid: 'u1',
          name: 'Ringleader',
          fineId: 'f1',
          fineAmount: 2000,
        ),
        OrderStudent(
          uid: 'u2',
          name: 'Accomplice',
          fineId: 'f2',
          fineAmount: 500,
        ),
        OrderStudent(uid: 'u3', name: 'Bystander'),
      ],
      fineTotal: 2500,
      fineCategory: 'Misconduct',
    );

    test('only the fined students count as fined', () {
      expect(mixed.finedStudents.map((s) => s.name), [
        'Ringleader',
        'Accomplice',
      ]);
      expect(mixed.hasUnfinedStudents, isTrue);
    });

    test('a student named but not fined owes nothing', () {
      expect(mixed.amountFor('u3'), isNull);
      expect(mixed.covers('u3'), isTrue, reason: 'still on the order');
    });

    test('each student sees their own amount, not the total', () {
      expect(mixed.amountFor('u1'), 2000);
      expect(mixed.amountFor('u2'), 500);
      expect(mixed.fineTotal, 2500);
    });

    test('somebody not on the order owes nothing', () {
      expect(mixed.amountFor('stranger'), isNull);
    });

    test('the range spans the smallest and largest fine', () {
      expect(mixed.fineRangeLabel, '₹500–₹2000');
    });

    test('a single amount reads as one figure, not a range', () {
      final flat = order(
        students: const [
          OrderStudent(uid: 'a', name: 'A', fineId: 'f1', fineAmount: 700),
          OrderStudent(uid: 'b', name: 'B', fineId: 'f2', fineAmount: 700),
        ],
        fineTotal: 1400,
      );
      expect(flat.fineRangeLabel, '₹700');
      expect(flat.hasUnfinedStudents, isFalse);
    });

    test('an order fining nobody has no range at all', () {
      expect(order(students: const [ravi, asha]).fineRangeLabel, isNull);
    });

    test('a zero amount is not a fine', () {
      // Guards against a blank box being read as zero owed rather than unset.
      final zero = order(
        students: const [
          OrderStudent(uid: 'a', name: 'A', fineId: 'f1', fineAmount: 0),
        ],
      );
      expect(zero.hasFine, isFalse);
      expect(zero.amountFor('a'), isNull);
    });
  });

  group('reading an order written when everyone paid the same', () {
    test('the old per-each amount becomes the total', () {
      // Those documents stored fineAmount meaning "each"; multiplying by the
      // number of students recovers what they always represented.
      final back = OfficeOrder.fromMap('o1', {
        'orderNo': 'OLD/3',
        'title': 'Flat rate',
        'postedByUid': 'a',
        'postedByName': 'A',
        'students': [
          {'uid': 'u1', 'name': 'A', 'fineId': 'f1'},
          {'uid': 'u2', 'name': 'B', 'fineId': 'f2'},
          {'uid': 'u3', 'name': 'C', 'fineId': 'f3'},
        ],
        'fineAmount': 1000,
        'fineCategory': 'Misconduct',
      });

      expect(back.fineTotal, 3000, reason: '1000 each across three');
      expect(back.students.length, 3);
    });

    test('a legacy single-student order keeps its amount', () {
      final back = OfficeOrder.fromMap('o1', {
        'orderNo': 'OLD/4',
        'title': 'One student',
        'postedByUid': 'a',
        'postedByName': 'A',
        'studentUid': 'u9',
        'studentName': 'Solo',
        'fineId': 'f9',
        'fineAmount': 250,
      });

      expect(back.amountFor('u9'), 250);
      expect(back.fineTotal, 250);
      expect(back.hasFine, isTrue);
    });
  });
}
