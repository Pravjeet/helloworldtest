// READ-ONLY: what does the QA workspace actually consist of?
import { initAdmin } from './lib.js';
const { db } = initAdmin();
const QA = 'qa-responsive-test-college-msflrt4p';

const colleges = await db.collection('colleges').get();
console.log(`colleges/ documents: ${colleges.size}`);
colleges.docs.forEach((d) => console.log(`   ${d.id}   name="${d.data().name ?? ''}"`));

const qaDoc = await db.collection('colleges').doc(QA).get();
console.log(`\nQA college doc exists: ${qaDoc.exists}`);

if (qaDoc.exists) {
  for (const sub of await qaDoc.ref.listCollections()) {
    const s = await sub.get();
    console.log(`   subcollection ${sub.id}: ${s.size} doc(s)`);
  }
}

const members = await db.collection('users').where('collegeId', '==', QA).get();
console.log(`\nusers pointing at the QA college: ${members.size}`);
members.docs.forEach((d) => console.log(`   ${d.id}  ${d.data().name}  super=${d.data().isSuperAdmin === true}`));
