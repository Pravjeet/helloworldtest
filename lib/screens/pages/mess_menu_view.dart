import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/mess.dart';
import '../../services/auth_service.dart';
import '../../services/mess_service.dart';

/// The seven-day menu.
///
/// Shown a day at a time rather than as a 7x4 grid: the original printed sheet
/// is a wall of text, and the question a resident actually has is "what's for
/// dinner today", not "compare Tuesday and Friday". The day selector defaults
/// to today for that reason.
class MessMenuView extends StatefulWidget {
  final String collegeId;
  final MessConfig config;
  final bool canManage;

  const MessMenuView({
    super.key,
    required this.collegeId,
    required this.config,
    required this.canManage,
  });

  @override
  State<MessMenuView> createState() => _MessMenuViewState();
}

class _MessMenuViewState extends State<MessMenuView> {
  /// 1 = Monday … 7 = Sunday, matching `DateTime.weekday`.
  late int _day = DateTime.now().weekday;
  bool _seeding = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MessMenu>(
      stream: MessService.instance.watchMenu(widget.collegeId),
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

        final menu = snap.data!;
        if (menu.isEmpty) return _empty(context);

        final today = DateTime.now().weekday;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------------------- day selector ----------------------
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'DAY',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.9,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                      if (_day != today)
                        TextButton.icon(
                          onPressed: () => setState(() => _day = today),
                          icon: const Icon(Icons.today_rounded, size: 16),
                          label: const Text('Jump to today'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List.generate(7, (i) {
                      final weekday = i + 1;
                      final selected = weekday == _day;
                      final isToday = weekday == today;
                      return ChoiceChip(
                        label: Text(
                          isToday
                              ? '${kWeekdayNames[i]} · Today'
                              : kWeekdayNames[i],
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? AppColors.primary
                                : AppColors.textMuted,
                          ),
                        ),
                        selected: selected,
                        onSelected: (_) => setState(() => _day = weekday),
                        showCheckmark: false,
                        selectedColor: AppColors.primarySoft,
                        backgroundColor: Colors.white,
                        side: BorderSide(
                          color: selected
                              ? AppColors.primary
                              : isToday
                              ? AppColors.info
                              : AppColors.border,
                        ),
                      );
                    }),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // ------------------------- meals -------------------------
            ...Meal.values.map(
              (meal) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _MealCard(
                  meal: meal,
                  timing: widget.config.timingFor(meal),
                  text: menu.item(_day, meal),
                  canManage: widget.canManage,
                  onEdit: () => _edit(menu, meal),
                ),
              ),
            ),

            // ------------------------- notes -------------------------
            if (menu.notes.isNotEmpty) ...[
              const SizedBox(height: 4),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GOOD TO KNOW',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.9,
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...menu.notes.map(
                      (n) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: EdgeInsets.only(top: 5, right: 10),
                              child: Icon(
                                Icons.circle,
                                size: 5,
                                color: AppColors.textMuted,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                n,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.5,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (menu.updatedAt != null) ...[
              const SizedBox(height: 12),
              Text(
                'Last updated ${_formatDate(menu.updatedAt!)}'
                '${menu.updatedByName != null ? ' by ${menu.updatedByName}' : ''}',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ],
        );
      },
    );
  }

  // --------------------------- empty state ---------------------------

  Widget _empty(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.restaurant_menu_rounded,
              size: 40,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 14),
            const Text(
              'No menu has been published yet.',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              widget.canManage
                  ? 'Start from the standard institute menu, then edit any '
                        'meal to match your mess.'
                  : 'Your mess manager hasn\'t published the menu yet.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textMuted,
                height: 1.5,
              ),
            ),
            if (widget.canManage) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _seeding ? null : _seed,
                icon: _seeding
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.auto_awesome_rounded, size: 17),
                label: const Text('Use the standard menu'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _seed() async {
    setState(() => _seeding = true);
    final messenger = ScaffoldMessenger.of(context);
    final me = Session.of(context).user;
    try {
      await MessService.instance.seedDefaultMenu(
        widget.collegeId,
        byName: me.name,
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Menu published — edit any meal to '
            'match your mess',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    } finally {
      if (mounted) setState(() => _seeding = false);
    }
  }

  // ------------------------------ editing ------------------------------

  Future<void> _edit(MessMenu menu, Meal meal) async {
    final me = Session.of(context).user;
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController(text: menu.item(_day, meal) ?? '');

    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${weekdayName(_day)} · ${meal.label}'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 8,
            minLines: 4,
            decoration: const InputDecoration(
              labelText: 'What is served',
              hintText: 'One item per line',
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;

    try {
      await MessService.instance.saveMeal(
        widget.collegeId,
        _day,
        meal,
        value,
        byName: me.name,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('${weekdayName(_day)} ${meal.label} updated')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }

  static String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}

// ------------------------------ meal card ------------------------------

class _MealCard extends StatelessWidget {
  final Meal meal;
  final String timing;
  final String? text;
  final bool canManage;
  final VoidCallback onEdit;

  const _MealCard({
    required this.meal,
    required this.timing,
    required this.text,
    required this.canManage,
    required this.onEdit,
  });

  IconData get _icon => switch (meal) {
    Meal.breakfast => Icons.free_breakfast_rounded,
    Meal.lunch => Icons.lunch_dining_rounded,
    Meal.eveningTea => Icons.emoji_food_beverage_rounded,
    Meal.dinner => Icons.dinner_dining_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final isSpecial = (text ?? '').toUpperCase().contains('SPECIAL');

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: isSpecial
                      ? AppColors.warningSoft
                      : AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _icon,
                  size: 19,
                  color: isSpecial ? AppColors.warning : AppColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          meal.label,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (isSpecial) ...[
                          const SizedBox(width: 8),
                          StatusPill(
                            'SPECIAL',
                            AppColors.warning,
                            AppColors.warningSoft,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      timing,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              if (canManage)
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: 'Edit this meal',
                ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.canvas,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              text ?? 'Not set yet.',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.6,
                color: text == null
                    ? AppColors.textMuted
                    : AppColors.textStrong,
                fontStyle: text == null ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
