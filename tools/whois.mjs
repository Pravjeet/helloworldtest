// READ-ONLY: who the surviving accounts are.
import { initAdmin, resolveCollege } from './lib.js';

const { db, auth } = initAdmin();
const college = await resolveCollege(db);

const page = await auth.listUsers(1000);
console.log(`${page.users.length} Auth account(s):\n`);

for (const u of page.users) {
  const doc = await db.collection('users').doc(u.uid).get();
  const p = doc.exists ? doc.data() : null;
  console.log(`  email        : ${u.email ?? '(none)'}`);
  console.log(`  uid          : ${u.uid}`);
  console.log(`  created      : ${u.metadata.creationTime}`);
  console.log(`  last sign-in : ${u.metadata.lastSignInTime ?? '(never)'}`);
  if (!p) {
    console.log('  profile      : NONE (orphan)');
  } else {
    console.log(`  name         : ${p.name ?? '(unnamed)'}`);
    console.log(`  role         : ${p.roleName ?? '(none)'}${p.isSuperAdmin ? '   [SUPER ADMIN]' : ''}`);
    console.log(`  college      : ${p.collegeId}${p.collegeId === college.id ? ' (this one)' : ' (OTHER)'}`);
    console.log(`  active       : ${p.isActive !== false}`);
    console.log(`  hostel/room  : ${p.hostelName ?? '—'} / ${p.roomNumber ?? '—'}`);
  }
  console.log('');
}
