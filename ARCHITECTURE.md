# Homi Hostel — how the app is put together

Written for you, future-Pravjeet, so you can pick this up in a week and know
where things go.

---

## 1. The big decision: one dashboard, not five

You asked whether to build a separate dashboard per role, or one shared
dashboard that hides things. **Build one.** Here's the reasoning, because the
reasoning matters more than the answer:

Separate dashboards look tidy on day one and rot fast. The moment you add
"Notices", you have to add it to the warden dashboard, the chief warden
dashboard, the manager dashboard — and you *will* forget one. Worse, the
dashboards drift: the warden's user table gets a search box, the manager's
doesn't. And your role list isn't fixed anyway — you specifically want the
Super Admin to invent roles like "Hostel Manager" at runtime. You cannot write
a Dart file for a role that doesn't exist yet.

So: **one shell, permission-filtered navigation.**

```
lib/core/nav_registry.dart   ← the master list of every screen in the app
lib/core/permissions.dart    ← the vocabulary of what can be granted
lib/core/session.dart        ← "who is looking at this screen"
lib/screens/dashboard_shell.dart ← the sidebar + header everyone shares
```

`nav_registry.dart` declares each sidebar entry with a `requires:` list.
`navigationFor(session)` filters that list. A Student and a Super Admin run
the identical widget tree; they just survive the filter differently.

Adding a feature is now one entry in `_allSections` plus one page file. It
appears automatically for every role that was granted the permission — and for
no one else.

**Roles are data, not code.** `colleges/{id}/roles/{roleId}` holds a name and a
list of permission strings. The Roles page is a permission-ticking UI. Invent
"Mess Supervisor" at 2am and it works, with the right sidebar, no rebuild.

---

## 2. Data model

```
colleges/{collegeId}
    name, ownerUid, createdAt
  └── roles/{roleId}
        name, description, permissions: ["users.view", "mess.manage", ...], isSystem

users/{uid}                      ← top-level on purpose (see below)
    uid, name, email, collegeId,
    roleId, roleName,            ← roleName is denormalised so lists don't N+1
    isSuperAdmin, isActive,
    phone, gender, enrollmentNo, createdAt
```

`users` is a **root collection**, not a subcollection of the college. At login
you only have a `uid` — you don't know the college yet. A root collection lets
you read `users/{uid}` in one hop and learn the `collegeId` from it. If users
lived under the college you'd need a collection-group query just to log
somebody in.

---

## 3. Permission strings

`"<module>.<action>"` — `users.view`, `mess.manage`, `requests.approve`.

Your old model had `read / get / list / write / create / update / delete`.
That's a copy of *Firestore's* rule verbs, and it can't answer the only
question the UI actually asks: **"should the Mess menu appear for this
person?"** `canRead == true` doesn't tell you *what* they can read. Module
permissions do.

Checking one is `session.can(Perm.usersEdit)`. Super Admin short-circuits to
`true` for everything.

---

## 4. Auth flow

```
main() → Firebase.initializeApp (errors caught, shown on screen)
       → AuthGate
           StreamBuilder<User?>  (authStateChanges)
             null      → LoginScreen
             signed in → watch users/{uid} → watch the role doc
                       → SessionScope(session) → DashboardShell
```

Consequences worth noticing:

- **Sessions survive a restart.** Your old gate was a menu, so a logged-in
  user was shown the login form again on every launch.
- **`signOut()` is the only logout code you need.** The stream fires and the
  gate swaps the screen. No `pushAndRemoveUntil`, no stale route stacks.
- **Permission changes are live.** The role doc is watched, not fetched once.
  Revoke `mess.view` and the warden's sidebar loses the entry immediately.
- **There is no role selector on the login screen.** Role comes from the
  database. The old code routed by comparing role names in `login_screen.dart`,
  which meant a custom role like "Hostel Manager" hit the `else` branch and got
  "Access Denied".
- Users with no role, or a deactivated account, get an explanatory screen
  rather than a dead end.

---

## 5. Creating sub-users — the honest caveat

`createUserWithEmailAndPassword` signs in the *new* user, which would log the
admin out. The workaround (kept from your code, tidied) is a secondary
`FirebaseApp` instance that is created, used, and deleted.

It works. It is not what you'd ship. The real answer is a **Cloud Function
using the Admin SDK**, which also lets you actually delete an Auth account —
today `deleteUserProfile` only removes the Firestore document, so the login
credential lingers. That's why the UI offers **Deactivate** first and warns you
on Delete. Put this on the list for when you're ready for the Blaze plan.

---

## 6. Security rules

`firestore.rules`. Deploy with:

```bash
firebase deploy --only firestore:rules
```

The single most important idea: **the UI hiding a button is not security.**
Anyone can hit the Firestore REST API with their ID token. Every check in the
app is repeated in the rules, and the rules are what actually enforce it.

Guards worth knowing about:

- No cross-college reads. Every rule compares against the caller's `collegeId`.
- No self-promotion. You may edit your own `name`, `phone`, `gender` — not your
  `roleId`, `collegeId`, `isSuperAdmin` or `isActive`.
- The `isSystem` Super Admin role can't be edited or deleted.
- Everything not explicitly matched is denied.

**Test them before you trust them** — Firebase Console → Firestore → Rules →
Playground. Try to read a user from a college you don't belong to.

---

## 6b. Room allotment

Warden picks a student → picks a free room → done. No request queue, no
approval step, current occupancy only (no history).

**The write touches three documents and must be atomic:**

```
rooms/{roomId}     occupantUids  += student
users/{uid}        hostelId, hostelName, roomId, roomNumber, allottedAt
hostels/{hostelId} occupiedBeds  += 1
```

It runs in a **transaction**, not a batch, and the distinction is the whole
point. A batch writes blindly. A transaction re-reads the room at commit time
and aborts if anything changed. Without it, two wardens clicking "Allot" on the
last free bed at the same instant both read *1 free*, both write, and you get
three students in a two-seater. With it, the second attempt retries against
fresh data, sees the room is full, and fails with a readable message.

**Why the student's room is stored twice.** `occupantUids` on the room drives
occupancy display; `roomId`/`roomNumber` on the user makes "My Room" a single
document read instead of a collection-group query across every room in the
institution. Both sides are written in the same transaction, so they can't
disagree.

**Gender is enforced.** A Boys hostel refuses a student marked Female, and vice
versa; co-ed takes anyone. A student with *no* gender recorded is allowed
through — blocking on missing data would strand real students — but the allot
dialog shows a warning icon so you know to fill it in.

**Two permissions, deliberately.** `hostels.manage` changes the building
(capacity, features, status). `allotment.manage` moves people. The Firestore
rules enforce that split field-by-field: an allotment write may only touch
`occupantUids` on a room, `occupiedBeds` on a hostel, and the five room fields
on a user. A warden who can fill beds still cannot rename anyone or change a
role.

**Optional profile fields** (course, year, DOB, blood group, guardian contact,
address, notes) are *not* asked for at account creation — you only need name,
email and role to get someone in. They're filled in afterwards from the user
detail screen, reachable by clicking any row in User Management or Room
Allotment. That's why every one of them is nullable.

---

## 7. Where to add the next feature

Say you're building Notices:

1. `lib/screens/pages/notices_page.dart` — the UI.
2. `lib/core/nav_registry.dart` — swap `_notices` to return your page.
   (`Perm.noticesView` / `Perm.noticesManage` already exist.)
3. `lib/services/data_service.dart` — the Firestore reads/writes.
4. `firestore.rules` — a `match /colleges/{collegeId}/notices/{id}` block
   gating on those same permission strings. There's a template at the bottom of
   the file.

That's the whole loop. No dashboard files to touch.

---

## 8. Your old code — what to keep doing, what to change

Genuinely good instincts already there:

- Services separated from widgets.
- The secondary-FirebaseApp trick for sub-user creation — that's a non-obvious
  problem and you found the real workaround.
- `mounted` checks after `await` before `setState`. Lots of people skip that.
- Batched writes for the multi-document registration.
- Cleaning up roles when a role is deleted, so no user points at a ghost.

Habits worth changing:

1. **Don't branch on role names.** `if (role == 'Warden')` was scattered
   through login and the dashboards. Every custom role breaks it. Branch on
   permissions.
2. **Don't pass data down constructors when the source of truth is Firestore.**
   `SuperAdminDashboard(institutionName:, adminName:, email:)` meant the name in
   the header went stale the moment the profile changed, and every dashboard
   re-fetched `collegeId` in its own `initState`. Load it once at the gate.
3. **`print` → `debugPrint`**, or better, surface the error in the UI. A
   `print` in a `catch` that then returns `[]` gives the user a blank screen and
   no idea why. Every failure path here now produces a visible message.
4. **`Map<String, dynamic>` everywhere is a typo waiting to happen.**
   `user['isActve']` compiles fine and is silently null forever. Models turn
   that into a compile error.
5. **Duplicate logic.** `database_service.dart` and `firebase_auth_service.dart`
   both wrote user profiles, with *different* fields (`isActive` in one, not the
   other). Whichever one you called last won. One writer per collection.
6. **Raw Firebase errors aren't user-facing.** `[firebase_auth/wrong-password]
   The password is invalid...` in a red SnackBar isn't an error message, it's a
   stack trace. See `AuthService.describeError`.
7. **1100-line widget files.** `roles_view.dart` was 1162 lines. When a file
   gets past ~300, the sub-widgets inside it want to be their own files.

On workflow:

- **Commit small and often**, with messages describing *why*. You had one large
  working blob; git would let you experiment without fear.
- **Run `flutter analyze` before you run the app.** It catches in two seconds
  what you'd otherwise find by clicking through five screens.
- **Build one vertical slice at a time** — Notices end to end (model → service →
  rules → UI) beats five half-built modules. You get something demonstrable, and
  each slice teaches you the pattern for the next.
- **Write the security rule at the same time as the feature**, not "before
  launch". Rules written retroactively against an existing schema are miserable.

---

## 9. First run

```bash
flutter pub get
flutter analyze          # expect zero errors
flutter run -d chrome    # or -d windows

firebase deploy --only firestore:rules
```

In Firebase Console → Authentication, make sure **Email/Password** is enabled.

Then: Register a new institution → you land in the dashboard as Super Admin →
Roles & Permissions already has Chief Warden / Warden / Caretaker / BHS /
Student templates → User Management → Add user. To see the difference for
yourself, open a private window and sign in as the student you just made.

Your previous screens are preserved in `_legacy_backup_old_code/` at the
project root (outside `lib/`, so they don't get compiled). Delete the folder
once you're happy.
