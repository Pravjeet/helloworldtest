import { initAdmin, resolveCollege } from './lib.js';
const { db } = initAdmin();
const college = await resolveCollege(db, 'sliet-ms9lo7xf');
const snap = await db.collection('colleges').doc(college.id).collection('enrollments').limit(1).get();
console.log('enrollment documents that exist right now:', snap.size, snap.empty ? '(collection is empty)' : '');
