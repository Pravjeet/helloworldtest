import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Honest placeholder for modules that are wired into navigation and
/// permissions but not yet implemented.
class ComingSoonPage extends StatelessWidget {
  final String title;
  final IconData icon;
  final String blurb;

  const ComingSoonPage({
    super.key,
    required this.title,
    required this.icon,
    required this.blurb,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 70, horizontal: 28),
      child: Column(
        children: [
          Container(
            height: 64,
            width: 64,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, size: 30, color: AppColors.primary),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              blurb,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 18),
          StatusPill(
            'NOT BUILT YET',
            AppColors.warning,
            AppColors.warningSoft,
          ),
        ],
      ),
    );
  }
}
