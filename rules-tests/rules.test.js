// Automated assertions against firestore.rules, run against the local
// Firestore emulator — never against the live homihostel-57391 project.
// This is the automated counterpart to ../MANUAL_QA.md: that script proves
// the UI respects roles by clicking through the app; this proves the rules
// themselves refuse the write/read even if the UI's check were bypassed
// entirely (e.g. a direct REST call), which is the actual security boundary
// per DEVELOPMENT.md.
//
// Run with:  cd rules-tests && npm install && npm test
// Requires the Firebase CLI (already installed) and a JDK (the emulator is
// a Java process).

import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} from '@firebase/rules-unit-testing';
// The aggregation tests need the modular API: the compat Firestore that
// rules-unit-testing hands back has no `.count()`. `_delegate` is the modular
// instance underneath it.
import {
  collection,
  query,
  where,
  getCountFromServer,
  // Sentinels for the photo batch tests below. The compat db accepts the
  // modular ones: its writes unwrap to the same modular instance.
  serverTimestamp,
  deleteField,
  Timestamp,
  increment,
} from 'firebase/firestore';

let testEnv;

const COLLEGE_A = 'college-a';
const COLLEGE_B = 'college-b';

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'homihostel-rules-test',
    firestore: {
      rules: readFileSync('../firestore.rules', 'utf8'),
    },
  });
});

after(async () => {
  await testEnv.cleanup();
});

afterEach(async () => {
  await testEnv.clearFirestore();
});

/** Seeds a college, a role, and a user document, bypassing rules entirely. */
async function seed(collegeId, { studentRole, wardenRole } = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.collection('colleges').doc(collegeId).set({
      name: 'Test College',
      ownerUid: 'owner-uid',
    });
    await db
      .collection('colleges')
      .doc(collegeId)
      .collection('roles')
      .doc('student')
      .set({
        name: 'Student',
        permissions: studentRole ?? ['fines.viewOwn', 'requests.create', 'requests.viewOwn'],
        isSystem: false,
      });
    await db
      .collection('colleges')
      .doc(collegeId)
      .collection('roles')
      .doc('warden')
      .set({
        name: 'Warden',
        permissions: wardenRole ?? ['fines.viewAll', 'fines.manage', 'requests.viewAll', 'requests.approve'],
        isSystem: false,
      });
  });
}

async function seedUser(collegeId, uid, roleId, extra = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await ctx
      .firestore()
      .collection('users')
      .doc(uid)
      .set({
        name: 'Test User',
        email: `${uid}@test.local`,
        collegeId,
        roleId,
        isActive: true,
        isSuperAdmin: false,
        ...extra,
      });
  });
}

function asUser(uid) {
  return testEnv.authenticatedContext(uid).firestore();
}

describe('user data isolation', () => {
  it('a student cannot read a fine belonging to another student', async () => {
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'student-a', 'student');
    await seedUser(COLLEGE_A, 'student-b', 'student');

    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('fines')
        .doc('fine-1')
        .set({ studentUid: 'student-b', amount: 100, status: 'pending', imposedByUid: 'warden-a' });
    });

    const db = asUser('student-a');
    await assertFails(
      db.collection('colleges').doc(COLLEGE_A).collection('fines').doc('fine-1').get(),
    );
  });

  it('a student CAN read their own fine', async () => {
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('fines')
        .doc('fine-1')
        .set({ studentUid: 'student-a', amount: 100, status: 'pending', imposedByUid: 'warden-a' });
    });

    const db = asUser('student-a');
    await assertSucceeds(
      db.collection('colleges').doc(COLLEGE_A).collection('fines').doc('fine-1').get(),
    );
  });
});

describe('cross-college isolation', () => {
  it('a user in college A cannot read a user document from college B, even with users.view', async () => {
    await seed(COLLEGE_A, { studentRole: ['users.view'] });
    await seed(COLLEGE_B);
    await seedUser(COLLEGE_A, 'staff-a', 'student');
    await seedUser(COLLEGE_B, 'student-b', 'student');

    const db = asUser('staff-a');
    await assertFails(db.collection('users').doc('student-b').get());
  });
});

describe('self-approval is blocked', () => {
  it('a warden cannot approve a request they themselves raised', async () => {
    await seed(COLLEGE_A, {
      wardenRole: ['requests.create', 'requests.viewOwn', 'requests.viewAll', 'requests.approve'],
    });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('requests')
        .doc('req-1')
        .set({ raisedByUid: 'warden-a', status: 'pending', type: 'leave' });
    });

    const db = asUser('warden-a');
    await assertFails(
      db
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('requests')
        .doc('req-1')
        .update({ status: 'approved' }),
    );
  });
});

describe('privilege escalation is blocked', () => {
  it('a user cannot grant themselves a permission via their own profile update', async () => {
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'student-a', 'student');

    const db = asUser('student-a');
    // onlySelfEditableFields() only allows name/phone/gender/email/updatedAt —
    // roleId and isSuperAdmin must never be among them.
    await assertFails(
      db.collection('users').doc('student-a').update({ isSuperAdmin: true }),
    );
    await assertFails(
      db.collection('users').doc('student-a').update({ roleId: 'warden' }),
    );
    // But an allowed field succeeds, proving the failures above are about
    // the field, not some unrelated setup mistake.
    await assertSucceeds(
      db.collection('users').doc('student-a').update({ phone: '9999999999' }),
    );
  });

  it('a role update cannot grant a permission the editor does not already hold', async () => {
    await seed(COLLEGE_A, { wardenRole: ['roles.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    const db = asUser('warden-a');
    // Warden holds roles.manage but not users.delete — rules only check
    // roles.manage + isSystem here (see firestore.rules), so this specific
    // rule doesn't itself block granting an unheld permission; documenting
    // the actual behaviour rather than an aspirational one:
    await assertSucceeds(
      db
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('roles')
        .doc('warden')
        .update({ permissions: ['roles.manage', 'users.delete'] }),
    );
  });
});

describe('allotment.manage is narrower than users.edit', () => {
  it('a warden with only allotment.manage cannot rename a student', async () => {
    await seed(COLLEGE_A, { wardenRole: ['allotment.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');

    const db = asUser('warden-a');
    await assertFails(
      db.collection('users').doc('student-a').update({ name: 'Renamed' }),
    );
  });

  it('the same warden CAN write the allotment fields', async () => {
    await seed(COLLEGE_A, { wardenRole: ['allotment.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');

    const db = asUser('warden-a');
    await assertSucceeds(
      db.collection('users').doc('student-a').update({
        hostelId: 'h1',
        hostelName: 'Block A',
        roomId: '101',
        roomNumber: '101',
      }),
    );
  });
});

// An office order names one or more students and may or may not carry money.
// Those two facts are gated by *different* permissions, so the rule has a
// conditional in it — which is exactly the kind of thing that silently inverts.
describe('office orders covering several students', () => {
  const ORDERS = (db) =>
    db.collection('colleges').doc(COLLEGE_A).collection('officeOrders');

  /** A well-formed group order.
   *
   * `fineTotal` is what the rule reads: the per-student amounts live inside
   * `students[]`, and rules cannot look inside an array. */
  const order = (uid, extra = {}) => ({
    orderNo: 'SLIET/HM/2026/17',
    title: 'Hostel discipline',
    postedByUid: uid,
    postedByName: 'Test User',
    students: [
      { uid: 'student-a', name: 'A', regNo: '1', fineId: null, fineAmount: null },
      { uid: 'student-b', name: 'B', regNo: '2', fineId: null, fineAmount: null },
    ],
    studentUids: ['student-a', 'student-b'],
    ...extra,
  });

  it('a scan within 70 KB is accepted, a bigger one refused', async () => {
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    const db = asUser('warden-a');
    await assertSucceeds(
      ORDERS(db).add(order('warden-a', { imageBase64: 'A'.repeat(95000) })),
    );
    await assertFails(
      ORDERS(db).add(order('warden-a', { imageBase64: 'A'.repeat(96001) })),
    );
  });

  it('fines.manage can issue a group order that fines everyone', async () => {
    await seed(COLLEGE_A, {
      wardenRole: ['fines.manage', 'officeOrders.manage'],
    });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertSucceeds(
      ORDERS(asUser('warden-a')).doc('o1').set(
        order('warden-a', { fineTotal: 2500, fineCategory: 'Misconduct' }),
      ),
    );
  });

  it('officeOrders.manage alone can issue a warning with no fine', async () => {
    // The reason the rule was relaxed: a suspension or notice of enquiry is a
    // real order that costs nothing, and used to be impossible to record.
    await seed(COLLEGE_A, { wardenRole: ['officeOrders.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertSucceeds(
      ORDERS(asUser('warden-a')).doc('o1').set(order('warden-a')),
    );
  });

  it('officeOrders.manage alone CANNOT levy money', async () => {
    // The hole this rule exists to close: recording a warning must not imply
    // authority to fine people.
    await seed(COLLEGE_A, { wardenRole: ['officeOrders.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertFails(
      ORDERS(asUser('warden-a')).doc('o1').set(
        order('warden-a', { fineTotal: 2500, fineCategory: 'Misconduct' }),
      ),
    );
  });

  it('fines.manage alone CAN issue a bare warning', async () => {
    // The starter Warden role has fines.manage but not officeOrders.manage.
    // Letting them fine a student while refusing to let them record a warning
    // would be backwards, so the rule is monotonic in that direction.
    await seed(COLLEGE_A, { wardenRole: ['fines.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertSucceeds(
      ORDERS(asUser('warden-a')).doc('o1').set(order('warden-a')),
    );
  });

  it('a warning written with an explicit null amount is still a warning', async () => {
    // The app's toMap always includes the key, so this is the shape real
    // warnings actually arrive in — not the absent-key case.
    await seed(COLLEGE_A, { wardenRole: ['officeOrders.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertSucceeds(
      ORDERS(asUser('warden-a')).doc('o1').set(
        order('warden-a', { fineTotal: null, fineCategory: null }),
      ),
    );
  });

  it('an order naming nobody is refused', async () => {
    // It would be a document no student page could ever surface.
    await seed(COLLEGE_A, { wardenRole: ['officeOrders.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertFails(
      ORDERS(asUser('warden-a')).doc('o1').set(
        order('warden-a', { students: [], studentUids: [] }),
      ),
    );
  });

  it('studentUids must be a list, not a single id', async () => {
    await seed(COLLEGE_A, { wardenRole: ['officeOrders.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertFails(
      ORDERS(asUser('warden-a')).doc('o1').set(
        order('warden-a', { studentUids: 'student-a' }),
      ),
    );
  });

  it('the issuer cannot be spoofed', async () => {
    await seed(COLLEGE_A, { wardenRole: ['officeOrders.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertFails(
      ORDERS(asUser('warden-a')).doc('o1').set(order('someone-else')),
    );
  });

  it('a student cannot issue an order at all', async () => {
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await assertFails(
      ORDERS(asUser('student-a')).doc('o1').set(order('student-a')),
    );
  });

  it('an order cannot be planted in another college', async () => {
    await seed(COLLEGE_A, { wardenRole: ['officeOrders.manage'] });
    await seed(COLLEGE_B, { wardenRole: ['officeOrders.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    const db = asUser('warden-a');
    await assertFails(
      db
        .collection('colleges')
        .doc(COLLEGE_B)
        .collection('officeOrders')
        .doc('o1')
        .set(order('warden-a')),
    );
  });
});

// The dashboard replaces "download 2,650 students and count them in Dart" with
// count() aggregations, which bill one read per 1,000 index entries instead of
// one per document. That only works if the rules permit an aggregation — and
// the users `list` rule constrains `resource.data`, which an aggregation never
// produces. These tests establish what Firestore actually does, because the
// whole optimisation rests on it.
describe('aggregation queries on users', () => {
  /** Modular query over users, scoped to a college unless collegeId is null. */
  const usersQuery = (db, collegeId) => {
    const col = collection(db._delegate, 'users');
    return collegeId === null
      ? query(col)
      : query(col, where('collegeId', '==', collegeId));
  };

  it('someone with users.view can count their own college', async () => {
    await seed(COLLEGE_A, { wardenRole: ['users.view'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');
    await seedUser(COLLEGE_A, 'student-b', 'student');

    const snap = await assertSucceeds(
      getCountFromServer(usersQuery(asUser('warden-a'), COLLEGE_A)),
    );
    // warden + two students
    assert.equal(snap.data().count, 3);
  });

  it('a student without users.view cannot count anybody', async () => {
    // The count must not become a side channel for a figure the caller is not
    // allowed to read document by document.
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await assertFails(
      getCountFromServer(usersQuery(asUser('student-a'), COLLEGE_A)),
    );
  });

  it('users.view does not let you count another college', async () => {
    await seed(COLLEGE_A, { wardenRole: ['users.view'] });
    await seed(COLLEGE_B);
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_B, 'student-b', 'student');

    await assertFails(
      getCountFromServer(usersQuery(asUser('warden-a'), COLLEGE_B)),
    );
  });

  it('an unscoped count over every college is refused', async () => {
    // Dropping the collegeId filter would otherwise reveal the size of every
    // institution in the project.
    await seed(COLLEGE_A, { wardenRole: ['users.view'] });
    await seed(COLLEGE_B);
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_B, 'student-b', 'student');

    await assertFails(
      getCountFromServer(usersQuery(asUser('warden-a'), null)),
    );
  });

  it('a narrower count inside your own college is allowed', async () => {
    // What the dashboard actually asks: how many are inactive, unallotted, etc.
    await seed(COLLEGE_A, { wardenRole: ['users.view'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student', { isActive: false });
    await seedUser(COLLEGE_A, 'student-b', 'student', { isActive: true });

    const col = collection(asUser('warden-a')._delegate, 'users');
    const snap = await assertSucceeds(
      getCountFromServer(
        query(
          col,
          where('collegeId', '==', COLLEGE_A),
          where('isActive', '==', false),
        ),
      ),
    );
    assert.equal(snap.data().count, 1);
  });
});

// Enrollments carry a student's academic year per session, and their room
// history. The rule mirrors office orders and fines in shape, but the field
// it protects (year) matters more: it decides graduation and room
// entitlement, so getting the permission split wrong here either locks staff
// out of legitimate promotion or lets a warden edit someone's year through
// the allotment door.
describe('enrollments', () => {
  const enrollmentsOf = (db, collegeId) =>
    db.collection('colleges').doc(collegeId).collection('enrollments');

  const enrollment = (uid, extra = {}) => ({
    uid,
    session: '2026-27',
    collegeId: COLLEGE_A,
    year: 2,
    name: 'Test Student',
    ...extra,
  });

  it('academic.manage can create an enrollment record', async () => {
    await seed(COLLEGE_A, { wardenRole: ['academic.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertSucceeds(
      enrollmentsOf(asUser('warden-a'), COLLEGE_A)
        .doc('student-a_2026-27')
        .set(enrollment('student-a')),
    );
  });

  it('academic.view alone cannot create one', async () => {
    await seed(COLLEGE_A, { wardenRole: ['academic.view'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertFails(
      enrollmentsOf(asUser('warden-a'), COLLEGE_A)
        .doc('student-a_2026-27')
        .set(enrollment('student-a')),
    );
  });

  it('academic.view can list the session roster', async () => {
    await seed(COLLEGE_A, { wardenRole: ['academic.view'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('enrollments')
        .doc('student-a_2026-27')
        .set(enrollment('student-a'));
    });

    const snap = await assertSucceeds(
      enrollmentsOf(asUser('warden-a'), COLLEGE_A)
        .where('session', '==', '2026-27')
        .get(),
    );
    assert.equal(snap.size, 1);
  });

  it('a student can read only their own enrollment record', async () => {
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'student-a', 'student');
    await seedUser(COLLEGE_A, 'student-b', 'student');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const col = ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('enrollments');
      await col.doc('student-a_2026-27').set(enrollment('student-a'));
      await col.doc('student-b_2026-27').set(enrollment('student-b'));
    });

    const db = asUser('student-a');
    await assertSucceeds(
      enrollmentsOf(db, COLLEGE_A).doc('student-a_2026-27').get(),
    );
    await assertFails(
      enrollmentsOf(db, COLLEGE_A).doc('student-b_2026-27').get(),
    );
  });

  it('a student without academic.view cannot list the whole roster', async () => {
    // Rules run per candidate document on a list — the same isolation the
    // fines list rule relies on — so a bare where('session', ==) query from a
    // student must come back empty/denied rather than widened to just theirs.
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'student-a', 'student');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('enrollments')
        .doc('student-a_2026-27')
        .set(enrollment('student-a'));
    });

    await assertFails(
      enrollmentsOf(asUser('student-a'), COLLEGE_A)
        .where('session', '==', '2026-27')
        .get(),
    );
  });

  it('allotment.manage can read an enrollment and list the session roster', async () => {
    // Every allot transaction reads the student's enrollment, and Room
    // Allotment lists the roster for years and the seating policy. A stock
    // Warden (no academic.*) was denied both — so no Warden could allot.
    await seed(COLLEGE_A, { wardenRole: ['allotment.manage', 'users.view'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('enrollments')
        .doc('student-a_2026-27')
        .set(enrollment('student-a'));
    });

    const col = enrollmentsOf(asUser('warden-a'), COLLEGE_A);
    await assertSucceeds(col.doc('student-a_2026-27').get());
    await assertSucceeds(col.doc('nobody_2026-27').get());
    await assertSucceeds(col.where('session', '==', '2026-27').get());
  });

  it('allotment.manage without users.view cannot list the roster', async () => {
    // BHS: fills beds but is deliberately kept out of the student directory.
    // It may read one enrollment by id (the allot transaction does), but not
    // enumerate every student by listing enrollments.
    await seed(COLLEGE_A, { wardenRole: ['allotment.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('enrollments')
        .doc('student-a_2026-27')
        .set(enrollment('student-a'));
    });

    const col = enrollmentsOf(asUser('warden-a'), COLLEGE_A);
    await assertSucceeds(col.doc('student-a_2026-27').get());
    await assertFails(col.where('session', '==', '2026-27').get());
  });

  it('allotment.manage can mark merit, but still not edit anything else', async () => {
    await seed(COLLEGE_A, {
      wardenRole: ['users.view', 'hostels.view', 'allotment.manage'],
    });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');

    const student = asUser('warden-a').collection('users').doc('student-a');
    await assertSucceeds(
      student.update({
        singleRoomEligible: true,
        updatedAt: serverTimestamp(),
      }),
    );
    // The widened list must not have opened the profile itself.
    await assertFails(
      student.update({ singleRoomEligible: false, name: 'Someone Else' }),
    );
  });

  it('a Warden-shaped role can run the whole allot transaction', async () => {
    // The exact reads and writes AllotmentService.allot makes, as a role with
    // the stock Warden's allotment-relevant permissions and nothing academic.
    await seed(COLLEGE_A, {
      wardenRole: ['users.view', 'hostels.view', 'allotment.manage'],
    });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const college = ctx.firestore().collection('colleges').doc(COLLEGE_A);
      await college.collection('settings').doc('config').set({
        session: { current: '2026-27' },
      });
      await college
        .collection('hostels')
        .doc('h1')
        .set({ name: 'BH-1', occupiedBeds: 0 });
      await college
        .collection('hostels')
        .doc('h1')
        .collection('rooms')
        .doc('101')
        .set({ number: '101', capacity: 3, occupantUids: [] });
      await college
        .collection('enrollments')
        .doc('student-a_2026-27')
        .set(enrollment('student-a'));
    });

    const db = asUser('warden-a');
    const college = db.collection('colleges').doc(COLLEGE_A);
    const roomRef = college
      .collection('hostels')
      .doc('h1')
      .collection('rooms')
      .doc('101');
    const userRef = db.collection('users').doc('student-a');
    const hostelRef = college.collection('hostels').doc('h1');
    const settingsRef = college.collection('settings').doc('config');
    const enrollmentRef = college
      .collection('enrollments')
      .doc('student-a_2026-27');

    await assertSucceeds(
      db.runTransaction(async (tx) => {
        await tx.get(roomRef);
        await tx.get(userRef);
        await tx.get(settingsRef);
        await tx.get(enrollmentRef);
        tx.update(roomRef, { occupantUids: ['student-a'] });
        tx.update(userRef, {
          hostelId: 'h1',
          hostelName: 'BH-1',
          roomId: '101',
          roomNumber: '101',
          allottedAt: serverTimestamp(),
        });
        tx.update(hostelRef, { occupiedBeds: increment(1) });
        tx.update(enrollmentRef, {
          hostelId: 'h1',
          hostelName: 'BH-1',
          roomId: '101',
          roomNumber: '101',
          roomCapacity: 3,
          allottedAt: serverTimestamp(),
        });
      }),
    );
  });

  it('only a Super Admin can delete an enrollment (the master reset)', async () => {
    // academic.manage can rewrite history by re-running promotion, but not
    // erase it. Deletion exists for exactly one caller: "delete all students".
    await seed(COLLEGE_A, { wardenRole: ['academic.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'admin-a', 'warden', { isSuperAdmin: true });
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const col = ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('enrollments');
      await col.doc('student-a_2026-27').set(enrollment('student-a'));
      await col.doc('student-b_2026-27').set(enrollment('student-b'));
    });

    await assertFails(
      enrollmentsOf(asUser('warden-a'), COLLEGE_A)
        .doc('student-a_2026-27')
        .delete(),
    );
    await assertSucceeds(
      enrollmentsOf(asUser('admin-a'), COLLEGE_A)
        .doc('student-a_2026-27')
        .delete(),
    );
  });

  it('a Super Admin cannot delete another college\'s enrollments', async () => {
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'admin-a', 'warden', { isSuperAdmin: true });
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_B)
        .collection('enrollments')
        .doc('student-x_2026-27')
        .set(enrollment('student-x', { collegeId: COLLEGE_B }));
    });

    await assertFails(
      enrollmentsOf(asUser('admin-a'), COLLEGE_B)
        .doc('student-x_2026-27')
        .delete(),
    );
  });

  it('allotment.manage may update only the room fields on an enrollment', async () => {
    await seed(COLLEGE_A, { wardenRole: ['allotment.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('enrollments')
        .doc('student-a_2026-27')
        .set(enrollment('student-a'));
    });

    await assertSucceeds(
      enrollmentsOf(asUser('warden-a'), COLLEGE_A)
        .doc('student-a_2026-27')
        .update({ hostelId: 'h1', hostelName: 'BH-1', roomId: '101' }),
    );
  });

  it('allotment.manage may NOT touch the year through the enrollment', async () => {
    // The whole reason the update rule is split: filling a bed must not be
    // the same authority as changing what year a student is in.
    await seed(COLLEGE_A, { wardenRole: ['allotment.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('enrollments')
        .doc('student-a_2026-27')
        .set(enrollment('student-a'));
    });

    await assertFails(
      enrollmentsOf(asUser('warden-a'), COLLEGE_A)
        .doc('student-a_2026-27')
        .update({ year: 4 }),
    );
  });

  it('delete is refused for everyone, including academic.manage', async () => {
    await seed(COLLEGE_A, { wardenRole: ['academic.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('enrollments')
        .doc('student-a_2026-27')
        .set(enrollment('student-a'));
    });

    await assertFails(
      enrollmentsOf(asUser('warden-a'), COLLEGE_A)
        .doc('student-a_2026-27')
        .delete(),
    );
  });

  it('an enrollment cannot be planted in another college', async () => {
    await seed(COLLEGE_A, { wardenRole: ['academic.manage'] });
    await seed(COLLEGE_B, { wardenRole: ['academic.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertFails(
      enrollmentsOf(asUser('warden-a'), COLLEGE_B)
        .doc('student-a_2026-27')
        .set(enrollment('student-a', { collegeId: COLLEGE_B })),
    );
  });
});

// The users/{uid} write promotion makes when a student graduates —
// academic.manage may set `status`, and nothing else.
describe('academic.manage graduating a student', () => {
  it('can set status to graduated', async () => {
    await seed(COLLEGE_A, { wardenRole: ['academic.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await assertSucceeds(
      asUser('warden-a')
        .collection('users')
        .doc('student-a')
        .update({ status: 'graduated' }),
    );
  });

  it('cannot rename or re-role a student through the same permission', async () => {
    await seed(COLLEGE_A, { wardenRole: ['academic.manage'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await assertFails(
      asUser('warden-a')
        .collection('users')
        .doc('student-a')
        .update({ status: 'graduated', name: 'Renamed' }),
    );
  });

  it('academic.view alone cannot graduate anyone', async () => {
    await seed(COLLEGE_A, { wardenRole: ['academic.view'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await assertFails(
      asUser('warden-a')
        .collection('users')
        .doc('student-a')
        .update({ status: 'graduated' }),
    );
  });
});

// ID photos exist to catch impersonation, so who can SET one is the part that
// matters: a student choosing their own face for their record defeats it.
describe('ID photos', () => {
  const photo = (db, collegeId, uid) =>
    db.collection('colleges').doc(collegeId).collection('photos').doc(uid);

  const body = (uid, by, bytes = 'aGVsbG8=') => ({
    uid,
    bytes,
    mimeType: 'image/jpeg',
    updatedByUid: by,
    updatedByName: 'Test User',
  });

  async function seedPhoto(collegeId, uid) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await photo(ctx.firestore(), collegeId, uid).set(body(uid, 'someone'));
    });
  }

  it('users.edit can set a student\'s photo', async () => {
    await seed(COLLEGE_A, { wardenRole: ['users.edit'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await assertSucceeds(
      photo(asUser('warden-a'), COLLEGE_A, 'student-a').set(
        body('student-a', 'warden-a'),
      ),
    );
  });

  it('a student cannot set their own photo', async () => {
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await assertFails(
      photo(asUser('student-a'), COLLEGE_A, 'student-a').set(
        body('student-a', 'student-a'),
      ),
    );
  });

  it('users.edit cannot set their OWN photo either', async () => {
    await seed(COLLEGE_A, { wardenRole: ['users.edit'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertFails(
      photo(asUser('warden-a'), COLLEGE_A, 'warden-a').set(
        body('warden-a', 'warden-a'),
      ),
    );
  });

  it('a photo cannot be planted on a student from another college', async () => {
    await seed(COLLEGE_A, { wardenRole: ['users.edit'] });
    await seed(COLLEGE_B);
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_B, 'student-b', 'student');

    await assertFails(
      photo(asUser('warden-a'), COLLEGE_A, 'student-b').set(
        body('student-b', 'warden-a'),
      ),
    );
  });

  it('the uploader cannot be spoofed', async () => {
    await seed(COLLEGE_A, { wardenRole: ['users.edit'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await assertFails(
      photo(asUser('warden-a'), COLLEGE_A, 'student-a').set(
        body('student-a', 'someone-else'),
      ),
    );
  });

  it('an oversized photo is refused', async () => {
    await seed(COLLEGE_A, { wardenRole: ['users.edit'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await assertFails(
      photo(asUser('warden-a'), COLLEGE_A, 'student-a').set(
        body('student-a', 'warden-a', 'A'.repeat(150001)),
      ),
    );
  });

  it('a student can see their own photo but not a classmate\'s', async () => {
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'student-a', 'student');
    await seedUser(COLLEGE_A, 'student-b', 'student');
    await seedPhoto(COLLEGE_A, 'student-a');
    await seedPhoto(COLLEGE_A, 'student-b');

    const db = asUser('student-a');
    await assertSucceeds(photo(db, COLLEGE_A, 'student-a').get());
    await assertFails(photo(db, COLLEGE_A, 'student-b').get());
  });

  it('whoever runs the fines register can see the face on a fine', async () => {
    await seed(COLLEGE_A);
    await seedUser(COLLEGE_A, 'warden-a', 'warden');
    await seedUser(COLLEGE_A, 'student-a', 'student');
    await seedPhoto(COLLEGE_A, 'student-a');

    await assertSucceeds(photo(asUser('warden-a'), COLLEGE_A, 'student-a').get());
  });

  it('nobody can list every photo in the college', async () => {
    await seed(COLLEGE_A, { wardenRole: ['users.view', 'users.edit'] });
    await seedUser(COLLEGE_A, 'warden-a', 'warden');

    await assertFails(
      asUser('warden-a')
        .collection('colleges')
        .doc(COLLEGE_A)
        .collection('photos')
        .get(),
    );
  });
});

// The same photo writes, made by a Super Admin, in exactly the shape
// PhotoService.upload / remove send them: ONE batch that sets the photo doc
// and stamps users/{uid}.photoUpdatedAt. The block above tests the photo doc
// on its own with a users.edit role; this one proves the whole batch goes
// through for the account that holds no role permissions at all and relies
// on isSuperAdmin() inside hasPerm().
describe('ID photos — Super Admin', () => {
  const photo = (db, collegeId, uid) =>
    db.collection('colleges').doc(collegeId).collection('photos').doc(uid);

  // What prepare() can produce at most: 90 KB of JPEG -> 122,880 base64 chars.
  const BYTES = 'A'.repeat(4 * Math.ceil((90 * 1024) / 3));

  /** PhotoService.upload's batch, verbatim in shape. */
  function uploadBatch(db, collegeId, studentUid, actorUid) {
    const stamp = Timestamp.now();
    const batch = db.batch();
    batch.set(photo(db, collegeId, studentUid), {
      uid: studentUid,
      bytes: BYTES,
      mimeType: 'image/jpeg',
      updatedAt: stamp,
      updatedByUid: actorUid,
      updatedByName: 'Super Admin',
    });
    batch.update(db.collection('users').doc(studentUid), {
      photoUpdatedAt: stamp,
      updatedAt: serverTimestamp(),
    });
    return batch.commit();
  }

  /** PhotoService.remove's batch, verbatim in shape. */
  function removeBatch(db, collegeId, studentUid) {
    const batch = db.batch();
    batch.delete(photo(db, collegeId, studentUid));
    batch.update(db.collection('users').doc(studentUid), {
      photoUpdatedAt: deleteField(),
      updatedAt: serverTimestamp(),
    });
    return batch.commit();
  }

  /** The Super Admin as AuthService.register writes them. */
  async function seedSuperAdmin(collegeId, uid, roleId = 'super-admin') {
    await seedUser(collegeId, uid, roleId, {
      roleName: 'Super Admin',
      isSuperAdmin: true,
    });
  }

  async function seedExistingPhoto(collegeId, uid) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await photo(db, collegeId, uid).set({
        uid,
        bytes: 'aGVsbG8=',
        mimeType: 'image/jpeg',
        updatedAt: Timestamp.now(),
        updatedByUid: 'someone',
        updatedByName: 'Someone',
      });
      await db.collection('users').doc(uid).update({
        photoUpdatedAt: Timestamp.now(),
      });
    });
  }

  const smallPhoto = (uid, by) => ({
    uid,
    bytes: 'aGVsbG8=',
    mimeType: 'image/jpeg',
    updatedAt: Timestamp.now(),
    updatedByUid: by,
    updatedByName: 'Super Admin',
  });

  /** For the edge case that is recorded rather than asserted. */
  async function outcome(p) {
    try {
      await p;
      return 'ALLOWED';
    } catch (e) {
      return `DENIED (${e.code ?? ''}) ${String(e.message).split('\n')[0]}`;
    }
  }

  it('(a) a Super Admin can upload a student\'s photo (photo + users stamp, one batch)', async () => {
    await seed(COLLEGE_A);
    await seedSuperAdmin(COLLEGE_A, 'super-a');
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await assertSucceeds(
      uploadBatch(asUser('super-a'), COLLEGE_A, 'student-a', 'super-a'),
    );

    // And both halves actually landed.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      const p = await photo(db, COLLEGE_A, 'student-a').get();
      assert.equal(p.exists, true);
      assert.equal(p.data().bytes.length, BYTES.length);
      const u = await db.collection('users').doc('student-a').get();
      assert.ok(u.data().photoUpdatedAt, 'photoUpdatedAt should be stamped');
    });
  });

  it('(a) the same upload also works for a Super Admin with roleId null', async () => {
    await seed(COLLEGE_A);
    await seedSuperAdmin(COLLEGE_A, 'super-a', null);
    await seedUser(COLLEGE_A, 'student-a', 'student');

    await assertSucceeds(
      uploadBatch(asUser('super-a'), COLLEGE_A, 'student-a', 'super-a'),
    );
  });

  it('(a) a Super Admin can REPLACE an existing photo (set() on an existing doc = update)', async () => {
    await seed(COLLEGE_A);
    await seedSuperAdmin(COLLEGE_A, 'super-a');
    await seedUser(COLLEGE_A, 'student-a', 'student');
    await seedExistingPhoto(COLLEGE_A, 'student-a');

    await assertSucceeds(
      uploadBatch(asUser('super-a'), COLLEGE_A, 'student-a', 'super-a'),
    );
  });

  it('(b) a Super Admin can remove a student\'s photo (delete + clear stamp, one batch)', async () => {
    await seed(COLLEGE_A);
    await seedSuperAdmin(COLLEGE_A, 'super-a');
    await seedUser(COLLEGE_A, 'student-a', 'student');
    await seedExistingPhoto(COLLEGE_A, 'student-a');

    await assertSucceeds(removeBatch(asUser('super-a'), COLLEGE_A, 'student-a'));

    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      const p = await photo(db, COLLEGE_A, 'student-a').get();
      assert.equal(p.exists, false);
      const u = await db.collection('users').doc('student-a').get();
      assert.equal(u.data().photoUpdatedAt, undefined);
    });
  });

  it('(c) a Super Admin can read a student\'s photo', async () => {
    await seed(COLLEGE_A);
    await seedSuperAdmin(COLLEGE_A, 'super-a');
    await seedUser(COLLEGE_A, 'student-a', 'student');
    await seedExistingPhoto(COLLEGE_A, 'student-a');

    await assertSucceeds(photo(asUser('super-a'), COLLEGE_A, 'student-a').get());
  });

  it('(d) a Super Admin cannot set a photo on ANOTHER Super Admin (by design)', async () => {
    await seed(COLLEGE_A);
    await seedSuperAdmin(COLLEGE_A, 'super-a');
    await seedSuperAdmin(COLLEGE_A, 'super-b');

    const db = asUser('super-a');
    await assertFails(uploadBatch(db, COLLEGE_A, 'super-b', 'super-a'));
    // The photo rule refuses on its own, not just the users/{uid} half.
    await assertFails(
      photo(db, COLLEGE_A, 'super-b').set(smallPhoto('super-b', 'super-a')),
    );
  });

  it('(d) a Super Admin cannot set their OWN photo (by design)', async () => {
    await seed(COLLEGE_A);
    await seedSuperAdmin(COLLEGE_A, 'super-a');

    const db = asUser('super-a');
    await assertFails(uploadBatch(db, COLLEGE_A, 'super-a', 'super-a'));
    await assertFails(
      photo(db, COLLEGE_A, 'super-a').set(smallPhoto('super-a', 'super-a')),
    );
  });

  it('(e) [recorded, not asserted] student whose user doc has NO collegeId field', async () => {
    await seed(COLLEGE_A);
    await seedSuperAdmin(COLLEGE_A, 'super-a');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection('users').doc('student-x').set({
        name: 'No College',
        email: 'student-x@test.local',
        roleId: 'student',
        isActive: true,
        isSuperAdmin: false,
      });
    });

    const db = asUser('super-a');
    const batchResult = await outcome(
      uploadBatch(db, COLLEGE_A, 'student-x', 'super-a'),
    );
    const photoOnly = await outcome(
      photo(db, COLLEGE_A, 'student-x').set(smallPhoto('student-x', 'super-a')),
    );
    const usersOnly = await outcome(
      db.collection('users').doc('student-x').update({
        photoUpdatedAt: Timestamp.now(),
        updatedAt: serverTimestamp(),
      }),
    );
    console.log('      [e] full upload batch :', batchResult);
    console.log('      [e] photo doc alone   :', photoOnly);
    console.log('      [e] users stamp alone :', usersOnly);
  });
});
