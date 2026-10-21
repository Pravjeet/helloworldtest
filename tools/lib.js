/**
 * Shared helpers for the admin scripts.
 *
 * Everything in here deliberately mirrors the Dart implementation:
 *   - CSV parsing            → lib/services/csv_import.dart  (parseDelimited)
 *   - header aliases         → lib/services/csv_import.dart  (_normaliseHeader)
 *   - synthetic login emails → lib/core/identity.dart        (Identity)
 *   - sem / batch derivation → lib/services/csv_import.dart, lib/models/app_user.dart
 *
 * If you change a rule on one side, change it on the other. A student imported
 * by this script and a student imported in-app must end up byte-identical,
 * otherwise the dashboard buckets them separately and nobody can work out why.
 */

import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { initializeApp, cert } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';

const HERE = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------
// Identity  (mirrors lib/core/identity.dart)
// ---------------------------------------------------------------------

export const SYNTHETIC_DOMAIN = 'homihostel.local';

export const looksLikeEmail = (s) => s.includes('@');

export function toAuthEmail(input) {
  const v = (input ?? '').trim().toLowerCase();
  if (!v) return v;
  return looksLikeEmail(v) ? v : `${v}@${SYNTHETIC_DOMAIN}`;
}

/** Firebase requires 6 characters, so short registration numbers get padded. */
export function derivedPassword(registrationNo) {
  const v = (registrationNo ?? '').trim();
  return v.length >= 6 ? v : v.padEnd(6, '0');
}

export const isValidRegistrationNumber = (v) =>
  /^[A-Za-z0-9._-]{3,}$/.test((v ?? '').trim());

// ---------------------------------------------------------------------
// Derived fields
// ---------------------------------------------------------------------

/** "Sem 5" / "5th" / "V" / "5"  ->  5 */
export function parseSem(raw) {
  if (raw == null) return null;
  const digits = String(raw).match(/\d+/);
  if (digits) {
    const n = parseInt(digits[0], 10);
    return n >= 1 && n <= 12 ? n : null;
  }
  const roman = { i: 1, ii: 2, iii: 3, iv: 4, v: 5, vi: 6, vii: 7, viii: 8 };
  const key = String(raw).toLowerCase().replace(/[^ivx]/g, '');
  return roman[key] ?? null;
}

/** "2110910" -> "2021-22" (the two-digit admission year leads the number). */
export function batchFromRegistrationNo(regNo) {
  const v = (regNo ?? '').trim();
  if (v.length < 2) return null;
  const yy = parseInt(v.slice(0, 2), 10);
  if (Number.isNaN(yy)) return null;
  const start = 2000 + yy;
  if (start < 2000 || start > new Date().getFullYear() + 1) return null;
  return `${start}-${String((start + 1) % 100).padStart(2, '0')}`;
}

export function normaliseGender(raw) {
  const v = (raw ?? '').trim().toLowerCase();
  if (v === 'm' || v === 'male') return 'Male';
  if (v === 'f' || v === 'female') return 'Female';
  if (v === 'o' || v === 'other') return 'Other';
  return null;
}

/** Mirrors kIndianStates in lib/models/app_user.dart. */
export const STATES = [
  'Andhra Pradesh', 'Arunachal Pradesh', 'Assam', 'Bihar', 'Chhattisgarh',
  'Delhi', 'Goa', 'Gujarat', 'Haryana', 'Himachal Pradesh',
  'Jammu and Kashmir', 'Jharkhand', 'Karnataka', 'Kerala', 'Ladakh',
  'Madhya Pradesh', 'Maharashtra', 'Manipur', 'Meghalaya', 'Mizoram',
  'Nagaland', 'Odisha', 'Puducherry', 'Punjab', 'Rajasthan', 'Sikkim',
  'Tamil Nadu', 'Telangana', 'Tripura', 'Uttar Pradesh', 'Uttarakhand',
  'West Bengal', 'Andaman and Nicobar Islands', 'Chandigarh',
  'Dadra and Nagar Haveli and Daman and Diu', 'Lakshadweep',
];

const STATE_ALIASES = {
  up: 'Uttar Pradesh', uttarpradesh: 'Uttar Pradesh',
  mp: 'Madhya Pradesh', madhyapradesh: 'Madhya Pradesh',
  hp: 'Himachal Pradesh', himachal: 'Himachal Pradesh',
  ap: 'Andhra Pradesh', tn: 'Tamil Nadu', tamilnadu: 'Tamil Nadu',
  wb: 'West Bengal', westbengal: 'West Bengal',
  jk: 'Jammu and Kashmir', jandk: 'Jammu and Kashmir',
  jammukashmir: 'Jammu and Kashmir',
  uk: 'Uttarakhand', ua: 'Uttarakhand', uttaranchal: 'Uttarakhand',
  orissa: 'Odisha', pondicherry: 'Puducherry',
  newdelhi: 'Delhi', nct: 'Delhi', chattisgarh: 'Chhattisgarh',
  pb: 'Punjab', hr: 'Haryana', br: 'Bihar', jh: 'Jharkhand',
  rj: 'Rajasthan', mh: 'Maharashtra', ka: 'Karnataka', kl: 'Kerala',
  gj: 'Gujarat', ts: 'Telangana', ch: 'Chandigarh',
};

const stateKey = (s) => s.toLowerCase().replace(/[^a-z]/g, '');

/** Canonicalises a typed state name, or null if it is not one. */
export function normaliseState(raw) {
  const v = (raw ?? '').trim();
  if (!v) return null;
  const key = stateKey(v);
  if (!key) return null;
  const exact = STATES.find((s) => stateKey(s) === key);
  return exact ?? STATE_ALIASES[key] ?? null;
}

/**
 * Pulls the state out of a free-text address ("Ludhiana, Punjab").
 * Scans segments from the end, since "Village, District, Punjab" is as common
 * as "City, State". Returns null rather than guessing.
 */
export function stateFromAddress(address) {
  const v = (address ?? '').trim();
  if (!v) return null;
  const parts = v.split(',').map((p) => p.trim()).filter(Boolean).reverse();
  for (const p of parts) {
    const hit = normaliseState(p);
    if (hit) return hit;
  }
  return null;
}

/**
 * Mirrors kTrades in lib/models/app_user.dart — the *defaults* only.
 *
 * A college edits its own list under System Settings, stored on the settings
 * document. These scripts don't read that, so a workspace that has added its
 * own trades will see them flagged as unknown here even though the app knows
 * about them. That's a warning, never a rejection.
 */
export const TRADES = [
  // Diploma (ICD) — several run specialisations under a base code
  'DCE', 'DCE-CBM',
  'DME', 'DME-CAC', 'DME-CAF', 'DME-CFF', 'DME-CTD', 'DME-CWG',
  'DEE', 'DEE-CEN',
  'DIN', 'DIN-CIM', 'DIN-CSMM',
  'DEC', 'DEC-CSME', 'DEC-CTC', 'DEC-CTV',
  'DCS', 'DCS-CDE',
  'DCT', 'DCT-CPT',
  'DFT', 'DFT-CFP',
  // B.E.
  'GCS', 'GME', 'GCT', 'GEE', 'GEC', 'GFT', 'GIN', 'GCE', 'GAI',
  // M.Tech
  'PGCE', 'PGCSE', 'PGICE', 'PGECE', 'PGFET', 'PGMSE', 'PGWLF', 'PGVLSI',
  // M.Sc
  'PGPHY', 'PGCHY', 'PGMATH',
  // MBA
  'MBA',
];

// ---------------------------------------------------------------------
// CSV  (mirrors parseDelimited / _normaliseHeader)
// ---------------------------------------------------------------------

export const IMPORT_COLUMNS = [
  'name', 'registrationNo', 'email', 'role', 'gender', 'phone',
  'course', 'year', 'trade', 'batch', 'sem', 'state',
  'hostel', 'room', 'dateOfBirth', 'bloodGroup', 'address',
  'guardianName', 'guardianRelation', 'guardianPhone', 'notes',
  'category', 'religion', 'admissionYear', 'motherName', 'permanentMobile',
  'section', 'city', 'pinCode',
];

const HEADER_ALIASES = {
  fullname: 'name', studentname: 'name',
  emailaddress: 'email', emailid: 'email',
  rollno: 'registrationNo', rollnumber: 'registrationNo',
  enrollment: 'registrationNo', enrollmentno: 'registrationNo',
  enrolmentno: 'registrationNo', registrationno: 'registrationNo',
  registrationnumber: 'registrationNo',
  studentregistrationnumber: 'registrationNo',
  mobile: 'phone', phoneno: 'phone', contact: 'phone', contactno: 'phone',
  studentscontactnumber: 'phone',
  branch: 'trade', programme: 'course', semester: 'sem',
  homestate: 'state', domicile: 'state',
  hostelnumber: 'hostel', hostelname: 'hostel', block: 'hostel',
  roomno: 'room', roomnumber: 'room', hostelroomno: 'room',
  dob: 'dateOfBirth', dateofbirth: 'dateOfBirth',
  blood: 'bloodGroup', bloodgroup: 'bloodGroup',
  fathername: 'guardianName', guardian: 'guardianName',
  guardianname: 'guardianName',
  relation: 'guardianRelation', guardianrelation: 'guardianRelation',
  guardianphone: 'guardianPhone', guardiancontact: 'guardianPhone',
  permanentaddress: 'address', remarks: 'notes',
};

function normaliseHeader(raw) {
  const key = raw.trim().toLowerCase().replace(/[\s_\-.]/g, '');
  if (HEADER_ALIASES[key]) return HEADER_ALIASES[key];
  const exact = IMPORT_COLUMNS.find((c) => c.toLowerCase() === key);
  return exact ?? raw.trim();
}

/**
 * Handles comma files, tab-separated Excel paste, and quoted fields that
 * contain commas or newlines — which any address column produces.
 */
export function parseDelimited(rawText) {
  let text = rawText.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  if (text.startsWith('﻿')) text = text.slice(1);

  const delimiter = text.split('\n')[0].includes('\t') ? '\t' : ',';

  const records = [];
  let cell = '';
  let record = [];
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') { cell += '"'; i++; }
        else inQuotes = false;
      } else cell += ch;
      continue;
    }
    if (ch === '"') inQuotes = true;
    else if (ch === delimiter) { record.push(cell); cell = ''; }
    else if (ch === '\n') { record.push(cell); cell = ''; records.push(record); record = []; }
    else cell += ch;
  }
  if (cell !== '' || record.length) { record.push(cell); records.push(record); }

  const rows = records.filter((r) => r.some((c) => c.trim() !== ''));
  if (!rows.length) return { headers: [], rows: [] };

  return {
    headers: rows[0].map(normaliseHeader),
    rows: rows.slice(1),
  };
}

/** Turns a raw row array into a {column: value} object, dropping blanks. */
export function rowToValues(headers, raw) {
  const out = {};
  for (let c = 0; c < headers.length && c < raw.length; c++) {
    const v = raw[c].trim();
    if (v !== '') out[headers[c]] = v;
  }
  return out;
}

/**
 * The Firestore profile for one CSV row — the exact field set
 * AppUser.toMap() writes, so a script-created student is indistinguishable
 * from an app-created one.
 */
export function profileFor(values, { uid, collegeId, roleId, roleName }) {
  const reg = values.registrationNo ?? '';
  const sem = parseSem(values.sem);
  const batch = values.batch ?? batchFromRegistrationNo(reg);
  const trade = values.trade
    ? (TRADES.find((t) => t.toLowerCase() === values.trade.trim().toLowerCase())
       ?? values.trade.trim())
    : null;

  return {
    uid,
    name: (values.name ?? '').trim(),
    email: toAuthEmail(values.email || reg),
    collegeId,
    roleId,
    roleName,
    isSuperAdmin: false,
    isActive: true,
    phone: values.phone ?? null,
    gender: normaliseGender(values.gender),
    enrollmentNo: reg || null,
    course: values.course ?? null,
    year: values.year ?? null,
    trade,
    batch: batch ?? null,
    sem: sem ?? null,
    state: normaliseState(values.state) ?? stateFromAddress(values.address),
    dateOfBirth: values.dateOfBirth ?? null,
    bloodGroup: values.bloodGroup ?? null,
    address: values.address ?? null,
    guardianName: values.guardianName ?? null,
    guardianPhone: values.guardianPhone ?? null,
    guardianRelation: values.guardianRelation ?? null,
    notes: values.notes ?? null,
    category: values.category ?? null,
    religion: values.religion ?? null,
    admissionYear: values.admissionYear ?? null,
    motherName: values.motherName ?? null,
    permanentMobile: values.permanentMobile ?? null,
    section: values.section ?? null,
    city: values.city ?? null,
    pinCode: values.pinCode ?? null,
  };
}

// ---------------------------------------------------------------------
// Firebase
// ---------------------------------------------------------------------

const KEY_CANDIDATES = [
  'serviceAccountKey.json',
  '../serviceAccountKey.json',
];

export function initAdmin() {
  const found = KEY_CANDIDATES
    .map((p) => resolve(HERE, p))
    .find((p) => existsSync(p));

  if (!found) {
    console.error(
      '\nNo serviceAccountKey.json found.\n\n' +
      'Get one from the Firebase console:\n' +
      '  Project Settings  ->  Service Accounts  ->  Generate new private key\n\n' +
      `Save it as:  ${resolve(HERE, 'serviceAccountKey.json')}\n\n` +
      'It is already covered by .gitignore. Never commit or share it.\n'
    );
    process.exit(1);
  }

  const key = JSON.parse(readFileSync(found, 'utf8'));
  assertKeyMatchesApp(key.project_id, found);
  initializeApp({ credential: cert(key) });
  return { auth: getAuth(), db: getFirestore(), projectId: key.project_id };
}

/**
 * Refuses to run when the service-account key points at a different Firebase
 * project than the app itself does.
 *
 * This is not hypothetical. A key for the wrong project authenticates fine,
 * resolves a college fine, and reports "Deleted 1029 profiles" fine — against
 * a database nobody is looking at. Meanwhile the app goes on showing every
 * record you thought you had just deleted, which reads exactly like a caching
 * bug and gets debugged as one for hours.
 *
 * The app's project id is read from `.firebaserc`, which is the file
 * `firebase deploy` uses, so if this check passes the script is talking to
 * whatever the deployed app talks to. Missing or unreadable `.firebaserc` is
 * not fatal — plenty of checkouts do not have one — but a *mismatch* is.
 */
function assertKeyMatchesApp(keyProjectId, keyPath) {
  const rcPath = resolve(HERE, '..', '.firebaserc');
  if (!existsSync(rcPath)) return;

  let appProjectId;
  try {
    appProjectId = JSON.parse(readFileSync(rcPath, 'utf8'))?.projects?.default;
  } catch {
    return; // Malformed .firebaserc is the app's problem, not ours to enforce.
  }
  if (!appProjectId || appProjectId === keyProjectId) return;

  console.error(
    '\nWRONG PROJECT — refusing to run.\n\n' +
    `  The app  (.firebaserc)      -> ${appProjectId}\n` +
    `  This key (serviceAccountKey) -> ${keyProjectId}\n\n` +
    'Anything this script did would land in a database the app never reads,\n' +
    'so the app would keep showing the data you were trying to change.\n\n' +
    `Generate a key for ${appProjectId}:\n` +
    '  Firebase console -> pick that project -> Project Settings ->\n' +
    '  Service Accounts -> Generate new private key\n\n' +
    `Then replace:  ${keyPath}\n\n` +
    `If ${keyProjectId} really is the one you want, point .firebaserc at it.\n`
  );
  process.exit(1);
}

/**
 * Works out which college to write into. With exactly one college in the
 * project there is nothing to ask; with several you must say which, because
 * guessing would silently import 200 students into the wrong institution.
 */
export async function resolveCollege(db, requested) {
  const snap = await db.collection('colleges').get();
  const colleges = snap.docs.map((d) => ({ id: d.id, name: d.data().name }));

  if (!colleges.length) {
    console.error('This project has no colleges yet. Register one in the app first.');
    process.exit(1);
  }
  if (requested) {
    const hit = colleges.find((c) => c.id === requested);
    if (!hit) {
      console.error(`No college with id "${requested}". Found:`);
      colleges.forEach((c) => console.error(`  ${c.id}  (${c.name})`));
      process.exit(1);
    }
    return hit;
  }
  if (colleges.length === 1) return colleges[0];

  console.error('Several colleges exist — pass --college <id>:');
  colleges.forEach((c) => console.error(`  ${c.id}  (${c.name})`));
  process.exit(1);
}

/** Minimal flag parser: --key value, --flag. */
export function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next && !next.startsWith('--')) { out[key] = next; i++; }
      else out[key] = true;
    } else out._.push(a);
  }
  return out;
}

export const chunk = (arr, n) => {
  const out = [];
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
  return out;
};

/**
 * Same backoff the in-app importer uses (see kThrottleBackoff in
 * lib/services/csv_import.dart) — mirrored here so a script run at high
 * concurrency degrades the same way the browser path does instead of just
 * failing rows outright.
 */
export const THROTTLE_BACKOFF_MS = [3000, 8000, 20000];

export function isThrottle(e) {
  const code = e?.code ?? '';
  if (code === 'auth/too-many-requests' || code === 'auth/quota-exceeded') {
    return true;
  }
  const msg = String(e?.message ?? e).toLowerCase();
  return msg.includes('too-many-requests') ||
    msg.includes('too many requests') ||
    msg.includes('quota');
}

/** Retries `fn` on a Firebase throttle response, backing off between tries. */
export async function withThrottleRetry(fn) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (attempt >= THROTTLE_BACKOFF_MS.length || !isThrottle(e)) throw e;
      await new Promise((r) => setTimeout(r, THROTTLE_BACKOFF_MS[attempt]));
    }
  }
}
