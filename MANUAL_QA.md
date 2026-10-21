# Manual role-based QA script

Testing as Super Admin never exercises a permission branch — `can()` in
`session.dart` short-circuits to `true` for `isSuperAdmin`. This script only
proves anything if you actually sign in as the roles below. It can't be
automated from here: it needs real accounts in your live workspace
(`homihostel-57391`) and a human clicking through the browser.

Run this after any change to `firestore.rules`, `nav_registry.dart`,
`permissions.dart`, or a page's permission checks — and once as a baseline
now, before real students start using the app.

## 0. Set up standing test accounts (once)

Create these once, in your real college workspace, and reuse them for every
future QA pass rather than making new ones each time:

| Account | Role | How |
|---|---|---|
| `qa-warden` | Warden (starter template) | Users → Add user, or CSV import |
| `qa-chiefwarden` | Chief Warden (starter template) | same |
| `qa-student` | Student (starter template) | same, give it a registration number like `99999999` so you can log in with just that number |

Keep a note of each one's password (for staff, whatever you set; for the
student, it's `Identity.derivedPassword('99999999')` — the registration
number itself, since it's already 8 characters).

Do **not** reuse these for real data — no real fines, real requests, or real
room allotments against them, since this script deletes/undoes things.

## 1. Sidebar — does each role see what it should and nothing else

Sign in as `qa-student`. Confirm the sidebar shows: Dashboard, My Room, Mess,
Requests, Notices, Fines, Mess Fees, Office Orders, My Profile — and **not**
User Management, Roles & Permissions, Hostels & Rooms, Room Allotment, System
Settings, Activity Log.

Sign in as `qa-warden`. Confirm: Users, Hostels & Rooms, Room Allotment,
Mess, Requests, Notices, Fines, Mess Fees, Office Orders — and **not** Roles
& Permissions, System Settings, Activity Log.

Sign in as `qa-chiefwarden`. Same as Warden, plus confirm the *manage*
actions inside those pages are available (see §3).

## 2. Data isolation — a role can only see what it's allowed to, not less by luck

As `qa-student`:
- Open Fines / Mess Fees / Requests. Confirm you see **only your own**
  entries, not the whole roster.
- Try navigating directly to a staff-only page's URL/state if the app
  exposes one (deep link, browser back button after a permission change).
  Confirm it refuses rather than flashing the data first.

As `qa-warden`:
- Open Fines / Mess Fees / Requests. Confirm you see **everyone's**.
- Try to approve a request *raised by `qa-warden` itself* if you can create
  one — `firestore.rules` explicitly blocks self-approval
  (`requests.approve` excludes the author). Confirm the UI either hides the
  approve action on your own request or the write fails cleanly.

## 3. Manage-level actions — Chief Warden has them, Warden doesn't

As `qa-warden`, confirm these are **not** available (button hidden, or a
clean "you don't have permission" if forced):
- Create/edit a user
- Manage hostels & rooms (add/edit blocks, "Regenerate rooms…")
- Manage mess menu
- Publish an office order
- Publish a notice

As `qa-chiefwarden`, confirm all of the above **are** available and work.

## 4. Things that must be refused even for Chief Warden

- Delete a user (only `users.delete` grants this — neither starter template
  has it). Confirm the option is absent or the write fails.
- Open Roles & Permissions or System Settings. Confirm both are unreachable.
- Try to edit *your own* role's permission set to add one you don't have —
  `firestore.rules`' `roles` update rule should refuse.

## 5. The synthetic-login student flow end to end

- Log in as `qa-student` using just the registration number (no `@`).
- Go to Profile → **Change password**. Change it, sign out, sign back in
  with the new password. Confirm the old (derived) password no longer works.
- Confirm the "Email me a reset link" button is **absent** for this account
  (no inbox to send to) — see `profile_page.dart`.

## 6. Room allotment and the "regenerate rooms" safety check

- As `qa-chiefwarden`, allot `qa-student` to a test room.
- Try Hostels & Rooms → that hostel → Edit details → Regenerate rooms.
  Confirm it **refuses**, naming the occupied room, because `qa-student` is
  in it.
- Vacate `qa-student` from the room, then retry regenerate — confirm it now
  succeeds and the room count/bed count update correctly afterward.

## 7. Cross-college isolation (only if you have a second test workspace)

If you've registered a second test college, confirm a user in college A
cannot read anything under college B's `colleges/{collegeId}` subtree even
by permission level — `sameCollege()` in the rules should refuse regardless
of role.

## After the run

Note anything that failed against the step it belongs to, fix, redeploy
rules if that's what changed (`./deploy-rules.bat` then `./check-rules.bat`),
and re-run just the failed section — not the whole script — to confirm the
fix.
