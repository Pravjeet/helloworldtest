#!/usr/bin/env node
/**
 * Removes imported students — Auth account AND Firestore profile — and frees
 * the rooms they held.
 *
 *   node delete-students.js --from-csv ../students.csv           # preview
 *   node delete-students.js --from-csv ../students.csv --commit  # do it
 *   node delete-students.js --all-students --commit              # everyone
 *
 * This is the counterpart the app cannot provide: `deleteUserProfile` in the
 * Flutter app deletes the Firestore document only, leaving the Auth login
 * alive forever with nothing behind it. That orphan is why re-importing the
 * same registration number used to fail with "email already in use".
 *
 * Guards, because this is the destructive one:
 *   - dry run unless --commit is passed
 *   - a Super Admin is never touched, under any flag
 *   - --all-students additionally requires --i-mean-it
 */

import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

import { FieldValue } from 'firebase-admin/firestore';

import {
  initAdmin, resolveCollege, parseArgs, parseDelimited, rowToValues,
  toAuthEmail, chunk,
} from './lib.js';

const args = parseArgs(process.argv.slice(2));
const commit = args.commit === true;

// Only used below for freeing rooms — the account deletes further down
// already go through Admin SDK bulk calls (one auth.deleteUsers() RPC per
// 1000 uids, one Firestore batch per 400 docs), so there's no per-row loop
// there to parallelise. This is the one part of the script that was still
// reading one room at a time.
const CONCURRENCY = Number(args.concurrency) > 0 ? Number(args.concurrency) : 10;
const fromCsv = typeof args['from-csv'] === 'string' ? args['from-csv'] : null;
const allStudents = args['all-students'] === true;
const orphans = args.orphans === true;

if (!fromCsv && !allStudents && !orphans) {
  console.error(
    'Usage:\n' +
    '  node delete-students.js --from-csv <file.csv> [--commit]\n' +
    '  node delete-students.js --all-students --i-mean-it [--commit]\n' +
    '  node delete-students.js --orphans [--commit]\n\n' +
    '--orphans removes sign-in accounts that have no profile document —\n' +
    'the leftovers from deleting someone whose password the app could not\n' +
    'reconstruct. Those are what cause "email already in use" on re-import.\n\n' +
    'Without --commit it prints what WOULD be deleted and changes nothing.'
  );
  process.exit(1);
}
if (allStudents && args['i-mean-it'] !== true) {
  console.error(
    '--all-students deletes every non-admin account in the college.\n' +
    'If that is really what you want, add --i-mean-it as well.'
  );
  process.exit(1);
}

const { auth, db, projectId } = initAdmin();
const college = await resolveCollege(db, args.college);

console.log(`\nProject : ${projectId}`);
console.log(`College : ${college.id}  (${college.name})`);
console.log(commit ? 'Mode    : COMMIT — this will delete\n' : 'Mode    : DRY RUN — nothing will be deleted\n');

// --- orphaned sign-in accounts -------------------------------------------
//
// An Auth account with no `users/{uid}` document behind it. Created whenever
// a profile is deleted but the Auth side could not be — which the app cannot
// always do, because deleting from a browser needs the account's password and
// only derived ones are reconstructible.
//
// Deliberately scoped to accounts with NO profile anywhere, not "no profile in
// this college": a uid belonging to another workspace is not ours to remove.

if (orphans) {
  const profiles = await db.collection('users').get();
  const known = new Set(profiles.docs.map((d) => d.id));

  const found = [];
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    for (const u of page.users) {
      if (!known.has(u.uid)) {
        found.push({ uid: u.uid, email: u.email ?? '(no email)', created: u.metadata.creationTime });
      }
    }
    pageToken = page.pageToken;
  } while (pageToken);

  if (!found.length) {
    console.log('No orphaned sign-in accounts. Nothing to do.\n');
    process.exit(0);
  }

  found.forEach((u) => console.log(`  ${u.email.padEnd(38)} created ${u.created}`));
  console.log(`\n${found.length} orphaned sign-in account(s).`);

  if (!commit) {
    console.log('\nDry run — nothing deleted. Re-run with --commit.\n');
    process.exit(0);
  }

  let removed = 0;
  const problems = [];
  for (const group of chunk(found.map((u) => u.uid), 1000)) {
    const res = await auth.deleteUsers(group);
    removed += res.successCount;
    res.errors.forEach((e) => problems.push(`${group[e.index]}: ${e.error.message}`));
  }
  console.log(`Deleted ${removed} orphaned account(s).`);
  problems.forEach((p) => console.log(`  ! ${p}`));
  console.log('');
  process.exit(problems.length ? 1 : 0);
}

// --- work out who ---------------------------------------------------------

const userSnap = await db.collection('users')
  .where('collegeId', '==', college.id).get();

let targets = userSnap.docs
  .map((d) => ({ uid: d.id, ...d.data() }))
  .filter((u) => u.isSuperAdmin !== true);   // never, under any flag

if (fromCsv) {
  const path = resolve(process.cwd(), fromCsv);
  if (!existsSync(path)) {
    console.error(`No such file: ${path}`);
    process.exit(1);
  }
  const table = parseDelimited(readFileSync(path, 'utf8'));
  const wanted = new Set(
    table.rows
      .map((raw) => rowToValues(table.headers, raw))
      .map((v) => toAuthEmail(v.email || v.registrationNo || ''))
      .filter(Boolean)
  );
  targets = targets.filter((u) => wanted.has(String(u.email ?? '').toLowerCase()));
}

if (!targets.length) {
  console.log('Nothing matches. Nothing to delete.\n');
  process.exit(0);
}

targets.forEach((u) => {
  const room = u.roomId ? `  (${u.hostelName} room ${u.roomNumber})` : '';
  console.log(`  ${String(u.name ?? '?').padEnd(28)} ${u.email}${room}`);
});
console.log(`\n${targets.length} account(s) would be deleted.`);

if (!commit) {
  console.log('\nDry run — nothing was deleted. Re-run with --commit to apply.\n');
  process.exit(0);
}

// --- free the rooms first -------------------------------------------------
//
// Before the profiles go, take each student out of their room's occupantUids
// and decrement the hostel's bed counter. Skipping this would leave rooms
// showing occupants that no longer exist and a permanently wrong
// "beds occupied" figure on the hostels page.

const roomWrites = [];
const bedDelta = new Map();
const byRoom = new Map();

for (const u of targets) {
  if (!u.hostelId || !u.roomId) continue;
  const key = `${u.hostelId}/${u.roomId}`;
  if (!byRoom.has(key)) byRoom.set(key, []);
  byRoom.get(key).push(u.uid);
}

// bedDelta is a Map and roomWrites an array — both fine to mutate from
// concurrent closures below since Node is single-threaded; the awaits are
// what overlap, not the pushes/sets themselves.
for (const group of chunk([...byRoom], CONCURRENCY)) {
  await Promise.all(group.map(async ([key, uids]) => {
    const [hostelId, roomId] = key.split('/');
    const ref = db.collection('colleges').doc(college.id)
      .collection('hostels').doc(hostelId).collection('rooms').doc(roomId);
    const snap = await ref.get();
    if (!snap.exists) return;

    const occupants = snap.data().occupantUids ?? [];
    const remaining = occupants.filter((id) => !uids.includes(id));
    const removed = occupants.length - remaining.length;
    if (!removed) return;

    roomWrites.push({ ref, data: { occupantUids: remaining } });
    bedDelta.set(hostelId, (bedDelta.get(hostelId) ?? 0) + removed);
  }));
}

for (const [hostelId, delta] of bedDelta) {
  roomWrites.push({
    ref: db.collection('colleges').doc(college.id)
      .collection('hostels').doc(hostelId),
    data: { occupiedBeds: FieldValue.increment(-delta) },
  });
}

for (const group of chunk(roomWrites, 400)) {
  const batch = db.batch();
  group.forEach((w) => batch.set(w.ref, w.data, { merge: true }));
  await batch.commit();
}
if (roomWrites.length) console.log(`Freed ${bedDelta.size ? [...bedDelta.values()].reduce((a, b) => a + b, 0) : 0} bed(s).`);

// --- delete profiles then accounts ---------------------------------------

for (const group of chunk(targets, 400)) {
  const batch = db.batch();
  group.forEach((u) => batch.delete(db.collection('users').doc(u.uid)));
  await batch.commit();
}
console.log(`Deleted ${targets.length} Firestore profile(s).`);

// deleteUsers takes up to 1000 at a time and reports per-uid failures.
let authDeleted = 0;
const authFailures = [];
for (const group of chunk(targets.map((u) => u.uid), 1000)) {
  const res = await auth.deleteUsers(group);
  authDeleted += res.successCount;
  res.errors.forEach((e) => authFailures.push(`${group[e.index]}: ${e.error.message}`));
}

console.log(`Deleted ${authDeleted} Auth account(s).`);
if (authFailures.length) {
  console.log('\nThese Auth accounts could not be removed:');
  authFailures.forEach((f) => console.log(`  ${f}`));
}
console.log('');

process.exit(authFailures.length ? 1 : 0);
