// READ-ONLY preflight for the import. Writes nothing.
import { initAdmin, resolveCollege, parseDelimited, rowToValues } from './lib.js';
import { readFileSync } from 'node:fs';

const { db, auth } = initAdmin();
const college = await resolveCollege(db);
console.log(`College: ${college.name}  (${college.id})\n`);

// 1. orphans still gone?
const profiles = await db.collection('users').get();
const known = new Set(profiles.docs.map((d) => d.id));
let orphans = 0, authTotal = 0, pageToken;
do {
  const page = await auth.listUsers(1000, pageToken);
  authTotal += page.users.length;
  for (const u of page.users) if (!known.has(u.uid)) orphans++;
  pageToken = page.pageToken;
} while (pageToken);
console.log(`Auth accounts      : ${authTotal}`);
console.log(`Firestore profiles : ${profiles.size}`);
console.log(`ORPHANS            : ${orphans}${orphans ? '   <-- still blocking' : '   (clear)'}\n`);

// 2. roles
const roles = await db.collection('colleges').doc(college.id).collection('roles').get();
console.log('Roles:');
roles.docs.forEach((d) => console.log(`   ${d.data().name}${d.data().isSystem ? '  (system, not assignable)' : ''}`));
const assignable = roles.docs.filter((d) => !d.data().isSystem).map((d) => d.data().name);
console.log(`   -> "Student" assignable? ${assignable.some((n) => n.toLowerCase() === 'student') ? 'YES' : 'NO — rows fall back with a warning'}\n`);

// 3. hostels + room capacity
const hostels = await db.collection('colleges').doc(college.id).collection('hostels').get();
console.log(`Hostels in workspace: ${hostels.size}`);
const byKey = new Map();
for (const d of hostels.docs) {
  const h = d.data();
  console.log(`   name="${h.name}" code="${h.code ?? ''}" rooms=${h.roomCount ?? 0} beds=${h.bedCount ?? 0}`);
  byKey.set((h.name ?? '').toLowerCase(), d);
  if (h.code) byKey.set(h.code.toLowerCase(), d);
}

// what the sheet asks for
const t = parseDelimited(readFileSync(process.argv[2], 'utf8'));
const rows = t.rows.map((r, i) => ({ line: i + 2, v: rowToValues(t.headers, r) }));
const wanted = new Map();
rows.forEach(({ v }) => { if (v.hostel) wanted.set(v.hostel, (wanted.get(v.hostel) ?? 0) + 1); });

console.log('\nHostels the sheet names:');
let unmatched = 0;
for (const [name, n] of [...wanted.entries()].sort()) {
  const hit = byKey.get(name.toLowerCase());
  if (!hit) unmatched += n;
  console.log(`   "${name}" x${n}  -> ${hit ? `matches ${hit.data().name}` : 'NO MATCH — allotment skipped'}`);
}
console.log(`\nRows whose hostel will not resolve: ${unmatched}`);

// 4. capacity for the rows that want an actual bed
const beds = new Map();
rows.filter(({ v }) => v.hostel && v.room).forEach(({ v }) => {
  const k = `${v.hostel}||${v.room}`;
  beds.set(k, (beds.get(k) ?? 0) + 1);
});
console.log(`\nRooms the sheet wants filled: ${beds.size}`);
let over = 0, missing = 0;
for (const [k, want] of beds) {
  const [hName, roomNo] = k.split('||');
  const h = byKey.get(hName.toLowerCase());
  if (!h) continue;
  const roomDoc = await db.collection('colleges').doc(college.id)
    .collection('hostels').doc(h.id).collection('rooms').doc(roomNo).get();
  if (!roomDoc.exists) { missing++; console.log(`   MISSING room ${hName}/${roomNo} (wants ${want})`); continue; }
  const cap = roomDoc.data().capacity ?? 0;
  const taken = (roomDoc.data().occupantUids ?? []).length;
  if (want > cap - taken) {
    over++;
    console.log(`   OVER  ${hName}/${roomNo}: wants ${want}, capacity ${cap}, already ${taken}`);
  }
}
console.log(`\nRooms missing entirely : ${missing}`);
console.log(`Rooms over capacity    : ${over}`);
