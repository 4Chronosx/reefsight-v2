import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import 'home_screen.dart';

/// Sub-plan 5 task 7. Adapted from v1's `splash_screen.dart` -- a brief
/// branded launch screen, auto-advancing to Home. v1 timed this off asset
/// loading it no longer needs here (this project's model assets load
/// lazily per-screen, not at app start), so this uses a short fixed delay
/// instead.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: const Center(
        child: Icon(Icons.water, color: Colors.white, size: 96),
      ),
    );
  }
}
