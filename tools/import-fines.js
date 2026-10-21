#!/usr/bin/env node
/**
 * Seeds fines from a CSV, for populating the dashboard during testing.
 *
 *   node import-fines.js ../fines.csv            # preview, writes nothing
 *   node import-fines.js ../fines.csv --commit   # actually write
 *   node import-fines.js --clear --commit        # delete every fine
 *
 * A fine belongs to a student but is NOT a column on them — one student has
 * many fines — so this reads its own file, keyed by registration number.
 *
 * The student's name, hostel, room, trade, batch and semester are snapshotted
 * onto each fine from the LIVE student record, exactly as the app does when a
 * warden imposes one. That is what lets the dashboard aggregate 60 fines
 * without reading 60 user documents, and it keeps a fine attributed to where
 * the student was when it happened.
 *
 * CSV columns:
 *   registrationNo   which student (required)
 *   amount           number, required
 *   category         Damage to property | Discipline | Late return |
 *                    Mess violation | Unauthorised absence | Other
 *   reason           free text
 *   status           pending | paid | waived     (default pending)
 *   officeOrderNo    optional reference
 *   date             DD/MM/YYYY — when it was imposed (default: now)
 *   studentName      ignored; present so the file is readable by a human
 */

import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

import { Timestamp } from 'firebase-admin/firestore';

import {
  initAdmin, resolveCollege, parseArgs, parseDelimited, rowToValues, chunk,
  stateFromAddress,
} from './lib.js';

const CATEGORIES = [
  'Damage to property', 'Discipline', 'Late return',
  'Mess violation', 'Unauthorised absence', 'Other',
];
const STATUSES = ['pending', 'paid', 'waived'];

const args = parseArgs(process.argv.slice(2));
const commit = args.commit === true;
const clear = args.clear === true;
const backfill = args.backfill === true;
const csvPath = args._[0];

if (!clear && !backfill && !csvPath) {
  console.error(
    'Usage:\n' +
    '  node import-fines.js <fines.csv> [--commit] [--college <id>]\n' +
    '  node import-fines.js --clear [--commit]     # delete every fine\n' +
    '  node import-fines.js --backfill [--commit]  # re-snapshot student\n' +
    '                                              # fields onto existing fines\n\n' +
    'Without --commit nothing is written.'
  );
  process.exit(1);
}

const { db, projectId } = initAdmin();
const college = await resolveCollege(db, args.college);
const finesCol = db.collection('colleges').doc(college.id).collection('fines');

console.log(`\nProject : ${projectId}`);
console.log(`College : ${college.id}  (${college.name})`);
console.log(commit ? 'Mode    : COMMIT — this will write\n' : 'Mode    : DRY RUN — nothing will be written\n');

// ------------------------------------------------------------------ clear

if (clear) {
  const existing = await finesCol.get();
  console.log(`${existing.size} fine(s) currently recorded.`);
  if (!commit) {
    console.log('\nDry run — nothing deleted. Re-run with --commit.\n');
    process.exit(0);
  }
  for (const group of chunk(existing.docs, 400)) {
    const batch = db.batch();
    group.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }
  console.log(`Deleted ${existing.size} fine(s).\n`);
  process.exit(0);
}

// --------------------------------------------------------------- backfill
//
// Re-copies the student's current trade/batch/sem/state/hostel/room onto every
// existing fine. Needed whenever a new dimension is added to the dashboard:
// fines written before the field existed have it as null, so they all pile
// into a single "Not set" bar and the chart looks broken.
//
// Note this DOES overwrite the historical snapshot with today's values. That
// is the right trade for a field being introduced (there is nothing to
// preserve), and the wrong one if a student has since changed room. Run it
// once after adding a field, not routinely.

if (backfill) {
  const usersSnap = await db.collection('users')
    .where('collegeId', '==', college.id).get();
  const byUid = new Map(usersSnap.docs.map((d) => [d.id, d.data()]));

  const finesSnap = await finesCol.get();
  const updates = [];

  for (const doc of finesSnap.docs) {
    const f = doc.data();
    const s = byUid.get(f.studentUid);
    if (!s) continue;

    const next = {
      studentName: s.name ?? f.studentName,
      studentRegNo: s.enrollmentNo ?? null,
      hostelId: s.hostelId ?? null,
      hostelName: s.hostelName ?? null,
      roomNumber: s.roomNumber ?? null,
      trade: s.trade ?? null,
      batch: s.batch ?? null,
      sem: s.sem ?? null,
      state: s.state ?? stateFromAddress(s.address) ?? null,
    };
    const changed = Object.keys(next).some((k) => (f[k] ?? null) !== next[k]);
    if (changed) updates.push({ ref: doc.ref, data: next });
  }

  console.log(`${finesSnap.size} fine(s) on record · ${updates.length} would change.`);
  if (!commit) {
    console.log('\nDry run — nothing written. Re-run with --commit.\n');
    process.exit(0);
  }
  for (const group of chunk(updates, 400)) {
    const batch = db.batch();
    group.forEach((u) => batch.set(u.ref, u.data, { merge: true }));
    await batch.commit();
  }
  console.log(`Updated ${updates.length} fine(s).\n`);
  process.exit(0);
}

// ------------------------------------------------------------------ load

const fullPath = resolve(process.cwd(), csvPath);
if (!existsSync(fullPath)) {
  console.error(`No such file: ${fullPath}`);
  process.exit(1);
}

// Who to record as the imposer. The workspace owner is the honest answer for
// seeded data — inventing a fake warden would put a name in the audit trail
// that belongs to nobody.
const admins = await db.collection('users')
  .where('collegeId', '==', college.id)
  .where('isSuperAdmin', '==', true)
  .limit(1).get();

if (admins.empty) {
  console.error('No Super Admin found for this college — cannot attribute fines.');
  process.exit(1);
}
const imposer = { uid: admins.docs[0].id, name: admins.docs[0].data().name ?? 'Admin' };

// Students, indexed by registration number.
const userSnap = await db.collection('users')
  .where('collegeId', '==', college.id).get();
const byReg = new Map();
userSnap.docs.forEach((d) => {
  const u = d.data();
  if (u.enrollmentNo) byReg.set(String(u.enrollmentNo).trim(), { uid: d.id, ...u });
});

const table = parseDelimited(readFileSync(fullPath, 'utf8'));
const plan = [];

table.rows.forEach((raw, i) => {
  const v = rowToValues(table.headers, raw);
  const line = i + 2;
  const problems = [];

  const reg = (v.registrationNo ?? '').trim();
  const student = byReg.get(reg);
  if (!reg) problems.push('no registrationNo');
  else if (!student) problems.push(`no student with registration number ${reg}`);

  const amount = Number(v.amount);
  if (!Number.isFinite(amount) || amount <= 0) {
    problems.push(`amount "${v.amount}" is not a positive number`);
  }

  const category = CATEGORIES.find(
    (c) => c.toLowerCase() === (v.category ?? '').trim().toLowerCase()
  ) ?? 'Other';

  const status = STATUSES.includes((v.status ?? '').trim().toLowerCase())
    ? v.status.trim().toLowerCase()
    : 'pending';

  // DD/MM/YYYY — the format the rest of the project's sheets use.
  let createdAt = new Date();
  if (v.date) {
    const m = v.date.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
    if (m) createdAt = new Date(Number(m[3]), Number(m[2]) - 1, Number(m[1]), 10, 0, 0);
    else problems.push(`date "${v.date}" is not DD/MM/YYYY`);
  }

  plan.push({ line, v, student, amount, category, status, createdAt, problems });
});

const good = plan.filter((p) => !p.problems.length);
const bad = plan.filter((p) => p.problems.length);

bad.forEach((p) => {
  console.log(`SKIP  line ${String(p.line).padStart(3)}  ${p.problems.join('; ')}`);
});

const total = good.reduce((a, p) => a + p.amount, 0);
console.log(`\n${good.length} fine(s) to write · total ₹${total.toLocaleString('en-IN')} · ${bad.length} skipped`);

const byStatus = {};
good.forEach((p) => { byStatus[p.status] = (byStatus[p.status] ?? 0) + 1; });
console.log(Object.entries(byStatus).map(([k, n]) => `  ${k}: ${n}`).join('\n'));

const existing = await finesCol.limit(1).get();
if (!existing.empty) {
  console.log(
    '\nNote: this college already has fines recorded. This ADDS to them — ' +
    'run with --clear --commit first if you want a clean slate.'
  );
}

if (!commit) {
  console.log('\nDry run — nothing was written. Re-run with --commit to apply.\n');
  process.exit(0);
}
if (!good.length) {
  console.log('\nNothing to write.\n');
  process.exit(0);
}

// ----------------------------------------------------------------- write

console.log('\nWriting…');

for (const group of chunk(good, 400)) {
  const batch = db.batch();
  for (const p of group) {
    const s = p.student;
    const settled = p.status !== 'pending';
    batch.set(finesCol.doc(), {
      studentUid: s.uid,
      studentName: s.name ?? 'Unknown',
      studentRegNo: s.enrollmentNo ?? null,
      hostelId: s.hostelId ?? null,
      hostelName: s.hostelName ?? null,
      roomNumber: s.roomNumber ?? null,
      trade: s.trade ?? null,
      batch: s.batch ?? null,
      sem: s.sem ?? null,
      // Falls back to the address so the by-state chart works even for a
      // student whose `state` field was never filled in.
      state: s.state ?? stateFromAddress(s.address) ?? null,
      amount: p.amount,
      category: p.category,
      reason: (p.v.reason ?? '').trim(),
      status: p.status,
      officeOrderNo: (p.v.officeOrderNo ?? '').trim() || null,
      imposedByUid: imposer.uid,
      imposedByName: imposer.name,
      resolvedByUid: settled ? imposer.uid : null,
      resolvedByName: settled ? imposer.name : null,
      resolvedAt: settled ? Timestamp.fromDate(p.createdAt) : null,
      createdAt: Timestamp.fromDate(p.createdAt),
    });
  }
  await batch.commit();
  process.stdout.write('.'.repeat(group.length));
}

console.log(`\n\nWrote ${good.length} fine(s). Open the Fines page to see the dashboard.\n`);
process.exit(0);
