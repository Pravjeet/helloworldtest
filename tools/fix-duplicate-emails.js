#!/usr/bin/env node
/**
 * Gives every row in a student sheet a unique login identity.
 *
 *   node fix-duplicate-emails.js ../../finalsheet.csv
 *   node fix-duplicate-emails.js ../../finalsheet.csv --out clean.csv --force
 *
 * Siblings often share one parent's email address. The importer derives a
 * student's login from `email || registrationNo` and matches existing
 * students by exactly that key, so two rows sharing an address are not two
 * students — the second is read as an *update* of the first and silently
 * overwrites them. The row count looks right and nobody finds out.
 *
 * This rewrites the later rows of each colliding group to
 * `{registrationNo}@homihostel.local` — the same synthetic form the importer
 * already falls back to for a blank email — and records what happened in a
 * `notes` column, which round-trips into Firestore and shows on the student's
 * detail view. The original address is kept there in prose, so no contact
 * detail is lost.
 *
 * Writes a new file and never touches the input, so the substitutions can be
 * reviewed before anything reaches Firebase.
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  parseArgs, parseDelimited, rowToValues, toAuthEmail, SYNTHETIC_DOMAIN,
} from './lib.js';

const args = parseArgs(process.argv.slice(2));
const input = args._[0];

if (!input) {
  console.error(
    'Usage:\n' +
    '  node fix-duplicate-emails.js <file.csv> [--out <file.csv>] [--force]\n\n' +
    'Writes <file>.fixed.csv by default. The input is never modified.'
  );
  process.exit(1);
}

const inPath = resolve(process.cwd(), input);
if (!existsSync(inPath)) {
  console.error(`No such file: ${inPath}`);
  process.exit(1);
}

const outPath = resolve(
  process.cwd(),
  typeof args.out === 'string' ? args.out : input.replace(/(\.[^.]+)?$/, '.fixed.csv')
);
if (outPath === inPath) {
  console.error('Refusing to write over the input file. Pass a different --out.');
  process.exit(1);
}
if (existsSync(outPath) && args.force !== true) {
  console.error(`${outPath} already exists. Pass --force to overwrite.`);
  process.exit(1);
}

// --- read ----------------------------------------------------------------

const table = parseDelimited(readFileSync(inPath, 'utf8'));
if (!table.rows.length) {
  console.error('That file has no data rows.');
  process.exit(1);
}

const headers = [...table.headers];
const emailAt = headers.indexOf('email');
const regAt = headers.indexOf('registrationNo');

if (regAt === -1) {
  console.error('That file has no registrationNo column — nothing to build unique logins from.');
  process.exit(1);
}

// Ragged rows are normal in exported sheets; pad so a cell write can't land
// off the end of a short row.
const rows = table.rows.map((r) => {
  const copy = [...r];
  while (copy.length < headers.length) copy.push('');
  return copy;
});

// Both columns are written below, so both must exist before grouping.
const emailCol = emailAt === -1 ? headers.push('email') - 1 : emailAt;
const notesCol = headers.indexOf('notes') === -1
  ? headers.push('notes') - 1
  : headers.indexOf('notes');
rows.forEach((r) => { while (r.length < headers.length) r.push(''); });

// --- group by the identity the importer will actually use ----------------

const groups = new Map();

rows.forEach((raw, i) => {
  const v = rowToValues(headers, raw);
  const key = toAuthEmail(v.email || v.registrationNo || '');
  if (!key) return;
  if (!groups.has(key)) groups.set(key, []);
  groups.get(key).push({ index: i, line: i + 2, reg: (v.registrationNo ?? '').trim() });
});

const collisions = [...groups.entries()].filter(([, members]) => members.length > 1);

if (!collisions.length) {
  console.log('\nEvery row already has a unique login. Nothing to fix.\n');
  process.exit(0);
}

// --- rewrite the later members of each group -----------------------------

const changed = [];
const problems = [];

for (const [original, members] of collisions) {
  for (const m of members.slice(1)) {
    if (!m.reg) {
      problems.push(`line ${m.line}: shares ${original} but has no registration number`);
      continue;
    }
    const replacement = `${m.reg.toLowerCase()}@${SYNTHETIC_DOMAIN}`;
    const others = members.filter((o) => o !== m).map((o) => o.reg || `line ${o.line}`);

    rows[m.index][emailCol] = replacement;
    rows[m.index][notesCol] = [
      rows[m.index][notesCol],
      `Login email auto-assigned. Shared ${original} with ${others.join(', ')}. ` +
      `Contact: ${original}`,
    ].filter(Boolean).join(' | ');

    changed.push({ line: m.line, reg: m.reg, original, replacement });
  }
}

// A replacement can only clash if two rows carry the same registration
// number, which would break the import anyway — worth catching here rather
// than halfway through writing accounts.
const finalKeys = new Map();
rows.forEach((raw, i) => {
  const v = rowToValues(headers, raw);
  const key = toAuthEmail(v.email || v.registrationNo || '');
  if (!key) return;
  if (!finalKeys.has(key)) finalKeys.set(key, []);
  finalKeys.get(key).push(i + 2);
});
const stillDuplicated = [...finalKeys.entries()].filter(([, l]) => l.length > 1);

// --- write ---------------------------------------------------------------

const quote = (cell) => {
  const s = String(cell ?? '');
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

if (!stillDuplicated.length) {
  const csv = [headers, ...rows].map((r) => r.map(quote).join(',')).join('\n') + '\n';
  writeFileSync(outPath, csv, 'utf8');
}

// --- report --------------------------------------------------------------

console.log(`\nRead    : ${inPath}`);
console.log(`Rows    : ${rows.length}`);
console.log(`Groups  : ${collisions.length} shared address(es)`);
console.log(`Rewrote : ${changed.length} row(s)\n`);

changed.forEach((c) => {
  console.log(`  line ${String(c.line).padStart(5)}  ${c.reg.padEnd(12)} ${c.original}  ->  ${c.replacement}`);
});

if (problems.length) {
  console.log('\nCould not fix:');
  problems.forEach((p) => console.log(`  ! ${p}`));
}

if (stillDuplicated.length) {
  console.log('\nStill duplicated after the rewrite — nothing was written:');
  stillDuplicated.slice(0, 20).forEach(([k, l]) => console.log(`  ${k}  lines ${l.join(', ')}`));
  console.log('\nThese are almost certainly duplicate registration numbers. Fix them in the source sheet.\n');
  process.exit(1);
}

console.log(`\nUnique logins: ${finalKeys.size} of ${rows.length}`);
console.log(`Wrote   : ${outPath}\n`);

process.exit(problems.length ? 1 : 0);
