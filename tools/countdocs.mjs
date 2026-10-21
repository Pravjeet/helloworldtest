// READ-ONLY: how much legacy data would a schema change have to carry?
import { initAdmin } from './lib.js';
const { db } = initAdmin();
const colleges = await db.collection('colleges').get();
for (const c of colleges.docs) {
  console.log(`\n=== ${c.data().name}  (${c.id}) ===`);
  for (const name of ['officeOrders', 'fines', 'hostels', 'notices']) {
    const snap = await db.collection('colleges').doc(c.id).collection(name).get();
    let legacy = 0;
    if (name === 'officeOrders') {
      snap.docs.forEach((d) => { if (d.data().studentUid !== undefined) legacy++; });
    }
    console.log(`  ${name.padEnd(13)} ${String(snap.size).padStart(4)}` +
      (name === 'officeOrders' && snap.size ? `   (${legacy} old single-student shape)` : ''));
  }
  const users = await db.collection('users').where('collegeId','==',c.id).get();
  console.log(`  users         ${String(users.size).padStart(4)}`);
}
