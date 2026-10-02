import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/report_exporter.dart';
import '../services/transect_video.dart';

/// In-app playback of a transect's continuous recording
/// (`TransectRecorder` -> `TransectSession.videoPath`). Before this, the
/// only way to reach a recording was the "Share Transect Video" button at
/// the bottom of Summary's Technical tab -- there was nowhere to simply
/// watch it. Share stays available from the app bar here.
///
/// Sub-plan 16: Summary's colony rows open it at [startAt] -- just before
/// that colony first appears -- with [note] saying when that position is
/// only an estimate.
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({
    super.key,
    required this.file,
    this.title,
    this.startAt,
    this.note,
  });

  final File file;
  final String? title;

  /// Where playback starts; clamped to the file's duration. `null` plays
  /// from the beginning.
  final Duration? startAt;

  /// A line shown under the video, e.g. that [startAt] is approximate.
  final String? note;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final VideoPlayerController _controller =
      VideoPlayerController.file(widget.file);
  late final Future<void> _initFuture = _controller.initialize().then((_) async {
    final startAt = widget.startAt;
    if (startAt != null && startAt > Duration.zero) {
      // Not the exact end: play() at position == duration restarts from 0.
      var last = _controller.value.duration - const Duration(seconds: 1);
      if (last.isNegative) last = Duration.zero;
      await _controller.seekTo(startAt > last ? last : startAt);
    }
    await _controller.play();
  });

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title ?? 'Transect video'),
        actions: [
          IconButton(
            tooltip: 'Share video',
            icon: const Icon(Icons.share),
            onPressed: () => ReportExporter.shareVideo(widget.file.path),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<void>(
          future: _initFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.white),
              );
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Couldn\'t play this video: ${snapshot.error}',
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    ),
                  ),
                ),
                if (widget.note case final note?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      note,
                      style: TextStyle(color: Colors.amber.shade200, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),
                VideoProgressIndicator(
                  _controller,
                  allowScrubbing: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: _controller,
                  builder: (context, value, _) => Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        IconButton(
                          iconSize: 40,
                          color: Colors.white,
                          icon: Icon(
                            value.isPlaying
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_filled,
                          ),
                          onPressed: () => value.isPlaying
                              ? _controller.pause()
                              : _controller.play(),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${formatVideoTime(value.position)} / '
                          '${formatVideoTime(value.duration)}',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
