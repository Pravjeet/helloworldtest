import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/app_role.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';

/// Create roles and tick the modules each one may reach.
/// Whatever is ticked here is exactly what shows up in that user's sidebar.
class RolesPage extends StatelessWidget {
  const RolesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;
    final canManage = session.can(Perm.rolesManage);

    return StreamBuilder<List<AppRole>>(
      stream: DataService.instance.watchRoles(collegeId),
      builder: (context, snap) {
        if (snap.hasError) {
          return AppCard(child: Text(AuthService.describeError(snap.error!)));
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(60),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final roles = snap.data!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(
                    'Roles  (${roles.length})',
                    trailing: canManage
                        ? ElevatedButton.icon(
                            onPressed: () => _edit(context, collegeId, null),
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('New role'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 14,
                              ),
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'A role is just a bundle of permissions. Ticking a '
                    'permission makes the matching section appear in that '
                    'user\'s sidebar — there is no separate app to build per '
                    'role.',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13.5,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (context, c) {
                final columns = c.maxWidth > 1100
                    ? 3
                    : c.maxWidth > 700
                    ? 2
                    : 1;
                return GridView.count(
                  crossAxisCount: columns,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 1.55,
                  children: roles
                      .map(
                        (r) => _RoleCard(
                          role: r,
                          canManage: canManage,
                          onEdit: () => _edit(context, collegeId, r),
                          onDelete: () => _delete(context, collegeId, r),
                        ),
                      )
                      .toList(),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _edit(
    BuildContext context,
    String collegeId,
    AppRole? role,
  ) async {
    await showDialog(
      context: context,
      builder: (_) => _RoleEditorDialog(collegeId: collegeId, role: role),
    );
  }

  Future<void> _delete(
    BuildContext context,
    String collegeId,
    AppRole role,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete "${role.name}"?'),
        content: const Text(
          'Anyone currently holding this role will be left without one and '
          'will lose access until you assign them a new role.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await DataService.instance.deleteRole(collegeId, role);
      messenger.showSnackBar(const SnackBar(content: Text('Role deleted')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }
}

class _RoleCard extends StatelessWidget {
  final AppRole role;
  final bool canManage;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _RoleCard({
    required this.role,
    required this.canManage,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final modules = Perm.catalogue.entries
        .where((e) => e.value.any((p) => role.permissions.contains(p.key)))
        .map((e) => e.key)
        .toList();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  role.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (role.isSystem)
                StatusPill('SYSTEM', AppColors.textMuted, Color(0xFFF1F5F9)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            role.description.isEmpty ? 'No description.' : role.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: modules
                    .map(
                      (m) => StatusPill(
                        m,
                        AppColors.primary,
                        AppColors.primarySoft,
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '${role.permissions.length} permissions',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (canManage && !role.isSystem) ...[
                TextButton(onPressed: onEdit, child: const Text('Edit')),
                TextButton(
                  onPressed: onDelete,
                  child: Text(
                    'Delete',
                    style: TextStyle(color: AppColors.danger),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _RoleEditorDialog extends StatefulWidget {
  final String collegeId;
  final AppRole? role;
  const _RoleEditorDialog({required this.collegeId, this.role});

  @override
  State<_RoleEditorDialog> createState() => _RoleEditorDialogState();
}

class _RoleEditorDialogState extends State<_RoleEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _description;
  late Set<String> _selected;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.role?.name ?? '');
    _description = TextEditingController(text: widget.role?.description ?? '');
    _selected = {...?widget.role?.permissions};
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selected.isEmpty) {
      setState(() => _error = 'Tick at least one permission.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.role == null) {
        await DataService.instance.createRole(
          collegeId: widget.collegeId,
          name: _name.text,
          description: _description.text,
          permissions: _selected,
        );
      } else {
        await DataService.instance.updateRole(
          widget.collegeId,
          widget.role!.copyWith(
            name: _name.text.trim(),
            description: _description.text.trim(),
            permissions: _selected,
          ),
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.role == null ? 'New role' : 'Edit ${widget.role!.name}',
      ),
      content: SizedBox(
        width: 560,
        height: 520,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                    style: TextStyle(color: AppColors.danger, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              TextFormField(
                controller: _name,
                enabled: !_busy && widget.role == null,
                decoration: const InputDecoration(
                  labelText: 'Role name',
                  helperText: 'e.g. Warden, Caretaker, Mess Supervisor',
                ),
                validator: (v) => (v == null || v.trim().length < 2)
                    ? 'Role name is required'
                    : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _description,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    '${_selected.length} selected',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _selected = {...Perm.all}),
                    child: const Text('Select all'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _selected = {}),
                    child: const Text('Clear'),
                  ),
                ],
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  children: Perm.catalogue.entries.map((entry) {
                    return ExpansionTile(
                      initiallyExpanded: entry.value.any(
                        (p) => _selected.contains(p.key),
                      ),
                      title: Text(
                        entry.key,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        '${entry.value.where((p) => _selected.contains(p.key)).length}'
                        ' of ${entry.value.length}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      children: entry.value
                          .map(
                            (p) => CheckboxListTile(
                              dense: true,
                              value: _selected.contains(p.key),
                              title: Text(
                                p.label,
                                style: const TextStyle(fontSize: 13.5),
                              ),
                              subtitle: Text(
                                p.description,
                                style: const TextStyle(fontSize: 12),
                              ),
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() {
                                      if (v == true) {
                                        _selected.add(p.key);
                                      } else {
                                        _selected.remove(p.key);
                                      }
                                    }),
                            ),
                          )
                          .toList(),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              : const Text('Save role'),
        ),
      ],
    );
  }
}
