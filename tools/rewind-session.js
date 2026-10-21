#!/usr/bin/env node
/**
 * Rewinds the workspace to an earlier academic session, as if the promotions
 * after it had never been run.
 *
 *   node rewind-session.js --to 2025-26            # preview
 *   node rewind-session.js --to 2025-26 --commit   # do it
 *
 * "Reset session" in System Settings only blanks the session setting — every
 * promotion's results stay behind. This undoes them, using the target
 * session's own enrollment records as the picture to restore. Those records
 * are written once per student when the session is backfilled, so for the
 * first session they are exactly the state the import produced.
 *
 * What it does, in order:
 *   1. deletes every enrollment record for a session AFTER --to
 *   2. un-graduates every graduated student (removes `status`, which an
 *      imported student never had — the app reads a missing status as active)
 *   3. puts every room's occupants, every hostel's bed counter and every
 *      student's hostel/room back to what the --to records say
 *   4. sets the current session to --to and clears "next session"
 *
 * Deliberately NOT touched: hostels and rooms themselves (including
 * maintenance flags), fines, fees, requests, office orders, notices, roles,
 * settings other than the session, the audit log, Super Admins.
 *
 * Guards: dry run unless --commit; refuses a --to session that has no
 * records; refuses to run against a different Firebase project (lib.js).
 */

import { FieldValue } from 'firebase-admin/firestore';

import { initAdmin, resolveCollege, parseArgs, chunk } from './lib.js';

const args = parseArgs(process.argv.slice(2));
const commit = args.commit === true;
const target = typeof args.to === 'string' ? args.to.trim() : null;

if (!target || !/^\d{4}-\d{2}$/.test(target)) {
  console.error('Usage: node rewind-session.js --to 2025-26 [--commit] [--college <id>]');
  process.exit(1);
}

const { db } = initAdmin();
const college = await resolveCollege(db, args.college);
const cid = college.id;
const collegeRef = db.collection('colleges').doc(cid);
const enrollments = collegeRef.collection('enrollments');

console.log(`College : ${college.name} (${cid})`);
console.log(`Rewind  : to ${target}`);
console.log(commit ? 'Mode    : COMMIT — this will change data\n' : 'Mode    : DRY RUN — nothing will be changed\n');

// ------------------------------------------------------------ read
const targetSnap = await enrollments.where('session', '==', target).get();
if (targetSnap.empty) {
  console.error(`No ${target} enrollment records exist — nothing to rewind to.`);
  process.exit(1);
}

// "2026-27" > "2025-26" as strings, because every session is YYYY-YY.
const laterSnap = await enrollments.where('session', '>', target).get();
const laterBySession = {};
for (const d of laterSnap.docs) {
  const s = d.data().session;
  laterBySession[s] = (laterBySession[s] ?? 0) + 1;
}

const gradSnap = await db.collection('users')
  .where('collegeId', '==', cid)
  .where('status', '==', 'graduated')
  .get();

// Where everyone should be, per the target session's records.
const wanted = new Map();
for (const d of targetSnap.docs) {
  const e = d.data();
  wanted.set(e.uid, e.hostelId && e.roomId
    ? { hostelId: e.hostelId, hostelName: e.hostelName ?? null, roomId: e.roomId, roomNumber: e.roomNumber ?? null }
    : { hostelId: null, hostelName: null, roomId: null, roomNumber: null });
}

// Rooms: desired occupants vs actual.
const hostelsSnap = await collegeRef.collection('hostels').get();
const roomWrites = [];
const hostelWrites = [];
for (const h of hostelsSnap.docs) {
  const rooms = await h.ref.collection('rooms').get();
  let occupied = 0;
  for (const r of rooms.docs) {
    const want = [...wanted.entries()]
      .filter(([, w]) => w.hostelId === h.id && w.roomId === r.id)
      .map(([uid]) => uid)
      .sort();
    occupied += want.length;
    const have = [...(r.data().occupantUids ?? [])].sort();
    if (want.join() !== have.join()) roomWrites.push({ ref: r.ref, occupantUids: want, label: `${h.data().code || h.data().name} ${r.id}` });
  }
  if ((h.data().occupiedBeds ?? 0) !== occupied) hostelWrites.push({ ref: h.ref, occupiedBeds: occupied });
}

// Students whose own hostel/room fields need changing: anyone holding one
// now, plus anyone the target session says should hold one.
const holdingSnap = await db.collection('users')
  .where('collegeId', '==', cid)
  .where('hostelId', '!=', null)
  .get();
const userDocs = new Map(holdingSnap.docs.map((d) => [d.id, d]));
const missing = [...wanted.entries()].filter(([uid, w]) => w.hostelId && !userDocs.has(uid)).map(([uid]) => uid);
for (const part of chunk(missing, 300)) {
  const got = await db.getAll(...part.map((u) => db.collection('users').doc(u)));
  for (const d of got) if (d.exists) userDocs.set(d.id, d);
}
const userWrites = [];
for (const [uid, d] of userDocs) {
  const u = d.data();
  if (u.isSuperAdmin) continue;
  const w = wanted.get(uid) ?? { hostelId: null, hostelName: null, roomId: null, roomNumber: null };
  if ((u.hostelId ?? null) !== w.hostelId || (u.roomId ?? null) !== w.roomId) {
    userWrites.push({ ref: d.ref, fields: { ...w, allottedAt: w.roomId ? (u.allottedAt ?? FieldValue.serverTimestamp()) : null } });
  }
}

const settingsRef = collegeRef.collection('settings').doc('config');
const session = (await settingsRef.get()).data()?.session ?? {};

// ------------------------------------------------------------ report
console.log(`${target} records (the picture restored) : ${targetSnap.size}`);
console.log(`later-session records to delete         : ${laterSnap.size}`, laterBySession);
console.log(`graduated students to restore           : ${gradSnap.size}`);
console.log(`rooms whose occupants change            : ${roomWrites.length}`);
console.log(`hostel bed counters corrected           : ${hostelWrites.length}`);
console.log(`students whose hostel/room changes      : ${userWrites.length}`);
console.log(`session setting                         : ${JSON.stringify({ current: session.current ?? null, next: session.next ?? null })} -> ${JSON.stringify({ current: target, next: null })}`);
for (const r of roomWrites.slice(0, 15)) console.log(`   room ${r.label} -> [${r.occupantUids.length}]`);

if (!commit) {
  console.log('\nDry run — nothing was changed. Re-run with --commit to apply.\n');
  process.exit(0);
}

// ------------------------------------------------------------ write
const ops = [
  ...laterSnap.docs.map((d) => (b) => b.delete(d.ref)),
  ...gradSnap.docs.map((d) => (b) => b.update(d.ref, { status: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() })),
  ...roomWrites.map((r) => (b) => b.update(r.ref, { occupantUids: r.occupantUids })),
  ...hostelWrites.map((h) => (b) => b.update(h.ref, { occupiedBeds: h.occupiedBeds })),
  ...userWrites.map((u) => (b) => b.update(u.ref, { ...u.fields, updatedAt: FieldValue.serverTimestamp() })),
];
let done = 0;
for (const part of chunk(ops, 400)) {
  const batch = db.batch();
  for (const op of part) op(batch);
  await batch.commit();
  done += part.length;
  process.stdout.write(`\r  ${done}/${ops.length} writes`);
}
await settingsRef.set({ session: { ...session, current: target, next: null } }, { merge: true });
console.log(`\nDone. Workspace rewound to ${target}.`);
