import 'package:flutter/material.dart';

import 'app_shell.dart';

/// Sub-plan 6 (ui-ux-overhaul), step 3: branding, not a loading screen --
/// models load lazily on Live, not at app start, so this times off a fixed
/// ~1.5 s fade rather than any asset-ready signal. Follows v1's
/// `splash_screen.dart` (white background, `full_logo.png` fading in) and
/// this project's own prior `splash_screen.dart` (a fixed delay then a fade
/// transition), now landing on [AppShell] instead of the old bare
/// `HomeScreen` push.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
    Future.delayed(const Duration(milliseconds: 1500), _navigate);
  }

  void _navigate() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: AppShell.routeName),
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, _, _) => const AppShell(),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Align(
        alignment: const Alignment(0, 0.25),
        child: FadeTransition(
          opacity: _fade,
          child: Image.asset('assets/images/full_logo.png', width: width * 0.68),
        ),
      ),
    );
  }
}
