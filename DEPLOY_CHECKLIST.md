# Deploy checklist

Homi Hostel runs on one live Firebase project (`homihostel-57391`, see
`firebase.json`) — there is no separate staging project. That makes every
deploy a production deploy, so this checklist exists to make "did I actually
check before pushing that?" answerable instead of a vibe.

Run through this before any release, and always before a change that touches
`firestore.rules`, the data model, or bulk account creation.

## 1. Back up Firestore first

You cannot undo a bad rules deploy or a bad bulk-import run by hand once
students and wardens are actively using the app. Take a backup before
anything risky:

```bash
cd tools
npm run backup
```

This project is on Firebase's **Spark (free) plan** — no billing account
attached — so the managed `gcloud firestore export` path (which needs Blaze)
isn't available, same reason Firebase Storage isn't. `tools/backup-firestore.js`
is the Spark-compatible alternative: it walks every collection and
subcollection with the Admin SDK and writes the whole thing to one local
JSON file under `tools/backups/` (git-ignored — it contains every student's
personal data, never commit it).

It is **not** a true point-in-time snapshot the way a managed export is —
reads happen one collection at a time, so a write mid-backup could land in
an inconsistent spot. Good enough to undo a bad deploy or bad import; not a
substitute for a real export if this project ever moves to Blaze.

Restore is manual — the output is plain JSON, replay it with a script the
same shape as `tools/import-students.js` if you ever actually need to.

## 2. Run the test suite

```bash
flutter test
flutter analyze
```

Both must be clean. `flutter analyze` is the minimum bar per `DEVELOPMENT.md` —
don't ship on a red analyzer.

## 3. Rules changes: deploy, then verify

Per `DEVELOPMENT.md`: a change to `firestore.rules` is not real until deployed —
the file on disk has no effect on its own.

```bash
./deploy-rules.bat
./check-rules.bat
```

`check-rules.bat` must say **UP TO DATE**. If you edited `firestore.rules`
and cannot run `deploy-rules.bat` yourself (no `firebase login`, sandboxed
shell), do not consider the change done — say so explicitly and hand the two
commands to whoever can run them.

## 4. Manual smoke test — as a real Warden and a real Student, not Super Admin

`hasPerm()` short-circuits on `isSuperAdmin()`, so testing only as Super Admin
never exercises the permission branches in `firestore.rules` — see
`ARCHITECTURE.md` §6. Before calling a rules change safe, sign in as:

- **A Warden or Chief Warden test account** — confirm they can do what their
  role grants and get a clean "You don't have permission to do that" (not a
  crash) for what it doesn't.
- **A Student test account** — confirm they can only see their own
  fines/fees/requests, not everyone else's, and cannot reach any staff-only
  page even by URL/state manipulation.

If you don't already have standing test accounts for these roles, create them
once in the real workspace and keep reusing them — see the "manual QA" script
alongside this checklist.

## 5. Bulk operations (CSV import, account deletion)

- Import a **small test batch first** (2-3 rows) after any change to
  `csv_import.dart` or the role templates, before running a real class-sized
  import. Firebase throttles account creation past roughly 40 rows in one
  run — know that going in, don't discover it mid-import on live data.
- `deleteUserProfile` only removes the Firestore doc, not the Auth account —
  confirm orphaned Auth accounts via `tools/delete-students.js --orphans`
  (dry-run first, `--commit` only once you've read its output).

## 6. After deploying

- Watch the Firebase console (Authentication + Firestore usage) for a few
  minutes after a rules or bulk-import deploy — a bad rule shows up
  immediately as a spike in permission-denied reads, not eventually.
- Note what changed and when, informally — there's no formal release log yet,
  but even a one-line note in the PR/commit description saves the next
  "wait, when did this change?" investigation.
