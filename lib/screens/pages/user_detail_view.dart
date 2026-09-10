import 'package:flutter/material.dart';

import '../../core/identity.dart';
import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/app_role.dart';
import '../../models/app_user.dart';
import '../../models/fine.dart';
import '../../models/hostel.dart';
import '../../models/office_order.dart';
import '../../services/allotment_service.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/fine_service.dart';
import '../../services/hostel_service.dart';
import '../../services/office_order_service.dart';
import '../../widgets/hostel_picker_chips.dart';
import 'allot_room_view.dart';
import 'fines_shared.dart' show FineRow, compactAmount;
import 'impose_fine_view.dart';
import 'office_orders_page.dart' show OfficeOrderThumb, OfficeOrderViewer;

/// The full record for one person: everything that wasn't asked for at
/// account creation, plus their room.
///
/// Account creation deliberately stays minimal — name, email, password, role.
/// Everything else is optional detail you fill in when you have it, which is
/// what this screen is for.
///
/// Rendered as a drill-down *inside* the dashboard shell (same pattern as
/// [HostelDetailView]) rather than a dialog, so the sidebar stays visible and
/// there is room for the full form.
class UserDetailView extends StatefulWidget {
  final String uid;
  final AppUser initial;
  final VoidCallback onBack;

  const UserDetailView({
    super.key,
    required this.uid,
    required this.initial,
    required this.onBack,
  });

  @override
  State<UserDetailView> createState() => _UserDetailViewState();
}

class _UserDetailViewState extends State<UserDetailView> {
  /// Non-null while the allot/move picker is showing in place of the details.
  bool? _allotIsMove;

  /// True while the impose-fine form is showing in place of the details.
  bool _imposingFine = false;

  @override
  Widget build(BuildContext context) {
    // Watch the document so the room card and header stay live while the form
    // is open — allotting a room updates this page without a reload.
    return StreamBuilder<AppUser?>(
      stream: AuthService.instance.watchProfile(widget.uid),
      initialData: widget.initial,
      builder: (context, snap) {
        final user = snap.data;
        if (user == null) {
          return AppCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('This user no longer exists.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: widget.onBack,
                  child: const Text('Back to users'),
                ),
              ],
            ),
          );
        }

        if (_allotIsMove != null) {
          return AllotRoomView(
            student: user,
            isMove: _allotIsMove!,
            onBack: () => setState(() => _allotIsMove = null),
            onDone: () => setState(() => _allotIsMove = null),
          );
        }

        if (_imposingFine) {
          return ImposeFineView(
            student: user,
            onBack: () => setState(() => _imposingFine = false),
            onDone: () => setState(() => _imposingFine = false),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(user: user, onBack: widget.onBack),
            const SizedBox(height: 18),
            _RoomSection(
              user: user,
              onAllot: (move) => setState(() => _allotIsMove = move),
            ),
            const SizedBox(height: 18),
            _FinesSection(
              user: user,
              onImpose: () => setState(() => _imposingFine = true),
            ),
            const SizedBox(height: 18),
            _OfficeOrdersSection(user: user),
            const SizedBox(height: 18),
            // Keyed on uid so switching users rebuilds the controllers with
            // the new person's values instead of keeping the old text.
            _DetailForm(
              key: ValueKey(widget.uid),
              user: user,
              onDone: widget.onBack,
            ),
          ],
        );
      },
    );
  }
}

// -------------------------------- header --------------------------------

class _Header extends StatelessWidget {
  final AppUser user;
  final VoidCallback onBack;
  const _Header({required this.user, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Back to users',
          ),
          const SizedBox(width: 4),
          CircleAvatar(
            radius: 24,
            backgroundColor: AppColors.primarySoft,
            child: Text(
              user.initials,
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.name,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${Identity.display(user.email)} · ${user.displayRole}',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (!user.isActive)
            StatusPill(
              'DISABLED',
              AppColors.danger,
              AppColors.dangerSoft,
            ),
        ],
      ),
    );
  }
}

// -------------------------------- fines --------------------------------

/// This student's fine history, on their own record.
///
/// Shown to anyone who can see all fines (staff triaging a student) and to the
/// student themselves. Reuses [FineRow] from the fines page so a fine looks
/// and behaves identically wherever it appears.
class _FinesSection extends StatelessWidget {
  final AppUser user;
  final VoidCallback onImpose;

  const _FinesSection({required this.user, required this.onImpose});

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;
    final canManage = session.can(Perm.finesManage);
    final isSelf = session.user.uid == user.uid;

    if (!session.can(Perm.finesViewAll) && !isSelf) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<List<Fine>>(
      stream: FineService.instance.watchMine(collegeId, user.uid),
      builder: (context, snap) {
        if (snap.hasError) {
          return AppCard(child: Text(AuthService.describeError(snap.error!)));
        }

        final fines = snap.data ?? const <Fine>[];
        final summary = FineSummary(fines);

        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                'Fines',
                trailing: canManage
                    ? OutlinedButton.icon(
                        onPressed: onImpose,
                        icon: const Icon(Icons.gavel_rounded, size: 17),
                        label: const Text('Impose fine'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 13,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: 14),
              if (!snap.hasData)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (fines.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    isSelf
                        ? 'You have no fines.'
                        : '${user.name.split(' ').first} has no fines.',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13.5,
                    ),
                  ),
                )
              else ...[
                Wrap(
                  spacing: 30,
                  runSpacing: 12,
                  children: [
                    _FineStat(
                      'Still owed',
                      '₹${compactAmount(summary.outstanding)}',
                      summary.outstanding == 0
                          ? AppColors.success
                          : AppColors.danger,
                    ),
                    _FineStat(
                      'Total imposed',
                      '₹${compactAmount(summary.total)}',
                      AppColors.textStrong,
                    ),
                    _FineStat(
                      'Paid',
                      '₹${compactAmount(summary.collected)}',
                      AppColors.success,
                    ),
                    _FineStat('Count', '${summary.count}', AppColors.primary),
                  ],
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < fines.length; i++) ...[
                  if (i != 0)
                    Divider(height: 1, color: AppColors.border),
                  Padding(
                    // FineRow brings its own horizontal padding, which would
                    // double up inside a card that already has some.
                    padding: const EdgeInsets.symmetric(horizontal: 0),
                    child: FineRow(
                      fine: fines[i],
                      showWho: false,
                      canManage: canManage,
                      collegeId: collegeId,
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------- office orders -----------------------------

/// The disciplinary orders issued for this student's fines, on their own
/// record. Every order shown here was created alongside a fine — see
/// [ImposeFineView] — so there is exactly one row per fine that had one.
class _OfficeOrdersSection extends StatelessWidget {
  final AppUser user;

  const _OfficeOrdersSection({required this.user});

  Future<void> _open(BuildContext context, OfficeOrder order) async {
    final bytes = decodedOrderImage(order);
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That photo could not be read')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.86),
      builder: (_) => OfficeOrderViewer(order: order, bytes: bytes),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;
    final isSelf = session.user.uid == user.uid;

    if (!session.can(Perm.officeOrdersView) && !isSelf) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<List<OfficeOrder>>(
      stream: OfficeOrderService.instance.watchForStudent(collegeId, user.uid),
      builder: (context, snap) {
        if (snap.hasError) {
          return AppCard(child: Text(AuthService.describeError(snap.error!)));
        }

        final orders = snap.data ?? const <OfficeOrder>[];

        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('Office Orders'),
              const SizedBox(height: 14),
              if (!snap.hasData)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (orders.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    isSelf
                        ? 'No office orders have been issued against you.'
                        : '${user.name.split(' ').first} has no office '
                              'orders.',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13.5,
                    ),
                  ),
                )
              else
                for (var i = 0; i < orders.length; i++) ...[
                  if (i != 0) Divider(height: 1, color: AppColors.border),
                  InkWell(
                    onTap: () => _open(context, orders[i]),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          OfficeOrderThumb(order: orders[i], size: 36),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  orders[i].title.isEmpty
                                      ? orders[i].orderNo
                                      : orders[i].title,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  [
                                    if (orders[i].orderNo.isNotEmpty)
                                      orders[i].orderNo,
                                    if (orders[i].dateLabel != null)
                                      orders[i].dateLabel!,
                                    // This student's own share of the order,
                                    // not its total. On a group order the
                                    // others may have paid more, less, or
                                    // nothing, and none of that is their bill.
                                    if (orders[i].amountFor(user.uid) != null)
                                      '₹${orders[i].amountFor(user.uid)} · '
                                          '${orders[i].fineCategory ?? ''}',
                                  ].join(' · '),
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.zoom_in_rounded,
                            size: 16,
                            color: AppColors.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
            ],
          ),
        );
      },
    );
  }
}

class _FineStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _FineStat(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: AppColors.textMuted,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    ],
  );
}

// --------------------------------- form ---------------------------------

class _DetailForm extends StatefulWidget {
  final AppUser user;
  final VoidCallback onDone;
  const _DetailForm({super.key, required this.user, required this.onDone});

  @override
  State<_DetailForm> createState() => _DetailFormState();
}

class _DetailFormState extends State<_DetailForm> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _c;

  String? _gender;
  String? _bloodGroup;
  String? _trade;
  int? _sem;
  bool _singleRoomEligible = false;
  String? _state;
  late Set<String> _managedHostelIds;
  bool _busy = false;
  String? _error;

  /// Cached from the most recent build, so [_save] — called from a button
  /// callback, not from inside the stream builder — knows which section was
  /// actually on screen when the user hit save.
  bool _currentManagesHostels = false;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _managedHostelIds = u.managedHostelIds.toSet();
    _c = {
      'name': TextEditingController(text: u.name),
      'phone': TextEditingController(text: u.phone ?? ''),
      'enrollmentNo': TextEditingController(text: u.enrollmentNo ?? ''),
      'course': TextEditingController(text: u.course ?? ''),
      'year': TextEditingController(text: u.year ?? ''),
      'batch': TextEditingController(text: u.batch ?? ''),
      'officeRoom': TextEditingController(text: u.officeRoom ?? ''),
      'dateOfBirth': TextEditingController(text: u.dateOfBirth ?? ''),
      'address': TextEditingController(text: u.address ?? ''),
      'guardianName': TextEditingController(text: u.guardianName ?? ''),
      'guardianPhone': TextEditingController(text: u.guardianPhone ?? ''),
      'guardianRelation': TextEditingController(text: u.guardianRelation ?? ''),
      'notes': TextEditingController(text: u.notes ?? ''),
    };
    _gender = u.gender;
    _bloodGroup = u.bloodGroup;
    _trade = u.trade;
    _sem = u.sem;
    _singleRoomEligible = u.singleRoomEligible;
    // Fall back to whatever the address already says, so an existing student
    // shows their state without anyone re-entering it.
    _state = u.state ?? stateFromAddress(u.address);
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _val(String key) {
    final t = _c[key]!.text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await DataService.instance.updateUser(widget.user.uid, {
        'name': _c['name']!.text.trim(),
        'phone': _val('phone'),
        'gender': _gender,
        'enrollmentNo': _val('enrollmentNo'),
        if (_currentManagesHostels)
          'managedHostelIds': _managedHostelIds.toList()
        else ...{
          'course': _val('course'),
          'year': _val('year'),
          'trade': _trade,
          'batch': _val('batch'),
          'sem': _sem,
          'singleRoomEligible': _singleRoomEligible,
          'state': _state,
          'address': _val('address'),
          'guardianName': _val('guardianName'),
          'guardianPhone': _val('guardianPhone'),
          'guardianRelation': _val('guardianRelation'),
        },
        'officeRoom': _val('officeRoom'),
        'dateOfBirth': _val('dateOfBirth'),
        'bloodGroup': _bloodGroup,
        'notes': _val('notes'),
      });
      messenger.showSnackBar(const SnackBar(content: Text('Details saved')));
    } catch (e) {
      if (mounted) setState(() => _error = AuthService.describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    if (u.roleId == null) {
      return _buildCard(context, managesHostels: false, hostels: const []);
    }
    return StreamBuilder<AppRole?>(
      stream: AuthService.instance.watchRole(u.collegeId, u.roleId!),
      builder: (context, roleSnap) {
        final managesHostels = roleSnap.data != null &&
            Perm.managesHostels(roleSnap.data!.permissions);
        if (!managesHostels) {
          return _buildCard(context, managesHostels: false, hostels: const []);
        }
        return StreamBuilder<List<Hostel>>(
          stream: HostelService.instance.watchHostels(u.collegeId),
          builder: (context, hostelSnap) => _buildCard(
            context,
            managesHostels: true,
            hostels: hostelSnap.data ?? const [],
          ),
        );
      },
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required bool managesHostels,
    required List<Hostel> hostels,
  }) {
    _currentManagesHostels = managesHostels;
    final session = Session.of(context);
    final canEdit = session.can(Perm.usersEdit);
    final on = canEdit && !_busy;
    final tradeCodes = session.settings.tradeCodes;

    return AppCard(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(canEdit ? 'Edit details' : 'Details'),
            const SizedBox(height: 18),

            if (_error != null) ...[
              _ErrorBox(_error!),
              const SizedBox(height: 16),
            ],

            const _SectionLabel('Personal'),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _Field(
                    _c['name']!,
                    'Full name',
                    enabled: on,
                    validator: (v) => (v == null || v.trim().length < 2)
                        ? 'Name is required'
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Field(
                    _c['phone']!,
                    'Phone',
                    enabled: on,
                    keyboard: TextInputType.phone,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: DropdownButtonFormField<String>(
                      initialValue: _gender,
                      decoration: const InputDecoration(
                        labelText: 'Gender',
                        helperText: 'Used for hostel eligibility',
                      ),
                      items: const ['Male', 'Female', 'Other']
                          .map(
                            (g) => DropdownMenuItem(value: g, child: Text(g)),
                          )
                          .toList(),
                      onChanged: on ? (v) => setState(() => _gender = v) : null,
                    ),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: _Field(
                    _c['dateOfBirth']!,
                    'Date of birth',
                    hint: 'DD/MM/YYYY',
                    enabled: on,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: DropdownButtonFormField<String>(
                      initialValue: _bloodGroup,
                      decoration: const InputDecoration(
                        labelText: 'Blood group',
                      ),
                      items:
                          const ['A+', 'A-', 'B+', 'B-', 'O+', 'O-', 'AB+', 'AB-']
                              .map(
                                (g) =>
                                    DropdownMenuItem(value: g, child: Text(g)),
                              )
                              .toList(),
                      onChanged: on
                          ? (v) => setState(() => _bloodGroup = v)
                          : null,
                    ),
                  ),
                ),
                const Spacer(),
              ],
            ),

            const SizedBox(height: 8),
            _SectionLabel(managesHostels ? 'Work' : 'Academic'),
            Row(
              children: [
                Expanded(
                  child: _Field(
                    _c['enrollmentNo']!,
                    'Enrollment / Employee no.',
                    enabled: on,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: _Field(
                    _c['officeRoom']!,
                    'Office / staff room',
                    hint: 'Admin Block, Room 12',
                    enabled: on,
                  ),
                ),
              ],
            ),
            if (managesHostels) ...[
              const SizedBox(height: 4),
              const Text(
                'Hostels managed',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              HostelPickerChips(
                hostels: hostels,
                selectedIds: _managedHostelIds,
                enabled: on,
                onChanged: (v) => setState(() => _managedHostelIds = v),
              ),
              const SizedBox(height: 18),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: _Field(
                      _c['course']!,
                      'Course',
                      hint: 'B.Tech CSE',
                      enabled: on,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Field(
                      _c['year']!,
                      'Year',
                      hint: '2nd',
                      enabled: on,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: DropdownButtonFormField<String>(
                        initialValue: tradeCodes.contains(_trade)
                            ? _trade
                            : null,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Trade'),
                        items: tradeCodes
                            .map(
                              (t) => DropdownMenuItem(
                                value: t,
                                child: Text(
                                  session.settings.tradeLabelFor(t),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: on
                            ? (v) => setState(() => _trade = v)
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Field(
                      _c['batch']!,
                      'Batch',
                      hint: '2023-24',
                      enabled: on,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14),
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
                        onChanged: on ? (v) => setState(() => _sem = v) : null,
                      ),
                    ),
                  ),
                ],
              ),

              Container(
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: AppColors.canvas,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SwitchListTile(
                  value: _singleRoomEligible,
                  onChanged: on
                      ? (v) => setState(() => _singleRoomEligible = v)
                      : null,
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  title: const Text(
                    'Single-room eligible',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    'Earned by scoring well in 2nd year. Only affects a B.E. '
                    'student in year 3+ — Diploma and year 1/2 are always '
                    '3-Seater, and M.Tech/M.Sc/PhD are always Single, either '
                    'way. Once set, they keep the room until graduation.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                      height: 1.35,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 8),
              const _SectionLabel('Guardian & emergency contact'),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _Field(
                      _c['guardianName']!,
                      'Guardian name',
                      enabled: on,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Field(
                      _c['guardianRelation']!,
                      'Relation',
                      hint: 'Father',
                      enabled: on,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: _Field(
                      _c['guardianPhone']!,
                      'Guardian phone',
                      enabled: on,
                      keyboard: TextInputType.phone,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 8),
              const _SectionLabel('Other'),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _Field(
                      _c['address']!,
                      'Permanent address',
                      enabled: on,
                      lines: 2,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14),
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
                              (s) =>
                                  DropdownMenuItem(value: s, child: Text(s)),
                            )
                            .toList(),
                        onChanged: on
                            ? (v) => setState(() => _state = v)
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            _Field(
              _c['notes']!,
              'Internal notes',
              hint: 'Only staff can see this',
              enabled: on,
              lines: 2,
            ),

            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : widget.onDone,
                  child: Text(canEdit ? 'Cancel' : 'Back'),
                ),
                if (canEdit) ...[
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 16,
                      ),
                    ),
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Save details'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------ room section ------------------------------

/// Live room status for this user, with allot / move / vacate actions.
class _RoomSection extends StatelessWidget {
  final AppUser user;

  /// `true` = relocate an already-allotted student, `false` = first allotment.
  final ValueChanged<bool> onAllot;

  const _RoomSection({required this.user, required this.onAllot});

  @override
  Widget build(BuildContext context) {
    final canAllot = Session.of(context).can(Perm.allotmentManage);
    final u = user;

    return AppCard(
      child: Row(
        children: [
          Icon(
            u.isAllotted
                ? Icons.meeting_room_rounded
                : Icons.no_meeting_room_rounded,
            color: u.isAllotted ? AppColors.success : AppColors.textMuted,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  u.isAllotted ? u.roomLabel! : 'No room allotted',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  u.isAllotted
                      ? 'Allotted room'
                      : 'This person hasn\'t been given a bed yet.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (canAllot && !u.isSuperAdmin) ...[
            if (u.isAllotted) ...[
              TextButton(
                onPressed: () => onAllot(true),
                child: const Text('Change room'),
              ),
              TextButton(
                onPressed: () => _vacate(context, u),
                child: Text(
                  'Vacate',
                  style: TextStyle(color: AppColors.danger),
                ),
              ),
            ] else
              FilledButton(
                onPressed: () => onAllot(false),
                child: const Text('Allot room'),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _vacate(BuildContext context, AppUser u) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Vacate ${u.roomLabel}?'),
        content: Text(
          '${u.name} will be removed from the room and the bed freed up.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Vacate'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await AllotmentService.instance.vacate(collegeId: u.collegeId, student: u);
      messenger.showSnackBar(const SnackBar(content: Text('Room vacated')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_describe(e))));
    }
  }

  static String _describe(Object e) =>
      e is AllotmentFailure ? e.message : AuthService.describeError(e);
}

// ------------------------------ small pieces ------------------------------

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.9,
        color: AppColors.textMuted,
      ),
    ),
  );
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool enabled;
  final int lines;
  final TextInputType? keyboard;
  final String? Function(String?)? validator;

  const _Field(
    this.controller,
    this.label, {
    this.hint,
    this.enabled = true,
    this.lines = 1,
    this.keyboard,
    this.validator,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      controller: controller,
      enabled: enabled,
      maxLines: lines,
      keyboardType: keyboard,
      validator: validator,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}

class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox(this.message);

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.dangerSoft,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      message,
      style: TextStyle(color: AppColors.danger, fontSize: 13),
    ),
  );
}
