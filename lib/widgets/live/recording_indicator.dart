import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';

/// Top-left recording indicator (sub-plan 6, ui-ux-overhaul, step 6): makes
/// `TransectRecorder`'s recording-isolation guarantee visible to the diver
/// for the first time -- the Spec notes "the Spec's recording-isolation
/// guarantee is invisible to the diver today." Turns amber with a message
/// when [errorMessage] is set, matching `live_transect_screen.dart`'s
/// existing `_recordingError` state, which previously only showed up as a
/// line in the debug overlay.
class RecordingIndicator extends StatelessWidget {
  const RecordingIndicator({
    super.key,
    required this.isRecording,
    required this.elapsed,
    this.errorMessage,
  });

  final bool isRecording;
  final Duration elapsed;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final hasError = errorMessage != null;
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D2E48).withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.fiber_manual_record,
            color: hasError
                ? Colors.amber
                : (isRecording ? AppColors.bleached : Colors.white38),
            size: 14,
          ),
          const SizedBox(width: 6),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasError
                    ? 'Recording issue'
                    : (isRecording ? 'REC $minutes:$seconds' : 'Not recording'),
                style: TextStyle(
                  color: hasError ? Colors.amber : Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              // The reason, readable on the device: in the field there's no
              // Xcode console to find it in.
              if (hasError)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    errorMessage!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.amber, fontSize: 11),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
