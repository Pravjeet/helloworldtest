# Admin tools

Two scripts you run from your own machine to bulk-create and bulk-delete
student accounts. **Not part of the app** — wardens never touch these.

## Why these exist

The in-app CSV importer runs in a browser, which Firebase treats as untrusted.
It can only create accounts the way a member of the public would: one at a
time, through the public sign-up door. Firebase throttles that after a dozen or
so, which is why a 30-row import crawls.

These scripts use a **service-account key**, which proves to Firebase that you
own the project. That unlocks the Admin SDK: no throttling, no
secondary-FirebaseApp workaround, and — importantly — the ability to **delete
Auth accounts**, which the app genuinely cannot do. `deleteUserProfile` in the
app removes the Firestore document and leaves the login orphaned forever.

Same Firebase project, same free Spark plan. Just a more privileged door.

## One-time setup

**1. Get your key** (about 30 seconds, in the browser)

- Open the [Firebase console](https://console.firebase.google.com/) →
  your project → the gear icon → **Project settings**
- **Service accounts** tab → **Generate new private key** → **Generate key**
- A `.json` file downloads

**2. Put it here**

Rename it to `serviceAccountKey.json` and drop it in this `tools/` folder.

> ⚠️ **This file is the master key to your entire Firebase project.** Anyone
> holding it can read, write or delete every account and every document, with
> no password. It is already covered by `.gitignore`, so git will not pick it
> up — but never email it, never paste it into a chat, never put it in a
> screenshot. If it ever does leak, revoke it immediately in the same
> Service accounts screen; deleting the file later is not enough, because a
> committed file stays in git history forever.

**3. Install the dependency** (once)

```bash
cd tools
npm install
```

## Importing students

Always preview first. Without `--commit` nothing is written:

```bash
node import-students.js ../students.csv
```

You'll get a line per row — `NEW` / `UPDATE` / `SKIP` — with the reason for
anything skipped. When it looks right:

```bash
node import-students.js ../students.csv --commit
```

**Re-running is safe.** A registration number that already exists is *updated*,
never duplicated. If a run dies halfway, just run it again.

Options:

| Flag | What it does |
|---|---|
| `--commit` | Actually write. Without it, dry run. |
| `--college <id>` | Which college. Only needed if you have more than one. |
| `--role <name>` | Role for rows with a blank `role` column. Default `Student`. |

### CSV columns

Same file the in-app importer takes. Only `name` plus either
`registrationNo` or `email` are required; everything else is optional.

```
name, registrationNo, email, role, gender, phone,
course, year, trade, batch, sem,
hostel, room, officeRoom, dateOfBirth, bloodGroup, address,
guardianName, guardianRelation, guardianPhone, notes,
category, religion, admissionYear, motherName, permanentMobile,
section, city, pinCode
```

Header names are forgiving — `Student Name`, `Registration Number`,
`Branch`, `Semester`, `Hostel Number`, `Room No.` all map correctly.

Two fields are derived when blank:
- **`batch`** from the registration number (`2110910` → admitted 2021 → `2021-22`)
- **`sem`** accepts `5`, `Sem 5`, `5th` or `V`

### Logins

Students sign in with their **registration number as both username and
password**. Tell them to change it from My Profile after first login.

## Deleting students

The counterpart the app can't provide. Removes the Auth account *and* the
Firestore profile, and frees any room they held so bed counts stay correct.

```bash
# preview
node delete-students.js --from-csv ../students.csv

# do it
node delete-students.js --from-csv ../students.csv --commit
```

`--from-csv` deletes only the people listed in that file — the safe way to
undo a botched import.

### Orphaned sign-in accounts

```bash
node delete-students.js --orphans           # preview
node delete-students.js --orphans --commit  # do it
```

An **orphan** is a sign-in account with no profile document behind it. The app
deletes both where it can, but deleting an Auth account from a browser means
signing in as it — which only works when the password is the one derived from
the registration number. Give someone a custom password in *Add user* and the
app can no longer remove their login, so deleting them leaves an orphan.

The symptom is **"email already in use"** when you re-add the same person.
This is the fix. It only touches accounts with no profile *anywhere*, so a
user belonging to another workspace is never removed.

To wipe every non-admin account in the college:

```bash
node delete-students.js --all-students --i-mean-it --commit
```

**A Super Admin is never deleted**, under any combination of flags.

## When to use which

| Situation | Use |
|---|---|
| Warden adds 5 new students mid-semester | The app's CSV import |
| You seed 200 students at session start | `import-students.js` |
| A test import went wrong | `delete-students.js --from-csv` |
| You need an Auth account actually gone | `delete-students.js` |

## Keeping the two importers in step

`lib.js` deliberately mirrors the Dart implementation — CSV parsing, header
aliases, synthetic login emails, sem and batch derivation. If you change a rule
on one side, change it on the other. A student imported by this script and one
imported in-app must come out identical, or the fines dashboard buckets them
separately and nobody can work out why.

| This script | The app |
|---|---|
| `lib.js` → `parseDelimited` | `lib/services/csv_import.dart` |
| `lib.js` → `toAuthEmail`, `derivedPassword` | `lib/core/identity.dart` |
| `lib.js` → `parseSem`, `batchFromRegistrationNo` | `csv_import.dart`, `app_user.dart` |
| `lib.js` → `TRADES` | `kTrades` in `lib/models/app_user.dart` |
