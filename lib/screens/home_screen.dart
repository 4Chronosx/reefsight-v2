import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/app_database.dart';
import '../services/session_summary.dart';
import '../widgets/glove_button.dart';
import '../widgets/health_chip.dart';
import '../widgets/logo_badge.dart';
import '../widgets/section_card.dart';
import '../widgets/underwater_background.dart';
import 'summary_screen.dart';
import 'transect_setup_screen.dart';

/// Sub-plan 6 (ui-ux-overhaul), step 3. Adapted from v1's `home_screen.dart`
/// (`../reefsight/lib/screens/home_screen.dart`): the underwater-photo hero
/// with the logo badge, headline, and swipeable HEALTHY/BLEACHED coral
/// cards, plus a white bottom sheet -- kept close to v1's layout per the
/// sub-plan's "Adapt it, don't redraw it," but simplified (no callout-line
/// painter tying the photo to the floating card -- decorative only, and this
/// sub-plan's "Verification limits" mean nothing here gets a visual check
/// against the mockup regardless). v1's dual "Free Survey" / "Transect
/// Survey" choice is dropped for decision 2's single survey type, and the
/// bottom sheet gains a "Recent surveys" strip v1 never had (this project
/// has a `listSessions()` v1's data model had no equivalent for).
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.dataRevision,
    required this.onSeeAllSurveys,
    this.openDatabase = openAppDatabase,
  });

  /// Bumped by [AppShell] to force a reload of [_recentSurveys] -- see
  /// `app_shell.dart`'s doc comment.
  final int dataRevision;

  final VoidCallback onSeeAllSurveys;

  /// Injectable so widget tests can substitute an in-memory DB instead of
  /// `path_provider` (no platform channel under `flutter test`).
  final DatabaseOpener openDatabase;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _pageController = PageController();
  int _page = 0;
  late Future<List<SessionSummary>> _recentSurveys = _loadRecentSurveys();

  Future<List<SessionSummary>> _loadRecentSurveys() async {
    final db = await widget.openDatabase();
    try {
      final all = await db.listSessions();
      return all.take(3).toList(growable: false);
    } finally {
      await db.close();
    }
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataRevision != widget.dataRevision) {
      setState(() => _recentSurveys = _loadRecentSurveys());
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: height * 0.5,
            child: SafeArea(
              bottom: false,
              child: UnderwaterBackground(child: _buildHero()),
            ),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                child: _buildBottomContent(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Center(child: LogoBadge()),
        const SizedBox(height: 16),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 22),
          child: Text(
            "How do we know a coral's health state?",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: _corals.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => _CoralCard(data: _corals[i]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_corals.length, (i) {
              return AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _page ? 20 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: i == _page ? Colors.white : Colors.white38,
                  borderRadius: BorderRadius.circular(3),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionCard(
          icon: Icons.info_rounded,
          title: 'Before you start',
          // These bullets carry over from v1's `home_screen.dart` verbatim,
          // plus the landscape-orientation bullet this sub-plan adds
          // (decision 7). The 30-50 cm / 0-10 m figures aren't independently
          // sourced in this project's Spec or Dev Plan (checked: neither
          // document mentions either figure) -- confirm them with the field
          // team before relying on them at the panel/defense.
          child: Text(
            '• Move slowly and steadily along the transect\n'
            '• Keep camera 30–50 cm from reef surface\n'
            '• Ensure adequate lighting (avoid shadows)\n'
            '• Survey depth: 0–10 meters only\n'
            '• Hold the phone housing in landscape orientation',
            style: TextStyle(color: AppColors.onSurface, fontSize: 13, height: 1.6),
          ),
        ),
        const SizedBox(height: 20),
        GloveButton(
          label: 'Start Transect Survey',
          icon: Icons.play_circle_outline_rounded,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TransectSetupScreen()),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Recent surveys',
              style: TextStyle(
                color: AppColors.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            TextButton(
              onPressed: widget.onSeeAllSurveys,
              child: const Text('See all'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<SessionSummary>>(
          future: _recentSurveys,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final surveys = snapshot.data ?? const [];
            if (surveys.isEmpty) {
              return Text(
                'No surveys yet -- your first one will show up here.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              );
            }
            return Column(
              children: [
                for (final summary in surveys)
                  _RecentSurveyCard(summary: summary),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _RecentSurveyCard extends StatelessWidget {
  const _RecentSurveyCard({required this.summary});

  final SessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final session = summary.session;
    final bleachingPct = summary.colonyCount == 0
        ? null
        : (summary.bleachedCount / summary.colonyCount * 100).round();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => SummaryScreen(sessionId: session.id!)),
        ),
        title: Text(session.siteName ?? 'Unnamed site'),
        subtitle: Text(
          session.startedAt.toLocal().toString().substring(0, 16),
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
        ),
        // Sub-plan 14: no app numbers for a "Recount planned" survey until
        // its results are revealed.
        trailing: session.resultsCurrentlyHidden
            ? Text(
                'Results hidden',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              )
            : bleachingPct == null
                ? const HealthChip(healthLabel: null)
                : Text(
                    '$bleachingPct% bleached',
                    style: const TextStyle(color: AppColors.bleached, fontSize: 12),
                  ),
      ),
    );
  }
}

class _CoralData {
  const _CoralData(this.image, this.label, this.description, this.badgeColor);

  final String image;
  final String label;
  final String description;
  final Color badgeColor;
}

const _corals = [
  _CoralData(
    'assets/images/healthy_coral.png',
    'HEALTHY',
    'Full pigmentation, vivid coloration',
    AppColors.healthy,
  ),
  _CoralData(
    'assets/images/bleached_coral.png',
    'BLEACHED',
    'Near-total whitening, skeleton visible',
    AppColors.bleached,
  ),
];

class _CoralCard extends StatelessWidget {
  const _CoralCard({required this.data});

  final _CoralData data;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Image.asset(data.image, fit: BoxFit.contain),
        ),
        Positioned(
          top: 8,
          right: 18,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 6),
                      decoration:
                          BoxDecoration(color: data.badgeColor, shape: BoxShape.circle),
                    ),
                    Text(
                      data.label,
                      style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                SizedBox(
                  width: 148,
                  child: Text(
                    data.description,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
