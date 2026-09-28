import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/app_shell.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';

/// Sub-plan 6 (ui-ux-overhaul), decision 7: the Live screen is the only
/// landscape-locked screen; every other screen is portrait. Setting the
/// app-wide default here means a screen that never touches
/// `SystemChrome.setPreferredOrientations` (i.e. every screen except Live)
/// just gets portrait for free, and Live's own lock/restore
/// (`live_transect_screen.dart`) only has to override this default
/// temporarily rather than every other screen having to assert it.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const ReefSightApp());
}

class ReefSightApp extends StatelessWidget {
  const ReefSightApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ReefSight',
      theme: AppTheme.build(),
      navigatorObservers: [routeObserver],
      home: const SplashScreen(),
    );
  }
}
