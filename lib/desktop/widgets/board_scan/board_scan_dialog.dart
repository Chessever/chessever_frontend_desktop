import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:chessever/board_scan/board_scan_api.dart';
import 'package:chessever/board_scan/board_scan_crop.dart';
import 'package:chessever/board_scan/board_scan_image.dart';
import 'package:chessever/board_scan/board_scan_position.dart';
import 'package:chessever/board_scan/board_scan_preview.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/library/image_drop_zone.dart';
import 'package:chessever/theme/app_theme.dart';
import 'board_scan_camera.dart';

Future<String?> showBoardScanDialog(BuildContext context) =>
    showFDialog<String>(
      context: context,
      routeStyle: (_) => FThemes.zinc.dark.dialogRouteStyle,
      builder:
          (context, style, animation) => FTheme(
            data: FThemes.zinc.dark,
            child: FDialog.raw(
              animation: animation,
              constraints: const BoxConstraints(maxWidth: 980, maxHeight: 820),
              builder: (context, _) => const _BoardScanDialog(),
            ),
          ),
    );

class _BoardScanDialog extends StatefulWidget {
  const _BoardScanDialog();
  @override
  State<_BoardScanDialog> createState() => _BoardScanDialogState();
}

class _BoardScanDialogState extends State<_BoardScanDialog> {
  final _api = BoardScanApi();
  BoardScanImage? _image;
  BoardScanPosition? _position;
  List<Offset> _corners = List.of(initialBoardScanCorners);
  bool _camera = false;
  bool _photo = false;
  bool _blackToMove = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _openFile() async {
    if (_busy) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
        withData: false,
      );
      final file = result?.files.firstOrNull;
      if (file == null || !mounted) return;
      if (file.size > 20 * 1024 * 1024) {
        throw const FormatException('Choose an image smaller than 20 MB.');
      }
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      if (mounted) await _prepare(bytes);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error =
                  'The image could not be opened. Choose a JPEG, PNG or WebP under 20 MB.',
        );
      }
    }
  }

  Future<void> _prepare(Uint8List bytes, {bool photo = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _camera = false;
    });
    try {
      final image = await prepareBoardScanImage(bytes);
      if (mounted) {
        setState(() {
          _image = image;
          _position = null;
          _photo = photo;
          _corners = List.of(initialBoardScanCorners);
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  error is FormatException
                      ? error.message
                      : 'This image could not be read.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final image = _image;
    if (_busy || image == null || !validBoardScanCorners(_corners)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final quadrants = await boardScanQuadrants(
        image,
        _corners,
        photo: _photo,
      );
      if (!mounted) return;
      final position = await _api.scan(quadrants, photo: _photo);
      if (mounted) setState(() => _position = position);
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  error is BoardScanException
                      ? error.message
                      : 'The image could not be read. Try a clearer photo.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image, position = _position;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    position != null
                        ? 'Review detected position'
                        : image != null
                        ? 'Align board corners'
                        : 'Import board image',
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                DesktopDialogIconButton(
                  icon: Icons.close,
                  tooltip: 'Close image import',
                  onPress: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_camera)
              BoardScanCamera(
                onCapture: (bytes) => _prepare(bytes, photo: true),
                onCancel: () => setState(() => _camera = false),
              )
            else if (image == null) ...[
              const Text(
                'Choose a photo or diagram. The detected position opens in the board editor for correction.',
              ),
              const SizedBox(height: 20),
              ImageDropZone(
                enabled: !_busy,
                semanticsLabel: 'Upload a chessboard image, or drop one here',
                onChoose: _openFile,
                onDropped: _prepare,
                onRefused: (message) => setState(() => _error = message),
                builder:
                    (_, phase) => SizedBox(
                      height: 210,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.add_photo_alternate_outlined,
                              size: 30,
                              color: kWhiteColor,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              phase == ImageDropPhase.dragging
                                  ? 'Drop image to open'
                                  : 'Click to upload or drop an image',
                              style: const TextStyle(
                                color: kWhiteColor,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text('JPEG, PNG or WebP · up to 20 MB'),
                          ],
                        ),
                      ),
                    ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: DesktopDialogButton(
                  label: 'Use camera',
                  icon: Icons.camera_alt_outlined,
                  onPress: _busy ? null : () => setState(() => _camera = true),
                ),
              ),
            ] else if (position == null) ...[
              const Text(
                'Drag each corner to the edge of the 64 squares. Leave the frame and coordinates outside.',
              ),
              const SizedBox(height: 24),
              Center(
                child: SizedBox(
                  width: math.min(520, 400 * image.width / image.height),
                  child: BoardScanCrop(
                    image: image,
                    corners: _corners,
                    enabled: !_busy,
                    onChanged: (value) => setState(() => _corners = value),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  DesktopDialogButton(
                    label: _photo ? 'Photo ✓' : 'Photo',
                    onPress: _busy ? null : () => setState(() => _photo = true),
                  ),
                  DesktopDialogButton(
                    label: !_photo ? 'Diagram ✓' : 'Diagram',
                    onPress:
                        _busy ? null : () => setState(() => _photo = false),
                  ),
                  DesktopDialogButton(
                    label: 'Use whole image',
                    tone: DesktopDialogButtonTone.ghost,
                    onPress:
                        _busy
                            ? null
                            : () => setState(
                              () =>
                                  _corners = const [
                                    Offset.zero,
                                    Offset(1, 0),
                                    Offset(1, 1),
                                    Offset(0, 1),
                                  ],
                            ),
                  ),
                ],
              ),
              if (!validBoardScanCorners(_corners))
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    'Keep all four corners in order around the board.',
                  ),
                ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: DesktopDialogButton(
                  label: _busy ? 'Reading…' : 'Read position',
                  onPress:
                      _busy || !validBoardScanCorners(_corners) ? null : _scan,
                ),
              ),
            ] else ...[
              const Text(
                'Check every piece against the image. Rotate the position until its coordinates match your board.',
              ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder:
                    (context, constraints) => Wrap(
                      spacing: 20,
                      runSpacing: 20,
                      children: [
                        BoardScanPreview(
                          size: math.min(410, constraints.maxWidth),
                          fen: position.fen(),
                        ),
                        SizedBox(
                          width: math.min(330, constraints.maxWidth),
                          child: Image.memory(image.bytes, fit: BoxFit.contain),
                        ),
                      ],
                    ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  DesktopDialogButton(
                    label: 'Rotate position 90°',
                    icon: Icons.rotate_right,
                    onPress:
                        () => setState(() => _position = position.rotated()),
                  ),
                  DesktopDialogButton(
                    label: _blackToMove ? 'Black to move' : 'White to move',
                    onPress: () => setState(() => _blackToMove = !_blackToMove),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Castling and en passant are cleared. Set them in the editor if needed.',
              ),
              for (final warning in position.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(warning),
                ),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 12,
                children: [
                  DesktopDialogButton(
                    label: 'Adjust crop and retry',
                    tone: DesktopDialogButtonTone.ghost,
                    onPress: () => setState(() => _position = null),
                  ),
                  DesktopDialogButton(
                    label: 'Open in editor',
                    onPress:
                        () => Navigator.pop(
                          context,
                          position.fen(blackToMove: _blackToMove),
                        ),
                  ),
                ],
              ),
            ],
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 14),
                child: FCircularProgress(),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  _error!,
                  style: const TextStyle(color: kWhiteColor),
                  semanticsLabel: _error,
                ),
              ),
            if (image != null && position == null)
              Align(
                alignment: Alignment.centerLeft,
                child: DesktopDialogButton(
                  label: 'Choose another image',
                  tone: DesktopDialogButtonTone.ghost,
                  onPress:
                      _busy
                          ? null
                          : () => setState(() {
                            _image = null;
                            _error = null;
                          }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
