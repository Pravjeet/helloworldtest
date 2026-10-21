# Development notes

Working notes for anyone changing this codebase — the conventions that are
not obvious from the source, and the mistakes this project has already made.

Homi Hostel — a Flutter + Firebase hostel management dashboard for SLIET.
Read `ARCHITECTURE.md` for the reasoning behind the design, `MANUAL_QA.md`
for the role-by-role click-through, and `DEPLOY_CHECKLIST.md` before any
release; this file is the short operational brief.

## Commands

```bash
flutter analyze                          # ALWAYS run before saying code is done
flutter test                             # Dart unit tests (test/, no emulator needed)
flutter test test/csv_import_test.dart   # one file
flutter test --plain-name "batch"        # one test by name
flutter run -d edge                      # web (primary target during development)
flutter run -d windows                   # desktop
./deploy-web.bat                         # analyze + test + build web + deploy hosting
```

```bash
cd rules-tests && npm test               # firestore.rules assertions, via the emulator
```

`flutter analyze` is the single most useful thing you can run here. Much of
this codebase was written without a compiler available, so treat a clean
analyze as the minimum bar, not a bonus.

The rules tests boot `firebase emulators:exec --only firestore` against a
throwaway project id, so they never touch live data — unlike `MANUAL_QA.md`,
which needs real accounts in the live workspace and a human.

## The one architectural rule

**One dashboard, permission-filtered.** There is no per-role dashboard and
there must never be. `lib/core/nav_registry.dart` is the master list of every
screen; each entry declares a `requires:` list of permission strings, and
`navigationFor(session)` filters it. A Student and a Super Admin run the
identical widget tree.

Adding a feature = one entry in `_allSections` + one page file + a rules block.

**Never branch on role names** (`if (role == 'Warden')`). Roles are user-created
data, so any such check breaks the moment someone invents "Hostel Manager".
Branch on `session.can(Perm.x)`.

A `NavItem` also has `excludes:` — hide an entry from anyone holding those
permissions. It exists because `can()` short-circuits to true for a Super
Admin, so self-service pages (`My Room`) would otherwise show the workspace
owner a room they will never be allotted.

## Layout

```
lib/core/          permissions, session, nav registry, theme, identity
lib/models/        AppUser, AppRole, Hostel/Room, HostelRequest, Mess, Fine,
                   Fee, Notice, OfficeOrder, AuditEntry, CollegeSettings
lib/services/      one service per module; widgets never touch Firestore
lib/screens/pages/ one file per page, plus *_view.dart for drill-downs
firestore.rules    security — the real enforcement, not the UI
rules-tests/       emulator assertions against those rules
tools/             Node Admin-SDK scripts — import, delete, backup
```

Pages hold drill-down state internally (`_openHostelId`, `_openUser`) rather
than pushing routes, so the sidebar stays visible.

## Data model

```
colleges/{collegeId}
  ├── roles/{roleId}          name, permissions[], isSystem
  ├── hostels/{hostelId}      + denormalised roomCount/bedCount/occupiedBeds
  │     └── rooms/{roomNumber}   room number IS the doc id
  ├── requests/{requestId}    leave / complaint / roomChange / other
  ├── fines/{fineId}          feeRecords/{id}   mess fees
  ├── notices/  officeOrders/  auditLog/
  ├── settings/config         one fixed doc id — the whole workspace config
  ├── photos/{uid}            ID photo, base64 JPEG (~40 KB) — never on users/
  └── mess/menu, mess/config  same single-doc pattern

users/{uid}                   root collection, NOT under the college
```

`users` is root because at login you only have a uid — you don't know the
college yet. Room allotment is denormalised onto both the room
(`occupantUids`) and the user (`roomId`, `roomNumber`), written in one
transaction so they cannot disagree.

**An office order covers one *or more* students.** One incident is one order:
five students in the same fight get a single order naming all five, not five
near-identical ones — which is how the office issues them, and it stores the
scanned photo once instead of five times. The shape is three fields that must
stay in step:

  * `students[]`  — `{uid, name, regNo, fineId, fineAmount}` per person
  * `studentUids[]` — a flat array of the same uids, existing **only** so
    "orders against this student" can be a query; array-contains cannot reach
    inside `students[].uid`
  * `fineTotal` — the sum, denormalised for the same class of reason: security
    rules cannot look inside an array, so this is what tells them "this order
    levies money, require fines.manage"

Amounts are per student and optional. The ringleader and the bystander do not
pay the same, and a student can be named on an order with no fine at all. An
order fining nobody is a warning or suspension and writes no fine documents.
Each fined student still gets their own `fines/{id}`, so each is settled,
waived and counted independently.

**A role is staff or resident, and it is decided by permissions, not name.**
`Perm.isResident` returns true only when a role holds nothing reaching beyond
itself — no `.manage`, no `.viewAll`, no user-directory access. The
user-creation form asks it to decide whether to collect a full student record
(every CSV column) or a staff one. Tested that way round on purpose: a *new*
self-service permission added later must not be misfiled as staff. Do not
substitute `Perm.managesHostels` — an accountant runs no hostel but is
emphatically not a student.

## Things that will bite you

**Allotment must be a transaction, never a batch.** Two wardens clicking the
last free bed simultaneously would both read "1 free" and both write. See
`AllotmentService.allot`.

**Students log in with a registration number**, mapped to a synthetic address
(`2110910@homihostel.local`) by `lib/core/identity.dart`. Never show a raw
synthetic address in the UI — use `Identity.display()`. Synthetic addresses
have no inbox, so password reset cannot work for students.

**Creating users client-side is a workaround.** `AuthService.createSubUser`
uses a secondary FirebaseApp because `createUserWithEmailAndPassword` would
otherwise sign the admin out. Firebase quotas that endpoint per project, so
large imports still belong in `tools/import-students.js` (Admin SDK, no
quota). `deleteUserProfile` only removes the Firestore doc — the Auth account
lingers.

**`runImport` is three phases, and the middle one is deliberately timid.**
Updates are plain Firestore writes and run 10-wide; account creation runs on
`runPooled` lanes that **narrow to one permanently** the first time Firebase
answers `too-many-requests`; allotment stays strictly sequential because rows
can name the same room and the room cache is shared mutable state. Never
"tune up" the create concurrency to match the Node script's — that script is
on a different endpoint with a service-account key, and the block this one
risks tripping is project-wide, affecting real student sign-ins. The pool
logic is tested in `test/run_pooled_test.dart` against a fake task.

**Reads are a budget, not free.** Spark plan: 50,000 document reads/day, and a
2,500-student roster once burned that in ~19 screen opens because six pages
each called `watchUsers()` from inside `build()`. Every service therefore
hands out streams from `CachedStreamPool` (`lib/services/stream_cache.dart`):
one upstream subscription shared by all listeners, and — just as important —
the *same* `Stream` instance for the same query, so a keystroke in a search
box doesn't make `StreamBuilder` tear down and re-read. Never call
`.snapshots()` straight from a widget, and never build a new stream object
per rebuild. The pool outlives the widget tree, so `StreamCaches.disposeAll()`
must run on sign-out or the next user inherits the previous one's data.

Every `watch…` in `lib/services/` goes through a pool — there are no
exceptions left, and a new one is a bug rather than a style choice. The rule
holds for single documents too: `watchProfile`, `watchRole` and
`watchCollegeName` sit in nested `StreamBuilder`s at the root of `AuthGate`,
so they are re-evaluated on every rebuild of the whole app, and the per-student
`watchMine` queries are small but paid once per resident across a few thousand
of them.

**A `Future` built inside `build()` is the same mistake, and harder to see.**
`FutureBuilder(future: service.thing())` re-runs the read on every rebuild,
and unlike a stream there is no pool to catch it — the fix is to memoise the
future in a `State` field, keyed on whatever genuinely invalidates it, so a
real change still refetches. See `_MyRoomPageState._roomFor` (keyed on the
allotment) and `_FeedState._countsFor` (keyed on the role set).

**Counting is not reading.** The dashboard wants seven integers, and deriving
them from the roster cost one billed read per student — 2,650 on this campus,
every time the app opened, before anyone clicked anything. `count()` answers
from the index instead, billed one read per 1,000 entries matched: the same
figure costs 3 reads, and no document data crosses the network. See
`DataService.countUsersByRole`, which counts per role so one batch yields the
total, the resident/staff split *and* the breakdown chart.

Aggregations are subject to the same rules as the underlying query, and the
users `list` rule constrains `resource.data`, which an aggregation never
produces — so whether it worked at all was an open question. It does, and
`rules-tests` pins it along with the denials that matter: no `users.view`, no
count; another college, no count; unscoped across all colleges, no count. If
you touch that rule, run those tests before assuming the dashboard still
loads.

The trade is that a `count()` is a `Future`, not a `Stream` — the dashboard
shows a snapshot from when it loaded. That is right for a summary screen and
wrong for Room Allotment, where two wardens genuinely race. Memoise the
futures (see `_FeedState._countsFor`) or every rebuild re-fires the batch,
which is the cost the change exists to remove.

**There is no Firebase Storage** (Spark plan, no billing account). Images —
the college logo, office-order scans, fine attachments — are base64 strings
inside Firestore documents. Mind the 1 MB per-document limit.

**Office-order photos are still inside the order documents**, and the register
streams every one of them. Forty orders is roughly 35 MB transferred to render
forty rows of text. The reads are cheap — forty documents — but the bandwidth
and memory are not, and it worsens with every order issued. Moving the image
to `officeOrders/{id}/media/photo` would let the register stream metadata only
and fetch a photo when someone actually opens one. Not done yet; know about it
before adding anything else to that page.

**`tools/lib.js` deliberately mirrors Dart code and must stay in step.** CSV
parsing, header aliases, synthetic login emails, sem/batch derivation and the
trade list exist twice: `lib.js` ↔ `csv_import.dart`, `identity.dart`,
`app_user.dart`. A student imported by the script and one imported in-app must
come out byte-identical, or the fines dashboard buckets them separately. The
mapping table is at the bottom of `tools/README.md`.

**`Session.of(context)` throws inside a dialog.** `showDialog` pushes onto the
root Navigator, so the dialog's context sits *above* `SessionScope` and the
lookup fails the moment it opens — a full-screen red error, not a subtle bug.
`flutter analyze` cannot see it, because it fails at runtime. Read the session
in the calling page and pass what the dialog needs as constructor arguments;
`BulkDeleteUsersDialog` and `RoomDetailDialog` both document the pattern, and
`test/room_detail_dialog_test.dart` pins it by pumping the dialog with no
scope above it. This has already shipped broken once.

**A widget that returns `Expanded` or `Spacer` needs a bounded parent.** A
card inside a `Wrap` has unbounded height; a vertical flex child there fails
to lay out and silently blanks the whole list. This has already happened once.

**`ConstrainedBox` is not const-constructible** (its constructor asserts via a
method call). Neither are `Container`, `AlertDialog`, `Tooltip`.

## Security rules

The UI hiding a button is not security — anyone can hit the Firestore REST API
with their ID token. Every permission check in the app is repeated in
`firestore.rules`, and those are what enforce it.

`hasPerm()` short-circuits on `isSuperAdmin()`, so **testing as Super Admin
will not exercise the permission branches.** Create a Warden and a Student to
test properly. If you see "You don't have permission to do that" while signed
in as Super Admin, the rules are out of date — redeploy.

### Deploying rules — non-negotiable

**Any change to `firestore.rules` is not real until it is deployed.** The file
on disk has no effect; only the published version does.

```bash
./deploy-rules.bat     # publishes, and records the deployed hash
./check-rules.bat      # says whether live rules match the file
```

**Run `deploy-rules.bat` immediately after editing `firestore.rules`** — not
at the end of the day, not "before the next release". The gap between editing
and deploying is where the confusing permission errors live.

**If you cannot run it** (no credentials to hand), then say so explicitly in
whatever you hand over — a clearly marked note that the rules changed and must
be deployed, naming what changed and who it affects. Silently editing the file
and moving on has already caused confusing permission errors in this project
more than once.

## Reference data

College details and structure: https://sliet.ac.in/
