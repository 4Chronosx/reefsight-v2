import 'package:flutter/material.dart';

import 'constants/app_colors.dart';
import 'constants/app_typography.dart';
import 'screens/splash_screen.dart';

void main() {
  runApp(const ReefSightApp());
}

class ReefSightApp extends StatelessWidget {
  const ReefSightApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primary),
    );
    return MaterialApp(
      title: 'ReefSight',
      theme: baseTheme.copyWith(
        textTheme: AppTypography.textTheme(baseTheme.textTheme),
      ),
      home: const SplashScreen(),
    );
  }
}
