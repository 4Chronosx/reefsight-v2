import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// The white rounded "ReefSight / Coral Reef Health Monitor" badge over the
/// Home hero photo -- ported from v1's `home_screen.dart`'s private
/// `_LogoBadge` (sub-plan 6, ui-ux-overhaul, step 1).
class LogoBadge extends StatelessWidget {
  const LogoBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child:
                Image.asset('assets/icon/app_icon.png', fit: BoxFit.contain),
          ),
          const SizedBox(width: 12),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ReefSight',
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                  height: 1.1,
                ),
              ),
              Text(
                'Coral Reef Health Monitor',
                style: TextStyle(
                  color: AppColors.secondary,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
