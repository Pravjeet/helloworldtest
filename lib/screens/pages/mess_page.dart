import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/mess.dart';
import '../../services/auth_service.dart';
import '../../services/mess_service.dart';
import 'mess_fees_view.dart';
import 'mess_menu_view.dart';

/// The mess module: what's being served, and what it costs.
///
/// Two tabs rather than two sidebar entries — a student thinking about the
/// mess is thinking about one thing, and the fee calculator only makes sense
/// next to the menu it's paying for.
class MessPage extends StatefulWidget {
  const MessPage({super.key});

  @override
  State<MessPage> createState() => _MessPageState();
}

class _MessPageState extends State<MessPage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;
    final canManage = session.can(Perm.messManage);

    return StreamBuilder<MessConfig>(
      stream: MessService.instance.watchConfig(collegeId),
      builder: (context, configSnap) {
        if (configSnap.hasError) {
          return AppCard(
            child: Text(AuthService.describeError(configSnap.error!)),
          );
        }
        final config = configSnap.data ?? const MessConfig();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader('Mess'),
                  const SizedBox(height: 4),
                  Text(
                    'The weekly menu, and what a month of it costs.',
                    style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _Tab(
                        label: 'Weekly Menu',
                        icon: Icons.restaurant_menu_rounded,
                        selected: _tab == 0,
                        onTap: () => setState(() => _tab = 0),
                      ),
                      const SizedBox(width: 10),
                      _Tab(
                        label: 'Fees & Calculator',
                        icon: Icons.calculate_rounded,
                        selected: _tab == 1,
                        onTap: () => setState(() => _tab = 1),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (_tab == 0)
              MessMenuView(
                collegeId: collegeId,
                config: config,
                canManage: canManage,
              )
            else
              MessFeesView(
                collegeId: collegeId,
                config: config,
                canManage: canManage,
              ),
          ],
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _Tab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? AppColors.primarySoft : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 17,
              color: selected ? AppColors.primary : AppColors.textMuted,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? AppColors.primary : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
