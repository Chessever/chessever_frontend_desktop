import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/theme/app_theme.dart';

/// Local preview only: no peer connection, audio track or network video.
class BoardScanCamera extends StatefulWidget {
  const BoardScanCamera({
    super.key,
    required this.onCapture,
    required this.onCancel,
  });
  final ValueChanged<Uint8List> onCapture;
  final VoidCallback onCancel;
  @override
  State<BoardScanCamera> createState() => _BoardScanCameraState();
}

class _BoardScanCameraState extends State<BoardScanCamera> {
  final _renderer = RTCVideoRenderer();
  MediaStream? _stream;
  late final Future<void> _opening;
  String? _error;
  bool _ready = false;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    _opening = _start();
    unawaited(_opening);
  }

  Future<void> _start() async {
    try {
      await _renderer.initialize();
      if (!mounted) return;
      MediaStream stream;
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {
            'mandatory': {'minWidth': '1280', 'minHeight': '720'},
            'optional': [],
          },
        });
      } catch (_) {
        if (!mounted) return;
        stream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': true,
        });
      }
      if (!mounted) {
        await _stop(stream);
        return;
      }
      _stream = stream;
      _renderer.srcObject = stream;
      setState(() => _ready = true);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error =
                  'Camera unavailable. Check camera access in system settings, or upload an image.',
        );
      }
    }
  }

  Future<void> _stop(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  Future<void> _capture() async {
    if (_capturing || !_ready || _stream == null) return;
    setState(() => _capturing = true);
    try {
      final frame = await _stream!.getVideoTracks().first.captureFrame();
      if (mounted) widget.onCapture(frame.asUint8List());
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error =
                  'The photo could not be captured. Try again or upload an image.',
        );
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  void dispose() {
    unawaited(_disposeAfterOpening());
    super.dispose();
  }

  Future<void> _disposeAfterOpening() async {
    await _opening;
    _renderer.srcObject = null;
    final stream = _stream;
    if (stream != null) await _stop(stream);
    await _renderer.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: 340,
        child:
            _ready
                ? RTCVideoView(
                  _renderer,
                  mirror: false,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                )
                : Center(
                  child: Text(
                    _error ?? 'Opening camera…',
                    style: const TextStyle(color: kWhiteColor),
                  ),
                ),
      ),
      if (_error != null && _ready)
        Text(_error!, style: const TextStyle(color: kWhiteColor)),
      const SizedBox(height: 16),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          DesktopDialogButton(
            label: 'Back',
            onPress: widget.onCancel,
            tone: DesktopDialogButtonTone.ghost,
          ),
          const SizedBox(width: 12),
          DesktopDialogButton(
            label: _capturing ? 'Capturing…' : 'Take photo',
            icon: Icons.camera_alt_outlined,
            onPress: _ready && !_capturing ? _capture : null,
          ),
        ],
      ),
    ],
  );
}
