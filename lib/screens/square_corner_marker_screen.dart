import 'dart:io';

import 'package:flutter/material.dart';

import '../services/frame_corners.dart';
import '../services/transect_frame.dart' show NormPoint;

/// Issue #14: marks the 1 × 1 m square's corners on one calibration still,
/// for notebook 31's field-of-view check. The same drag-four-corners idea
/// and geometry helpers as the frame corner editor (#5,
/// `frame_corner_editor_screen.dart`), without its database: a calibration
/// still isn't a transect frame. Pops the corners in image order (TL, TR,
/// BR, BL), or `null` when skipped.
class SquareCornerMarkerScreen extends StatefulWidget {
  const SquareCornerMarkerScreen({super.key, required this.imagePath, required this.aspectRatio});

  final String imagePath;

  /// Width over height of the still (portrait).
  final double aspectRatio;

  @override
  State<SquareCornerMarkerScreen> createState() => _SquareCornerMarkerScreenState();
}

class _SquareCornerMarkerScreenState extends State<SquareCornerMarkerScreen> {
  List<NormPoint> _corners = defaultCorners();
  String? _error;

  void _save() {
    final ordered = orderCorners(_corners);
    if (!isValidFrame(ordered)) {
      setState(() => _error = 'The corners cross or are too close together. Drag each onto a corner of the square.');
      return;
    }
    Navigator.of(context).pop(ordered);
  }

  void _drag(int i, Offset delta, BoxConstraints box) => setState(() {
        final c = _corners[i];
        _corners = [..._corners]..[i] = clampNorm((x: c.x + delta.dx / box.maxWidth, y: c.y + delta.dy / box.maxHeight));
        _error = null;
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Mark the 1 m square'),
          actions: [
            TextButton(
              key: const Key('square-skip'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Skip'),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: widget.aspectRatio,
                    child: LayoutBuilder(
                      builder: (context, box) => Stack(
                        children: [
                          Positioned.fill(
                            child: Image.file(
                              File(widget.imagePath),
                              fit: BoxFit.fill,
                              errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
                            ),
                          ),
                          Positioned.fill(child: CustomPaint(painter: _QuadPainter(_corners))),
                          for (var i = 0; i < 4; i++)
                            Positioned(
                              left: _corners[i].x * box.maxWidth - 24,
                              top: _corners[i].y * box.maxHeight - 24,
                              child: GestureDetector(
                                key: Key('square-corner-$i'),
                                onPanUpdate: (d) => _drag(i, d.delta, box),
                                child: Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.yellowAccent, width: 3),
                                    color: Colors.yellowAccent.withValues(alpha: 0.2),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(key: const Key('square-save'), onPressed: _save, child: const Text('Save corners')),
                ),
              ),
            ],
          ),
        ),
      );
}

class _QuadPainter extends CustomPainter {
  _QuadPainter(this.corners);
  final List<NormPoint> corners;

  @override
  void paint(Canvas canvas, Size size) {
    final ordered = orderCorners(corners);
    final path = Path()..moveTo(ordered[0].x * size.width, ordered[0].y * size.height);
    for (final c in ordered.skip(1)) {
      path.lineTo(c.x * size.width, c.y * size.height);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.yellowAccent,
    );
  }

  @override
  bool shouldRepaint(_QuadPainter old) => old.corners != corners;
}
