import 'package:flutter/material.dart';

/// A top-of-screen error banner for segmentation/recording/storage failures
/// (sub-plan 6, ui-ux-overhaul, step 6): an icon and one-line
/// plain-language [message], with the raw exception [detail] behind a
/// tap-to-expand toggle instead of always-on small red text -- replaces the
/// pre-sub-plan-6 `_PerformanceAndTracksOverlay`'s inline
/// `Text(..., style: TextStyle(color: Colors.redAccent, fontSize: 12))`
/// lines. Callers place this at the top edge only, so it never covers the
/// centre of the camera frame.
class LiveErrorBanner extends StatefulWidget {
  const LiveErrorBanner({super.key, required this.message, required this.detail});

  final String message;
  final String detail;

  @override
  State<LiveErrorBanner> createState() => _LiveErrorBannerState();
}

class _LiveErrorBannerState extends State<LiveErrorBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white70,
                  size: 18,
                ),
              ],
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 28),
                child: Text(
                  widget.detail,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
