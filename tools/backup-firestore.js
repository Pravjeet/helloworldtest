// Local Firestore backup.
//
// The managed `gcloud firestore export` path needs a Blaze (billing-enabled)
// project — this one is on Spark, same reason Firebase Storage isn't
// available (see DEVELOPMENT.md). This is the Spark-compatible alternative: walk
// every collection and subcollection with the Admin SDK (same credentials
// the other tools/ scripts use) and write it all to one local JSON file.
//
// Not a point-in-time snapshot the way a managed export is — reads happen
// one collection at a time, so a write mid-backup could land in an
// inconsistent spot. Good enough for "undo a bad deploy or a bad import,"
// not a substitute for a real export once this project ever moves to Blaze.
//
// Run:  node backup-firestore.js
// Restore is manual: the output is plain JSON, read it and re-write with a
// script the same shape as import-students.js if you ever need to.

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Timestamp } from 'firebase-admin/firestore';

import { initAdmin } from './lib.js';

const HERE = dirname(fileURLToPath(import.meta.url));

function serialise(value) {
  if (value instanceof Timestamp) return { __timestamp__: value.toDate().toISOString() };
  if (Array.isArray(value)) return value.map(serialise);
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = serialise(v);
    return out;
  }
  return value;
}

/** Recursively dumps a collection: every doc, plus every doc's subcollections. */
async function dumpCollection(colRef) {
  const snap = await colRef.get();
  const docs = {};
  for (const doc of snap.docs) {
    const subcols = await doc.ref.listCollections();
    const subcolData = {};
    for (const sub of subcols) {
      subcolData[sub.id] = await dumpCollection(sub);
    }
    docs[doc.id] = {
      data: serialise(doc.data()),
      ...(Object.keys(subcolData).length ? { subcollections: subcolData } : {}),
    };
  }
  return docs;
}

async function main() {
  const { db, projectId } = initAdmin();

  console.log(`Backing up ${projectId} ...`);
  const rootCollections = await db.listCollections();
  const out = { projectId, exportedAt: new Date().toISOString(), collections: {} };

  for (const col of rootCollections) {
    console.log(`  ${col.id} ...`);
    out.collections[col.id] = await dumpCollection(col);
  }

  const dir = `${HERE}/backups`;
  mkdirSync(dir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const path = `${dir}/${stamp}.json`;
  writeFileSync(path, JSON.stringify(out, null, 2));

  const docCount = Object.values(out.collections)
    .reduce((n, c) => n + countDocs(c), 0);
  console.log(`\nWrote ${path}`);
  console.log(`${Object.keys(out.collections).length} root collections, ${docCount} documents total.`);
  console.log('\nKeep this file somewhere other than this machine alone (it has every');
  console.log('student\'s data in it) — it is git-ignored on purpose, this is not a commit target.');
}

function countDocs(collectionDump) {
  let n = 0;
  for (const doc of Object.values(collectionDump)) {
    n += 1;
    if (doc.subcollections) {
      for (const sub of Object.values(doc.subcollections)) n += countDocs(sub);
    }
  }
  return n;
}

main().catch((err) => {
  console.error('Backup failed:', err.message ?? err);
  process.exitCode = 1;
});
