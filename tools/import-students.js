#!/usr/bin/env node
/**
 * Bulk student import via the Firebase Admin SDK.
 *
 *   node import-students.js ../students.csv            # preview, writes nothing
 *   node import-students.js ../students.csv --commit   # actually import
 *
 * Why this exists: the in-app importer has to create accounts the way a member
 * of the public would — one at a time, through the front door — because a
 * browser is untrusted. Firebase throttles that after a dozen or so, which is
 * why a 30-row import crawls or fails. This runs with a service-account key,
 * so it goes through the back door: no throttle, no secondary-app hack, and
 * it can delete Auth accounts, which the app genuinely cannot.
 *
 * Re-running is safe. A registration number that already exists is UPDATED,
 * never duplicated — so a half-finished run is fixed by running it again.
 */

import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  initAdmin, resolveCollege, parseArgs, parseDelimited, rowToValues,
  profileFor, toAuthEmail, derivedPassword, isValidRegistrationNumber,
  normaliseGender, parseSem, TRADES, chunk, IMPORT_COLUMNS, withThrottleRetry,
} from './lib.js';

import { FieldValue } from 'firebase-admin/firestore';

const args = parseArgs(process.argv.slice(2));
const csvPath = args._[0];
const commit = args.commit === true;

// How many accounts to create at once. Sequential (1) is what the in-app
// importer is stuck with — it has to look like a browser. This script has a
// service-account key, so it doesn't: 10 concurrent `createUser` calls finish
// in roughly a tenth of the time and, per Firebase, stay well under the
// threshold that trips the "unusual activity" block. Push it higher at your
// own risk — that block is a project-wide quota, not a per-row retry.
const CONCURRENCY = Number(args.concurrency) > 0 ? Number(args.concurrency) : 10;

if (!csvPath) {
  console.error(
    'Usage: node import-students.js <file.csv> [--commit] [--college <id>] ' +
    '[--role <name>] [--concurrency <n>]\n\n' +
    'Without --commit it prints what WOULD happen and writes nothing.\n' +
    '--concurrency controls how many accounts are created in parallel ' +
    '(default 10).'
  );
  process.exit(1);
}

const fullPath = resolve(process.cwd(), csvPath);
if (!existsSync(fullPath)) {
  console.error(`No such file: ${fullPath}`);
  process.exit(1);
}

const { auth, db, projectId } = initAdmin();

// ---------------------------------------------------------------------

const college = await resolveCollege(db, args.college);
const defaultRoleName = args.role ?? 'Student';

console.log(`\nProject : ${projectId}`);
console.log(`College : ${college.id}  (${college.name})`);
console.log(`File    : ${fullPath}`);
console.log(commit ? 'Mode    : COMMIT — this will write\n' : 'Mode    : DRY RUN — nothing will be written\n');

// --- roles ---------------------------------------------------------------

const roleSnap = await db.collection('colleges').doc(college.id)
  .collection('roles').get();
const roles = roleSnap.docs
  .map((d) => ({ id: d.id, ...d.data() }))
  .filter((r) => r.isSystem !== true);

if (!roles.length) {
  console.error(
    'This college has no assignable roles. Create one under ' +
    'Roles & Permissions in the app first.'
  );
  process.exit(1);
}

const findRole = (wanted) =>
  roles.find((r) => r.name.toLowerCase() === (wanted ?? '').toLowerCase());

const fallbackRole = findRole(defaultRoleName) ?? roles[0];

// --- existing users ------------------------------------------------------

const userSnap = await db.collection('users')
  .where('collegeId', '==', college.id).get();
const byEmail = new Map(
  userSnap.docs.map((d) => [String(d.data().email ?? '').toLowerCase(), { uid: d.id, ...d.data() }])
);

// --- parse ---------------------------------------------------------------

const table = parseDelimited(readFileSync(fullPath, 'utf8'));
if (!table.rows.length) {
  console.error('That file has a header row but no data rows.');
  process.exit(1);
}

const unknown = table.headers.filter((h) => !IMPORT_COLUMNS.includes(h));
if (unknown.length) {
  console.log(`Ignoring unrecognised column(s): ${unknown.join(', ')}\n`);
}

const plan = [];
const seen = new Set();

table.rows.forEach((raw, i) => {
  const values = rowToValues(table.headers, raw);
  const problems = [];
  const warnings = [];

  const name = values.name ?? '';
  if (name.trim().length < 2) problems.push('name is missing or too short');

  const reg = values.registrationNo ?? '';
  const email = values.email ?? '';
  if (!reg && !email) problems.push('needs a registration number or an email');
  if (reg && !isValidRegistrationNumber(reg)) {
    problems.push(`"${reg}" is not a usable registration number`);
  }

  const authEmail = toAuthEmail(email || reg);
  if (seen.has(authEmail)) problems.push('duplicate of an earlier row');
  seen.add(authEmail);

  if (values.gender && !normaliseGender(values.gender)) {
    warnings.push(`gender "${values.gender}" not recognised — left blank`);
  }
  if (values.sem && parseSem(values.sem) == null) {
    warnings.push(`semester "${values.sem}" unreadable — left blank`);
  }
  if (values.trade &&
      !TRADES.some((t) => t.toLowerCase() === values.trade.trim().toLowerCase())) {
    warnings.push(`trade "${values.trade}" is not a known code — saved as typed`);
  }

  const role = findRole(values.role) ?? fallbackRole;
  if (values.role && !findRole(values.role)) {
    warnings.push(`no role "${values.role}" — using ${role.name}`);
  }

  const existing = byEmail.get(authEmail);
  if (existing?.isSuperAdmin) problems.push('that login is the Super Admin — skipped');

  plan.push({
    line: i + 2,
    values,
    authEmail,
    role,
    existing,
    problems,
    warnings,
    action: problems.length ? 'skip' : (existing ? 'update' : 'create'),
  });
});

const creates = plan.filter((r) => r.action === 'create');
const updates = plan.filter((r) => r.action === 'update');
const skips = plan.filter((r) => r.action === 'skip');

for (const r of plan) {
  const tag = r.action === 'create' ? 'NEW   '
            : r.action === 'update' ? 'UPDATE' : 'SKIP  ';
  const room = r.values.hostel && r.values.room
    ? `  -> ${r.values.hostel} room ${r.values.room}` : '';
  console.log(`${tag} line ${String(r.line).padStart(3)}  ${(r.values.name ?? '?').padEnd(28)} ${r.authEmail}${room}`);
  r.problems.forEach((p) => console.log(`         ! ${p}`));
  r.warnings.forEach((w) => console.log(`         ~ ${w}`));
}

console.log(`\ncreate ${creates.length} · update ${updates.length} · skip ${skips.length}`);

if (!commit) {
  console.log('\nDry run — nothing was written. Re-run with --commit to apply.\n');
  process.exit(0);
}
if (!creates.length && !updates.length) {
  console.log('\nNothing to do.\n');
  process.exit(0);
}

// --- write ---------------------------------------------------------------

console.log(`\nWriting (${CONCURRENCY} at a time)…`);

const failures = [];
const imported = [];      // {uid, values, line}
let madeAccounts = 0;
let updatedProfiles = 0;

/** One row, start to finish. Never throws — a bad row records itself as a
 * failure and lets the rest of its batch keep going, same as the old
 * sequential loop did row by row. */
async function importOne(row) {
  try {
    let uid;
    if (row.action === 'create') {
      try {
        const rec = await withThrottleRetry(() => auth.createUser({
          email: row.authEmail,
          password: derivedPassword(row.values.registrationNo || row.authEmail),
          displayName: (row.values.name ?? '').trim(),
        }));
        uid = rec.uid;
      } catch (e) {
        // The Firestore profile was missing but the Auth account already
        // existed — adopt it rather than failing the row.
        if (e.code === 'auth/email-already-exists') {
          const rec = await auth.getUserByEmail(row.authEmail);
          uid = rec.uid;
        } else throw e;
      }
    } else {
      uid = row.existing.uid;
    }

    const profile = profileFor(row.values, {
      uid,
      collegeId: college.id,
      roleId: row.role.id,
      roleName: row.role.name,
    });

    // merge:true so a re-run never wipes room fields written by allotment.
    await db.collection('users').doc(uid).set(
      { ...profile, createdAt: FieldValue.serverTimestamp() },
      { merge: true },
    );

    imported.push({
      uid,
      values: row.values,
      line: row.line,
      existing: row.existing,
    });
    if (row.action === 'create') madeAccounts++;
    else updatedProfiles++;
    process.stdout.write('.');
  } catch (e) {
    failures.push(`line ${row.line} (${row.authEmail}): ${e.message}`);
    process.stdout.write('x');
  }
}

// Waves of CONCURRENCY, not a sliding pool: the whole batch finishes before
// the next one starts, which is what keeps Auth from seeing a steady flood.
for (const group of chunk([...creates, ...updates], CONCURRENCY)) {
  await Promise.all(group.map(importOne));
}
console.log('');

// --- room allotment ------------------------------------------------------
//
// Done after the accounts exist, and in one pass per hostel. This is a
// single-threaded script with nothing else writing, so reading each hostel's
// rooms once and assigning in memory is both correct and far cheaper than the
// per-student transaction the app has to use.

const wantRooms = imported.filter((r) => r.values.hostel && r.values.room);
// Hostel named but no room number — record membership without a bed rather
// than silently dropping the hostel value, which is what most rows in a
// typical sheet look like before rooms are finalised.
const wantHostelOnly = imported.filter((r) => r.values.hostel && !r.values.room);
const allotIssues = [];
let allotted = 0;
let hostelOnly = 0;

if (wantRooms.length || wantHostelOnly.length) {
  const hostelSnap = await db.collection('colleges').doc(college.id)
    .collection('hostels').get();
  const hostels = hostelSnap.docs.map((d) => ({ id: d.id, ...d.data() }));

  const roomsByHostel = new Map();
  const writes = [];
  const bedDelta = new Map();

  if (wantRooms.length) {
    console.log('\nAllotting rooms…');

    for (const r of wantRooms) {
      const wanted = r.values.hostel.toLowerCase();
      const hostel = hostels.find(
        (h) => (h.name ?? '').toLowerCase() === wanted ||
               (h.code ?? '').toLowerCase() === wanted
      );
      if (!hostel) {
        allotIssues.push(`line ${r.line}: no hostel called "${r.values.hostel}"`);
        continue;
      }

      // Already living somewhere ELSE. Adding them to the new room without
      // vacating the old one would leave them listed in two rooms at once and
      // permanently inflate both hostels' occupiedBeds. Moving a student is a
      // deliberate act — refuse it here and say so.
      const prev = r.existing;
      if (prev?.roomId &&
          !(prev.hostelId === hostel.id && String(prev.roomId) === String(r.values.room))) {
        allotIssues.push(
          `line ${r.line}: ${prev.name ?? 'that student'} is already in ` +
          `${prev.hostelName} room ${prev.roomNumber} — move them in the app ` +
          `instead of re-importing`
        );
        continue;
      }

      if (!roomsByHostel.has(hostel.id)) {
        const rs = await db.collection('colleges').doc(college.id)
          .collection('hostels').doc(hostel.id).collection('rooms').get();
        roomsByHostel.set(hostel.id, new Map(rs.docs.map((d) => [d.id, { id: d.id, ...d.data() }])));
      }
      const rooms = roomsByHostel.get(hostel.id);
      const room = rooms.get(String(r.values.room));

      if (!room) {
        allotIssues.push(`line ${r.line}: ${hostel.name} has no room ${r.values.room}`);
        continue;
      }
      const occupants = room.occupantUids ?? [];
      if (occupants.includes(r.uid)) continue;           // already there
      if (occupants.length >= (room.capacity ?? 1)) {
        allotIssues.push(`line ${r.line}: ${hostel.name} room ${room.id} is full`);
        continue;
      }

      room.occupantUids = [...occupants, r.uid];
      bedDelta.set(hostel.id, (bedDelta.get(hostel.id) ?? 0) + 1);
      allotted++;

      writes.push({
        ref: db.collection('colleges').doc(college.id)
          .collection('hostels').doc(hostel.id).collection('rooms').doc(room.id),
        data: { occupantUids: room.occupantUids },
      });
      writes.push({
        ref: db.collection('users').doc(r.uid),
        data: {
          hostelId: hostel.id,
          hostelName: hostel.name,
          roomId: room.id,
          roomNumber: room.number ?? room.id,
          allottedAt: FieldValue.serverTimestamp(),
        },
      });
    }
  }

  // Hostel named but no room number — record membership without a bed
  // rather than silently dropping the hostel value, which is what most rows
  // in a typical sheet look like before rooms are finalised. A student who
  // already holds an actual room is left alone: this path never downgrades
  // a real allotment.
  if (wantHostelOnly.length) {
    console.log('\nAssigning hostels (no room)…');

    for (const r of wantHostelOnly) {
      const wanted = r.values.hostel.toLowerCase();
      const hostel = hostels.find(
        (h) => (h.name ?? '').toLowerCase() === wanted ||
               (h.code ?? '').toLowerCase() === wanted
      );
      if (!hostel) {
        allotIssues.push(`line ${r.line}: no hostel called "${r.values.hostel}"`);
        continue;
      }

      const prev = r.existing;
      if (prev?.roomId) continue;                  // has an actual room — leave it
      if (prev?.hostelId === hostel.id) continue;   // already set from a prior run

      hostelOnly++;
      writes.push({
        ref: db.collection('users').doc(r.uid),
        data: { hostelId: hostel.id, hostelName: hostel.name },
      });
    }
  }

  for (const [hostelId, delta] of bedDelta) {
    writes.push({
      ref: db.collection('colleges').doc(college.id)
        .collection('hostels').doc(hostelId),
      data: { occupiedBeds: FieldValue.increment(delta) },
    });
  }

  for (const group of chunk(writes, 400)) {
    const batch = db.batch();
    group.forEach((w) => batch.set(w.ref, w.data, { merge: true }));
    await batch.commit();
  }
}

// --- summary -------------------------------------------------------------

console.log('\n─────────────────────────────');
console.log(`created  ${madeAccounts}`);
console.log(`updated  ${updatedProfiles}`);
console.log(`allotted ${allotted}`);
console.log(`hostel only (no room) ${hostelOnly}`);
console.log(`failed   ${failures.length}`);

if (allotIssues.length) {
  console.log('\nAccounts were created, but these rooms could not be allotted:');
  allotIssues.forEach((f) => console.log(`  ${f}`));
}
if (failures.length) {
  console.log('\nFailed rows — fix and re-run (re-running is safe):');
  failures.forEach((f) => console.log(`  ${f}`));
}

console.log(
  '\nStudents sign in with their registration number as BOTH username and ' +
  'password.\nTell them to change it from My Profile after first login.\n'
);

process.exit(failures.length ? 1 : 0);
