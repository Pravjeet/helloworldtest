import 'package:flutter/material.dart';

import '../../core/identity.dart';
import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/app_role.dart';
import '../../models/app_user.dart';
import '../../models/college_settings.dart';
import '../../models/hostel.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/hostel_service.dart';
import '../../widgets/hostel_picker_chips.dart';
import 'bulk_delete_users_dialog.dart';
import 'import_students_dialog.dart';
import 'user_detail_view.dart';

class UsersPage extends StatefulWidget {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

/// Deletes everyone the current filter is showing.
///
/// Scoped to the filtered list rather than "all students" on purpose: roles
/// are user-created data, so hard-coding a role name here would break the
/// moment someone renames Student or invents a second resident role. Filter
/// the list to what you want gone, then delete what you can see.
class _BulkDeleteButton extends StatelessWidget {
  final List<AppUser> targets;
  final String scopeLabel;
  final ValueChanged<List<AppUser>> onConfirm;

  const _BulkDeleteButton({
    required this.targets,
    required this.scopeLabel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final n = targets.length;
    return Tooltip(
      message: n == 0
          ? 'Nothing to delete in the current filter'
          : 'Deletes the $n user(s) currently listed ($scopeLabel).\n'
                'Super Admins and your own account are never included.',
      child: OutlinedButton.icon(
        onPressed: n == 0 ? null : () => onConfirm(targets),
        icon: const Icon(Icons.delete_sweep_rounded, size: 18),
        label: Text('Delete $n shown'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.danger,
          side: BorderSide(color: AppColors.dangerSoft),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
    );
  }
}

class _UsersPageState extends State<UsersPage> {
  String _query = '';

  /// Defaults to showing only the Super Admin rather than the whole roster.
  /// With a few thousand students imported, rendering "All" on first load
  /// means building a row for every one of them before anyone's chosen to
  /// look — picking any other filter (including "All" explicitly) shows
  /// the rest.
  String _roleFilter = 'Super Admin';

  /// Null = any. `_kUnallotted` is a real choice, not a missing one — finding
  /// who still needs a bed is the reason someone opens this filter.
  String? _hostelFilter;
  String? _roomFilter;

  static const _kUnallotted = '__none__';

  /// Null = anyone; true = can sign in; false = record only (see
  /// [AppUser.hasLogin]).
  bool? _loginFilter;

  /// Rendered a page at a time — with a few thousand students imported,
  /// building a row for every match at once is what makes the screen crawl
  /// or crash. Reset to 0 whenever a filter changes, so "page 3" of the old
  /// results doesn't silently carry over into a much smaller new list.
  static const _pageSize = 50;
  int _page = 0;

  /// Owned so "Clear filters" can actually empty the box. Without a
  /// controller, resetting `_query` in setState leaves the typed text on
  /// screen while the list silently shows everything.
  final _search = TextEditingController();
  final _roomSearch = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    _roomSearch.dispose();
    super.dispose();
  }

  /// Cached so the import dialog can resolve hostel names to allot rooms.
  List<Hostel> _hostels = const [];

  /// Set when a row is tapped. Held as state rather than pushed as a route so
  /// the dashboard sidebar stays visible on the detail screen.
  AppUser? _openUser;

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;

    if (_openUser != null) {
      return UserDetailView(
        uid: _openUser!.uid,
        initial: _openUser!,
        onBack: () => setState(() => _openUser = null),
      );
    }

    return StreamBuilder<List<Hostel>>(
      stream: HostelService.instance.watchHostels(collegeId),
      builder: (context, hSnap) {
        _hostels = hSnap.data ?? const <Hostel>[];
        return StreamBuilder<List<AppRole>>(
          stream: DataService.instance.watchRoles(collegeId),
          builder: (context, roleSnap) {
            final roles = roleSnap.data ?? const <AppRole>[];
            final assignable = roles.where((r) => !r.isSystem).toList();

            return StreamBuilder<List<AppUser>>(
              stream: DataService.instance.watchUsers(collegeId),
              builder: (context, userSnap) {
                if (userSnap.hasError) {
                  return AppCard(
                    child: Text(AuthService.describeError(userSnap.error!)),
                  );
                }
                if (!userSnap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(60),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final all = userSnap.data!;
                final roomQuery = _roomFilter?.trim().toLowerCase() ?? '';

                final filtered = all.where((u) {
                  final q = _query.toLowerCase();
                  final matchesQuery =
                      q.isEmpty ||
                      u.name.toLowerCase().contains(q) ||
                      u.email.toLowerCase().contains(q) ||
                      (u.enrollmentNo ?? '').toLowerCase().contains(q);
                  final matchesRole =
                      _roleFilter == 'All' || u.displayRole == _roleFilter;
                  final matchesHostel = switch (_hostelFilter) {
                    null => true,
                    _kUnallotted => !u.isAllotted,
                    final h => u.hostelName == h,
                  };
                  final matchesRoom =
                      roomQuery.isEmpty ||
                      (u.roomNumber?.toLowerCase().contains(roomQuery) ??
                          false);
                  final matchesLogin =
                      _loginFilter == null || u.hasLogin == _loginFilter;
                  return matchesQuery &&
                      matchesRole &&
                      matchesHostel &&
                      matchesRoom &&
                      matchesLogin;
                }).toList();

                // Clamp defensively rather than writing back to `_page` here —
                // mutating state during build is asking for trouble. A stale
                // `_page` (e.g. the list shrank after a filter changed) self
                // corrects the moment Next/Prev is pressed again.
                final pageCount = filtered.isEmpty
                    ? 1
                    : (filtered.length / _pageSize).ceil();
                final page = _page.clamp(0, pageCount - 1);
                final pageStart = page * _pageSize;
                final pageItems = filtered
                    .skip(pageStart)
                    .take(_pageSize)
                    .toList();

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SectionHeader(
                            'Users  (${all.length})',
                            trailing:
                                (session.can(Perm.usersCreate) ||
                                    session.can(Perm.usersDelete))
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (session.can(Perm.usersDelete)) ...[
                                        _BulkDeleteButton(
                                          // Anything the current filter is
                                          // showing, minus the people who must
                                          // never be swept up in a bulk action.
                                          targets: filtered
                                              .where((u) => !u.isSuperAdmin)
                                              .where(
                                                (u) =>
                                                    u.uid != session.user.uid,
                                              )
                                              .toList(),
                                          scopeLabel: _scopeLabel,
                                          onConfirm: _openBulkDelete,
                                        ),
                                        const SizedBox(width: 10),
                                      ],
                                      if (session.can(Perm.usersCreate)) ...[
                                        OutlinedButton.icon(
                                          onPressed: assignable.isEmpty
                                              ? null
                                              : () => _openImportDialog(
                                                  all,
                                                  roles,
                                                ),
                                          icon: const Icon(
                                            Icons.upload_file_rounded,
                                            size: 18,
                                          ),
                                          label: const Text('Import CSV'),
                                          style: OutlinedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 14,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        ElevatedButton.icon(
                                          onPressed: assignable.isEmpty
                                              ? null
                                              : () => _openCreateDialog(
                                                  assignable,
                                                ),
                                          icon: const Icon(
                                            Icons.person_add_alt_1,
                                            size: 18,
                                          ),
                                          label: const Text('Add user'),
                                          style: ElevatedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 18,
                                              vertical: 14,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  )
                                : null,
                          ),
                          if (session.can(Perm.usersCreate) &&
                              assignable.isEmpty)
                            Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text(
                                'Create at least one role before adding users — '
                                'a user without a role can\'t see anything.',
                                style: TextStyle(
                                  color: AppColors.warning,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _search,
                                  onChanged: (v) => setState(() {
                                    _query = v;
                                    _page = 0;
                                  }),
                                  decoration: const InputDecoration(
                                    hintText:
                                        'Search by name, registration number or email',
                                    prefixIcon: Icon(Icons.search_rounded),
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Builder(
                                builder: (context) {
                                  final options = <String>[
                                    'All',
                                    'Super Admin',
                                    ...assignable.map((r) => r.name),
                                    'Unassigned',
                                  ];
                                  // If the selected role was just deleted, fall
                                  // back to 'All' rather than crashing the dropdown.
                                  final value = options.contains(_roleFilter)
                                      ? _roleFilter
                                      : 'All';
                                  return DropdownButton<String>(
                                    value: value,
                                    underline: const SizedBox.shrink(),
                                    items: options
                                        .map(
                                          (r) => DropdownMenuItem(
                                            value: r,
                                            child: Text(r),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (v) => setState(() {
                                      _roleFilter = v ?? 'All';
                                      _page = 0;
                                    }),
                                  );
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              SizedBox(
                                width: 220,
                                child: DropdownButtonFormField<String>(
                                  initialValue: _hostelFilter,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Hostel',
                                    isDense: true,
                                  ),
                                  hint: const Text('Any hostel'),
                                  items: [
                                    const DropdownMenuItem<String>(
                                      value: null,
                                      child: Text('Any hostel'),
                                    ),
                                    const DropdownMenuItem<String>(
                                      value: _kUnallotted,
                                      child: Text('Not allotted'),
                                    ),
                                    ..._hostels.map(
                                      (h) => DropdownMenuItem(
                                        value: h.name,
                                        child: Text(
                                          h.label,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                  // Clearing the room too: a room number from the
                                  // old hostel almost certainly matches nobody in
                                  // the new one, leaving an empty list that looks
                                  // like a bug.
                                  onChanged: (v) => setState(() {
                                    _hostelFilter = v;
                                    _roomFilter = null;
                                    _roomSearch.clear();
                                    _page = 0;
                                  }),
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 170,
                                child: TextField(
                                  controller: _roomSearch,
                                  enabled:
                                      _hostelFilter != null &&
                                      _hostelFilter != _kUnallotted,
                                  onChanged: (v) => setState(() {
                                    _roomFilter = v;
                                    _page = 0;
                                  }),
                                  decoration: const InputDecoration(
                                    labelText: 'Room',
                                    hintText: 'Search room no.',
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 170,
                                child: DropdownButtonFormField<bool?>(
                                  key: ValueKey('login-$_loginFilter'),
                                  initialValue: _loginFilter,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Login',
                                    isDense: true,
                                  ),
                                  items: const [
                                    DropdownMenuItem<bool?>(
                                      value: null,
                                      child: Text('Anyone'),
                                    ),
                                    DropdownMenuItem<bool?>(
                                      value: true,
                                      child: Text('Has login'),
                                    ),
                                    DropdownMenuItem<bool?>(
                                      value: false,
                                      child: Text('No login'),
                                    ),
                                  ],
                                  onChanged: (v) => setState(() {
                                    _loginFilter = v;
                                    _page = 0;
                                  }),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                filtered.isEmpty
                                    ? '0 of ${all.length}'
                                    : '${pageStart + 1}–'
                                          '${pageStart + pageItems.length} of '
                                          '${filtered.length}',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textMuted,
                                ),
                              ),
                              const Spacer(),
                              if (_hostelFilter != null ||
                                  _roomFilter != null ||
                                  _loginFilter != null ||
                                  _roleFilter != 'All' ||
                                  _query.isNotEmpty)
                                TextButton.icon(
                                  onPressed: () {
                                    _search.clear();
                                    _roomSearch.clear();
                                    setState(() {
                                      _hostelFilter = null;
                                      _roomFilter = null;
                                      _loginFilter = null;
                                      _roleFilter = 'All';
                                      _query = '';
                                      _page = 0;
                                    });
                                  },
                                  icon: const Icon(
                                    Icons.filter_alt_off_rounded,
                                    size: 17,
                                  ),
                                  label: const Text('Clear filters'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (filtered.isEmpty)
                      AppCard(
                        padding: EdgeInsets.symmetric(vertical: 50),
                        child: Center(
                          child: Text(
                            _hostelFilter != null &&
                                    _hostelFilter != _kUnallotted &&
                                    roomQuery.isNotEmpty
                                ? 'Room "${_roomFilter!.trim()}" in '
                                      '$_hostelFilter is not allotted to anyone.'
                                : 'No users match your filters.',
                            style: TextStyle(color: AppColors.textMuted),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    else
                      AppCard(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          children: [
                            for (var i = 0; i < pageItems.length; i++) ...[
                              _UserRow(
                                user: pageItems[i],
                                roles: assignable,
                                isSelf: pageItems[i].uid == session.user.uid,
                                onOpen: () =>
                                    setState(() => _openUser = pageItems[i]),
                              ),
                              if (i != pageItems.length - 1)
                                Divider(
                                  height: 1,
                                  indent: 20,
                                  endIndent: 20,
                                  color: AppColors.border,
                                ),
                            ],
                          ],
                        ),
                      ),
                    if (pageCount > 1) ...[
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          OutlinedButton(
                            onPressed: page > 0
                                ? () => setState(() => _page = page - 1)
                                : null,
                            child: const Text('Previous'),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              'Page ${page + 1} of $pageCount',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                          OutlinedButton(
                            onPressed: page < pageCount - 1
                                ? () => setState(() => _page = page + 1)
                                : null,
                            child: const Text('Next'),
                          ),
                        ],
                      ),
                    ],
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// Human description of what the list is currently filtered to, echoed in
  /// the delete confirmation so you can see whether this is the batch you
  /// meant before you wipe it.
  String get _scopeLabel {
    final parts = <String>[
      if (_roleFilter != 'All') 'role "$_roleFilter"' else 'all roles',
      if (_loginFilter == true) 'has login',
      if (_loginFilter == false) 'no login',
      if (_query.trim().isNotEmpty) 'search "${_query.trim()}"',
    ];
    return parts.join(' · ');
  }

  Future<void> _openBulkDelete(List<AppUser> targets) async {
    final collegeId = Session.of(context).user.collegeId;
    final messenger = ScaffoldMessenger.of(context);

    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BulkDeleteUsersDialog(
        collegeId: collegeId,
        users: targets,
        scopeLabel: _scopeLabel,
      ),
    );

    if (done == true) {
      messenger.showSnackBar(const SnackBar(content: Text('Users deleted')));
    }
  }

  Future<void> _openImportDialog(
    List<AppUser> existing,
    List<AppRole> roles,
  ) async {
    // Read the session HERE, from the page's context — inside the builder the
    // context belongs to the dialog's route, which sits above SessionScope.
    final collegeId = Session.of(context).user.collegeId;
    final knownTrades = Session.of(context).settings.tradeCodes;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ImportStudentsDialog(
        collegeId: collegeId,
        existingUsers: existing,
        roles: roles,
        hostels: _hostels,
        knownTrades: knownTrades,
      ),
    );
  }

  Future<void> _openCreateDialog(List<AppRole> roles) async {
    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CreateUserDialog(
        collegeId: Session.of(context).user.collegeId,
        roles: roles,
        hostels: _hostels,
        settings: Session.of(context).settings,
      ),
    );
    if (created == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('User created')));
    }
  }
}

class _UserRow extends StatelessWidget {
  final AppUser user;
  final List<AppRole> roles;
  final bool isSelf;
  final VoidCallback onOpen;

  const _UserRow({
    required this.user,
    required this.roles,
    required this.isSelf,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    // Nobody may edit the Super Admin, and nobody may edit themselves into
    // a corner — both guarded here and in the Firestore rules.
    final editable =
        session.can(Perm.usersEdit) && !user.isSuperAdmin && !isSelf;

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 21,
              backgroundColor: AppColors.primarySoft,
              child: Text(
                user.initials,
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14.5,
                          ),
                        ),
                      ),
                      if (isSelf)
                        Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: StatusPill(
                            'YOU',
                            AppColors.info,
                            AppColors.infoSoft,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Identity.display(user.email),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: user.roleId == null && !user.isSuperAdmin
                    ? StatusPill(
                        'NO ROLE',
                        AppColors.warning,
                        AppColors.warningSoft,
                      )
                    : StatusPill(
                        user.displayRole.toUpperCase(),
                        AppColors.primary,
                        AppColors.primarySoft,
                      ),
              ),
            ),
            if (!user.hasLogin)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: StatusPill(
                  'NO LOGIN',
                  AppColors.warning,
                  AppColors.warningSoft,
                ),
              ),
            if (!user.isActive)
              StatusPill('DEACTIVATED', AppColors.danger, AppColors.dangerSoft),
            const SizedBox(width: 8),
            if (editable)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (v) => _handle(context, v),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'role',
                    child: Text('Change role'),
                  ),
                  PopupMenuItem(
                    value: 'active',
                    child: Text(user.isActive ? 'Deactivate' : 'Reactivate'),
                  ),
                  if (session.can(Perm.usersDelete))
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Delete profile',
                        style: TextStyle(color: AppColors.danger),
                      ),
                    ),
                ],
              )
            else
              const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }

  Future<void> _handle(BuildContext context, String action) async {
    final messenger = ScaffoldMessenger.of(context);
    // Read before the first await — these actions all show dialogs, and the
    // context may be gone by the time we need the actor for the audit entry.
    final session = Session.of(context);
    try {
      switch (action) {
        case 'role':
          final picked = await showDialog<AppRole?>(
            context: context,
            builder: (_) =>
                _RolePickerDialog(roles: roles, current: user.roleId),
          );
          if (picked != null) {
            await DataService.instance.setUserRole(
              user.uid,
              picked.id == '__none__' ? null : picked,
              collegeId: user.collegeId,
              actor: session.user,
            );
            messenger.showSnackBar(
              const SnackBar(content: Text('Role updated')),
            );
          }
          break;
        case 'active':
          await DataService.instance.setUserActive(
            user.uid,
            !user.isActive,
            collegeId: user.collegeId,
            actor: session.user,
          );
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                user.isActive ? 'User deactivated' : 'User reactivated',
              ),
            ),
          );
          break;
        case 'delete':
          // Whether the sign-in account can go too depends on the password
          // still being the derived one, which is knowable up front — so say
          // it in the dialog rather than surprising them afterwards.
          final canRemoveLogin =
              !user.hasLogin ||
              (user.enrollmentNo ?? '').trim().isNotEmpty ||
              Identity.isSynthetic(user.email);

          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text('Delete ${user.name}?'),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This removes their profile and access immediately'
                      '${user.isAllotted ? ', and frees ${user.roomLabel}' : ''}.',
                      style: const TextStyle(fontSize: 13.5, height: 1.5),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: canRemoveLogin
                            ? AppColors.infoSoft
                            : AppColors.warningSoft,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        !user.hasLogin
                            ? 'They have no sign-in account, so only their '
                                  'record is removed.'
                            : canRemoveLogin
                            ? 'Their sign-in account will also be removed, so '
                                  'the registration number can be re-imported '
                                  'cleanly.\n\nIf they have changed their '
                                  'password this part will fail and say so — '
                                  'the profile is still deleted.'
                            : 'Their sign-in account will NOT be removed — it '
                                  'has no derivable password. Use '
                                  'tools/delete-students.js for a complete '
                                  'wipe.',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.45,
                          color: canRemoveLogin
                              ? AppColors.info
                              : AppColors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                  ),
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (ok == true) {
            final outcome = await DataService.instance.deleteUserCompletely(
              collegeId: user.collegeId,
              user: user,
              actor: session.user,
            );
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  'Profile deleted · ${outcome.auth.explanation}'
                  '${outcome.finesDeleted == 0 ? '' : ' · ${outcome.finesDeleted} fine(s) removed'}',
                ),
                duration: outcome.auth.isGone
                    ? const Duration(seconds: 3)
                    : const Duration(seconds: 7),
              ),
            );
          }
          break;
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }
}

class _RolePickerDialog extends StatelessWidget {
  final List<AppRole> roles;
  final String? current;
  const _RolePickerDialog({required this.roles, required this.current});

  @override
  Widget build(BuildContext context) => SimpleDialog(
    title: const Text('Assign role'),
    children: [
      for (final r in roles)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, r),
          child: Row(
            children: [
              Icon(
                r.id == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 19,
                color: AppColors.primary,
              ),
              const SizedBox(width: 10),
              Text(r.name),
              const Spacer(),
              Text(
                '${r.permissions.length}',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      const Divider(),
      SimpleDialogOption(
        onPressed: () =>
            Navigator.pop(context, const AppRole(id: '__none__', name: '')),
        child: Text('Remove role', style: TextStyle(color: AppColors.danger)),
      ),
    ],
  );
}

class _CreateUserDialog extends StatefulWidget {
  final String collegeId;
  final List<AppRole> roles;
  final List<Hostel> hostels;

  /// Passed in rather than read from the context: showDialog pushes onto the
  /// root Navigator, so this dialog sits *above* SessionScope and
  /// `Session.of(context)` would throw. Same reasoning as
  /// [ImportStudentsDialog.collegeId].
  final CollegeSettings settings;

  const _CreateUserDialog({
    required this.collegeId,
    required this.roles,
    required this.hostels,
    required this.settings,
  });

  @override
  State<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<_CreateUserDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _enrollment = TextEditingController();

  // Everything below mirrors the columns the CSV importer accepts, so a
  // single manual add can capture the same detail a bulk import would —
  // without a second trip through the user's detail page afterwards.
  // Hostel/room are deliberately absent: allotment is a transaction against
  // live room availability (see AllotmentService.allot) and belongs to the
  // dedicated allot picker, not a text field on a creation form.
  final _course = TextEditingController();
  final _year = TextEditingController();
  final _batch = TextEditingController();
  final _officeRoom = TextEditingController();
  final _dateOfBirth = TextEditingController();
  final _address = TextEditingController();
  final _guardianName = TextEditingController();
  final _guardianRelation = TextEditingController();
  final _guardianPhone = TextEditingController();
  final _notes = TextEditingController();
  final _admissionYear = TextEditingController();
  final _section = TextEditingController();
  final _motherName = TextEditingController();
  final _category = TextEditingController();
  final _religion = TextEditingController();
  final _city = TextEditingController();
  final _pinCode = TextEditingController();
  final _permanentMobile = TextEditingController();

  String? _trade;
  int? _sem;
  String? _state;
  String? _bloodGroup;
  Set<String> _managedHostelIds = {};

  /// Once the admin edits the password themselves, stop overwriting it from
  /// the registration number.
  bool _passwordTouched = false;

  /// Null until a role is picked, which is the first thing this dialog asks.
  ///
  /// Not defaulted to the first role on purpose: the role decides which form
  /// you get, so silently pre-selecting one would mean an admin who never
  /// looked at the dropdown could fill in a staff form and create a student,
  /// or the reverse.
  AppRole? _role;
  String? _gender;
  bool _busy = false;
  String? _error;

  /// A student's academic and guardian fields, matching the CSV importer's
  /// columns — so a hand-added student carries the same detail as an imported
  /// one, and the two are comparable in every report.
  bool get _isResident => _role != null && Perm.isResident(_role!.permissions);

  /// Narrower than [_isResident]'s opposite: only hostel-operations staff get
  /// a "hostels managed" picker. An accountant is staff but manages no block.
  bool get _managesHostels =>
      _role != null && Perm.managesHostels(_role!.permissions);

  @override
  void dispose() {
    for (final c in [
      _name,
      _email,
      _password,
      _phone,
      _enrollment,
      _course,
      _year,
      _batch,
      _officeRoom,
      _dateOfBirth,
      _address,
      _guardianName,
      _guardianRelation,
      _guardianPhone,
      _notes,
      _admissionYear,
      _section,
      _motherName,
      _category,
      _religion,
      _city,
      _pinCode,
      _permanentMobile,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _val(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _role == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.createSubUser(
        name: _name.text,
        email: Identity.toAuthEmail(_email.text),
        // When they typed a registration number, that IS the enrollment no.
        enrollmentNo: Identity.looksLikeEmail(_email.text.trim())
            ? (_enrollment.text.trim().isEmpty ? null : _enrollment.text.trim())
            : _email.text.trim(),
        password: _password.text,
        collegeId: widget.collegeId,
        roleId: _role!.id,
        roleName: _role!.name,
        phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        gender: _gender,
        // Written strictly by the role's kind, not by whatever is still in the
        // controllers. Switching role mid-form keeps what you typed — helpful
        // if you switch back — but only the fields the chosen role's form
        // actually showed are ever saved.
        extra: {
          if (!_isResident) ...{
            if (_managesHostels) 'managedHostelIds': _managedHostelIds.toList(),
            'address': _val(_address),
          } else ...{
            'course': _val(_course),
            'year': _val(_year),
            'trade': _trade,
            'batch': _val(_batch),
            'sem': _sem,
            'state': _state ?? stateFromAddress(_val(_address)),
            'guardianName': _val(_guardianName),
            'guardianRelation': _val(_guardianRelation),
            'guardianPhone': _val(_guardianPhone),
            'address': _val(_address),
            'admissionYear': _val(_admissionYear),
            'section': _val(_section),
            'motherName': _val(_motherName),
            'category': _val(_category),
            'religion': _val(_religion),
            'city': _val(_city),
            'pinCode': _val(_pinCode),
            'permanentMobile': _val(_permanentMobile),
          },
          'officeRoom': _val(_officeRoom),
          'dateOfBirth': _val(_dateOfBirth),
          'bloodGroup': _bloodGroup,
          'notes': _val(_notes),
        }..removeWhere((_, v) => v == null),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = AuthService.describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_role == null ? 'Add a user' : 'Add a ${_role!.name}'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: _role == null
              ? _RoleChooser(
                  roles: widget.roles,
                  onPick: (r) => setState(() {
                    _role = r;
                    _error = null;
                  }),
                )
              : Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The chosen role, and a way back. Shown as a banner rather
                      // than a dropdown because changing it swaps the whole form.
                      _ChosenRole(
                        role: _role!,
                        isResident: _isResident,
                        onChange: _busy
                            ? null
                            : () => setState(() => _role = null),
                      ),
                      const SizedBox(height: 16),
                      if (_error != null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.dangerSoft,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: AppColors.danger,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      TextFormField(
                        controller: _name,
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          labelText: 'Full name',
                        ),
                        validator: (v) => (v == null || v.trim().length < 2)
                            ? 'Name is required'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _email,
                        enabled: !_busy,
                        // Keeps the password in step with the registration number,
                        // matching what the CSV importer does. That consistency is
                        // not cosmetic: in-app deletion works by reconstructing the
                        // derived password, so a hand-typed one leaves an
                        // undeletable sign-in account behind.
                        onChanged: (v) {
                          if (_passwordTouched) return;
                          final s = v.trim();
                          _password.text =
                              (s.isEmpty || Identity.looksLikeEmail(s))
                              ? ''
                              : Identity.derivedPassword(s);
                        },
                        decoration: const InputDecoration(
                          labelText: 'Registration number or email',
                          helperText:
                              'Students can use just a registration number — no '
                              'inbox needed.',
                        ),
                        validator: (v) {
                          final s = v?.trim() ?? '';
                          if (s.isEmpty) {
                            return 'A registration number or email is required';
                          }
                          if (Identity.looksLikeEmail(s)) {
                            if (!RegExp(
                              r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                            ).hasMatch(s)) {
                              return 'Enter a valid email address';
                            }
                          } else if (!Identity.isValidRegistrationNumber(s)) {
                            return 'Use letters, digits, . _ or - only';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        onChanged: (_) => _passwordTouched = true,
                        decoration: InputDecoration(
                          labelText: 'Temporary password',
                          helperText: _passwordTouched
                              ? 'Custom password — this account can only be fully '
                                    'deleted with tools/delete-students.js'
                              : 'Defaults to the registration number. Share it; '
                                    'they can change it later.',
                          helperMaxLines: 2,
                          helperStyle: TextStyle(
                            color: _passwordTouched
                                ? AppColors.warning
                                : AppColors.textMuted,
                          ),
                        ),
                        validator: (v) => (v == null || v.length < 6)
                            ? 'Use at least 6 characters'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _phone,
                              enabled: !_busy,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                labelText: 'Phone (optional)',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _gender,
                              decoration: const InputDecoration(
                                labelText: 'Gender (optional)',
                              ),
                              items: const ['Male', 'Female', 'Other']
                                  .map(
                                    (g) => DropdownMenuItem(
                                      value: g,
                                      child: Text(g),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() => _gender = v),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _enrollment,
                              enabled: !_busy,
                              decoration: const InputDecoration(
                                labelText:
                                    'Enrollment / Employee no. (optional)',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _dateOfBirth,
                              enabled: !_busy,
                              decoration: const InputDecoration(
                                labelText: 'Date of birth',
                                hintText: 'DD/MM/YYYY',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _bloodGroup,
                              decoration: const InputDecoration(
                                labelText: 'Blood group',
                              ),
                              items: kBloodGroups
                                  .map(
                                    (g) => DropdownMenuItem(
                                      value: g,
                                      child: Text(g),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() => _bloodGroup = v),
                            ),
                          ),
                        ],
                      ),
                      if (!_isResident) ...[
                        const SizedBox(height: 18),
                        _SectionLabel('Work'),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _officeRoom,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'Office / staff room (optional)',
                            hintText: 'Admin Block, Room 12',
                          ),
                        ),
                        if (_managesHostels) ...[
                          const SizedBox(height: 14),
                          Text(
                            'Hostels managed',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          HostelPickerChips(
                            hostels: widget.hostels,
                            selectedIds: _managedHostelIds,
                            enabled: !_busy,
                            onChanged: (v) =>
                                setState(() => _managedHostelIds = v),
                          ),
                        ],
                        const SizedBox(height: 18),
                        _SectionLabel('Optional details'),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _address,
                          enabled: !_busy,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'Address (optional)',
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _notes,
                          enabled: !_busy,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'Notes (optional)',
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 18),
                        _SectionLabel('Academic'),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _course,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                  labelText: 'Course',
                                  hintText: 'B.Tech CSE',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _year,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                  labelText: 'Year',
                                  hintText: '2nd',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                initialValue: _sem,
                                decoration: const InputDecoration(
                                  labelText: 'Semester',
                                ),
                                items: List.generate(8, (i) => i + 1)
                                    .map(
                                      (s) => DropdownMenuItem(
                                        value: s,
                                        child: Text('$s'),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() => _sem = v),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue:
                                    widget.settings.tradeCodes.contains(_trade)
                                    ? _trade
                                    : null,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Trade',
                                ),
                                items: widget.settings.tradeCodes
                                    .map(
                                      (t) => DropdownMenuItem(
                                        value: t,
                                        child: Text(
                                          widget.settings.tradeLabelFor(t),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() => _trade = v),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _batch,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                  labelText: 'Batch',
                                  hintText: '2023-24',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _admissionYear,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                  labelText: 'Admission year',
                                  hintText: '2023-24',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _section,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                  labelText: 'Section',
                                  hintText: 'Sec-A',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        _SectionLabel('Guardian & emergency contact'),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: _guardianName,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                  labelText: 'Guardian name',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _guardianRelation,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                  labelText: 'Relation',
                                  hintText: 'Father',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: _guardianPhone,
                                enabled: !_busy,
                                keyboardType: TextInputType.phone,
                                decoration: const InputDecoration(
                                  labelText: 'Guardian phone',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _motherName,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'Mother\'s name',
                          ),
                        ),
                        const SizedBox(height: 18),
                        _SectionLabel('Other'),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: _address,
                                enabled: !_busy,
                                maxLines: 2,
                                decoration: const InputDecoration(
                                  labelText: 'Permanent address',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: kIndianStates.contains(_state)
                                    ? _state
                                    : null,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Home state',
                                  helperText: 'Used by the fines dashboard',
                                ),
                                items: kIndianStates
                                    .map(
                                      (s) => DropdownMenuItem(
                                        value: s,
                                        child: Text(s),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() => _state = v),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _city,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                  labelText: 'City',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _pinCode,
                                enabled: !_busy,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'PIN code',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _category,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                  labelText: 'Category',
                                  hintText: 'GENERAL',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _religion,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                  labelText: 'Religion',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _permanentMobile,
                          enabled: !_busy,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            labelText: 'Permanent mobile (optional)',
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _notes,
                        enabled: !_busy,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Internal notes',
                          hintText: 'Only staff can see this',
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        if (_role != null)
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : Text('Create ${_role!.name}'),
          ),
      ],
    );
  }
}

/// Step one: which kind of user is this?
///
/// A list rather than a dropdown because the choice changes the entire form
/// that follows — a student is asked for a guardian and a registration
/// number, a warden is not — and that is worth seeing before you commit to it.
class _RoleChooser extends StatelessWidget {
  final List<AppRole> roles;
  final ValueChanged<AppRole> onPick;

  const _RoleChooser({required this.roles, required this.onPick});

  @override
  Widget build(BuildContext context) {
    if (roles.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 30),
        child: Text(
          'No assignable roles exist yet. Create one under Roles first.',
          style: TextStyle(color: AppColors.textMuted),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What kind of user is this? The form changes to match.',
          style: TextStyle(fontSize: 13, color: AppColors.textMuted),
        ),
        const SizedBox(height: 14),
        for (final r in roles) ...[
          _RoleOption(role: r, onTap: () => onPick(r)),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _RoleOption extends StatelessWidget {
  final AppRole role;
  final VoidCallback onTap;

  const _RoleOption({required this.role, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final resident = Perm.isResident(role.permissions);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(
              resident ? Icons.school_outlined : Icons.badge_outlined,
              size: 20,
              color: AppColors.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    role.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    resident
                        ? 'Full student record — academic, guardian and the '
                              'rest of the import fields'
                        : 'Staff account — contact details and what they '
                              'look after',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textMuted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

/// The role banner at the top of the filled-in form.
class _ChosenRole extends StatelessWidget {
  final AppRole role;
  final bool isResident;
  final VoidCallback? onChange;

  const _ChosenRole({
    required this.role,
    required this.isResident,
    this.onChange,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: AppColors.primarySoft,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        Icon(
          isResident ? Icons.school_outlined : Icons.badge_outlined,
          size: 18,
          color: AppColors.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            role.name,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
              color: AppColors.primary,
            ),
          ),
        ),
        TextButton(onPressed: onChange, child: const Text('Change role')),
      ],
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.9,
      color: AppColors.textMuted,
    ),
  );
}
