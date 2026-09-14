import 'package:flutter/material.dart';

import 'screens/live_transect_screen.dart';

void main() {
  runApp(const ReefSightApp());
}

class ReefSightApp extends StatelessWidget {
  const ReefSightApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ReefSight',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      home: const LiveTransectScreen(),
    );
  }
}
