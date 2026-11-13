import 'package:flutter/material.dart';

import '../services/station.dart';
import '../widgets/glove_button.dart';
import '../widgets/section_card.dart';

/// Issue #2: where a photo-transect or preliminary transect lands after
/// setup until its capture flow exists -- photo capture is #4 (import #5),
/// preliminary video is #13. The transect row is already saved, so those
/// flows attach their frames to it by [sessionId].
class CapturePlaceholderScreen extends StatelessWidget {
  const CapturePlaceholderScreen({
    super.key,
    required this.station,
    required this.sessionId,
    required this.transectNumber,
  });

  final Station station;
  final int sessionId;
  final int transectNumber;

  @override
  Widget build(BuildContext context) {
    final photo = station.surveyType == SurveyType.photoTransect;
    return Scaffold(
      appBar: AppBar(title: Text('${station.code} · T$transectNumber')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              icon: photo ? Icons.photo_camera_outlined : Icons.videocam_outlined,
              title: photo ? 'Photo capture' : 'Video capture',
              child: Text(
                'T$transectNumber is saved to ${station.code}. '
                '${photo ? 'In-app photo capture arrives with issue #4 and photo import with #5'
                    : 'Preliminary video capture arrives with issue #13'}; '
                'this transect is ready for it.',
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
            ),
            const SizedBox(height: 24),
            GloveButton(
              label: 'Back to station',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
