import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/report_exporter.dart';

/// In-app playback of a transect's continuous recording
/// (`TransectRecorder` -> `TransectSession.videoPath`). Before this, the
/// only way to reach a recording was the "Share Transect Video" button at
/// the bottom of Summary's Technical tab -- there was nowhere to simply
/// watch it. Share stays available from the app bar here.
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.file, this.title});

  final File file;
  final String? title;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final VideoPlayerController _controller =
      VideoPlayerController.file(widget.file);
  late final Future<void> _initFuture = _controller.initialize().then((_) {
    _controller.play();
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
                          '${_format(value.position)} / ${_format(value.duration)}',
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

  static String _format(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$minutes:$seconds' : '$minutes:$seconds';
  }
}
