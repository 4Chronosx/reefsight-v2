import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'station_edit_screen.dart';
import 'surveys_screen.dart';
import 'transect_setup_screen.dart';

/// Registered on `MaterialApp.navigatorObservers` (`main.dart`) so
/// [AppShell] can subscribe as a [RouteAware] and learn when a pushed route
/// above it (Setup/Live/Summary) is popped back to it -- that's how the
/// Home/Surveys tabs know to reload after a survey finishes, without Summary
/// or Live needing a callback threaded all the way back down (sub-plan 6
/// step 4: "Refresh the list when the tab is re-selected and after
/// returning from a survey").
final routeObserver = RouteObserver<PageRoute<void>>();

/// Sub-plan 6 (ui-ux-overhaul), step 3, decision 1: a three-tab bottom
/// navigation shell (Home, Surveys, Settings) with a raised centre "Start
/// Survey" action that goes straight to Transect Setup. Before this sub-plan
/// the app had no navigation structure at all -- Splash -> Home -> Setup ->
/// Live -> Summary was the only path, and a past survey could never be
/// reopened (`TransectDatabase` had no `listSessions`, and nothing in the UI
/// called it if it had).
///
/// Setup, Live, and Summary are pushed as full-screen routes on top of this
/// shell, not tabs -- decision 1: "The shell is hidden during Setup, Live,
/// and Summary ... so nothing can be mis-tapped mid-dive." `IndexedStack`
/// keeps Home/Surveys/Settings state alive across tab switches.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// Named so `Navigator.popUntil(ModalRoute.withName(AppShell.routeName))`
  /// (Summary's "Done" button, step 4) can return here regardless of how
  /// deep the stack is, and so the Live-end handoff can
  /// `pushAndRemoveUntil` down to this exact route instead of Setup.
  static const routeName = '/shell';

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with RouteAware {
  int _index = 0;

  /// Bumped whenever a DB-reading tab should reload. `HomeScreen` and
  /// `SurveysScreen` both take this as a constructor parameter and reload
  /// their own `FutureBuilder` in `didUpdateWidget` when it changes --
  /// simpler than plumbing a `ChangeNotifier` through `IndexedStack` for two
  /// screens that only ever need "reload now".
  int _dataRevision = 0;

  void _refreshData() => setState(() => _dataRevision++);

  void _openSurveysTab() => setState(() => _index = 1);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  /// Called when a route pushed on top of this shell (Setup, or the
  /// Setup -> Live -> Summary chain) is popped back to it -- refresh so a
  /// just-finished survey shows up without the diver having to manually
  /// switch tabs.
  @override
  void didPopNext() => _refreshData();

  /// Issue #2: surveys now start from a station. The quick transect (the
  /// pre-station flow, saved under Unassigned) stays one tap away, so the
  /// field team can keep using it while stations are new.
  Future<void> _chooseStart() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_location_alt_outlined),
              title: const Text('New station'),
              subtitle: const Text('3-5 transects, TB 2019-04'),
              onTap: () => Navigator.of(context).pop('station'),
            ),
            ListTile(
              leading: const Icon(Icons.straighten_rounded),
              title: const Text('Quick transect (no station)'),
              subtitle: const Text('Colony count, saved under Unassigned'),
              onTap: () => Navigator.of(context).pop('quick'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'station':
        await createStation(context);
      case 'quick':
        await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => const TransectSetupScreen()),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      HomeScreen(
        dataRevision: _dataRevision,
        onSeeAllSurveys: _openSurveysTab,
      ),
      SurveysScreen(dataRevision: _dataRevision, onDataChanged: _refreshData),
      const SettingsScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: screens),
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        color: AppColors.surface,
        child: SizedBox(
          height: 64,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                icon: Icons.home_rounded,
                label: 'Home',
                selected: _index == 0,
                onTap: () => setState(() => _index = 0),
              ),
              _NavItem(
                icon: Icons.list_alt_rounded,
                label: 'Surveys',
                selected: _index == 1,
                onTap: () => setState(() => _index = 1),
              ),
              const SizedBox(width: 56), // reserved space for the FAB notch
              _NavItem(
                icon: Icons.settings_rounded,
                label: 'Settings',
                selected: _index == 2,
                onTap: () => setState(() => _index = 2),
              ),
            ],
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primary,
        tooltip: 'Start Transect Survey',
        onPressed: _chooseStart,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color =
        selected ? AppColors.primary : AppColors.onSurface.withValues(alpha: 0.6);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        width: 64,
        child: FittedBox(
          // Guards against the label + icon's intrinsic height exceeding
          // whatever `BottomAppBar` leaves after reserving space for the
          // FAB notch (`notchMargin`) -- shrinks rather than overflows if
          // it doesn't quite fit, including under larger accessibility text
          // scales.
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
