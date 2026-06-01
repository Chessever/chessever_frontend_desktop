import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/theme/app_theme.dart';

/// Wraps a child widget with a drag-drop overlay for chess files/folders.
///
/// When the user drags recognized chess files or a folder over the window, a
/// translucent overlay previews the drop target. On release,
/// [onChessPathsDropped] is invoked with the list of relevant paths so the
/// active pane can decide what to do (load into board, stage a save-to-library
/// import, or browse the folder in-place).
///
/// This replaces the mobile [`receive_sharing_intent`] integration which
/// is Android/iOS only — desktop users get content into the app via OS
/// drag-and-drop, file associations, and explicit open-file commands.
class LocalChessDropZone extends StatefulWidget {
  const LocalChessDropZone({
    super.key,
    required this.child,
    required this.onChessPathsDropped,
  });

  final Widget child;
  final void Function(List<String> paths) onChessPathsDropped;

  @override
  State<LocalChessDropZone> createState() => _LocalChessDropZoneState();
}

class _LocalChessDropZoneState extends State<LocalChessDropZone> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (details) {
        setState(() => _hovering = false);
        final paths = localChessDropPaths(details.files.map((x) => x.path));
        if (paths.isEmpty) return;
        widget.onChessPathsDropped(paths);
      },
      child: Stack(
        children: [
          widget.child,
          if (_hovering)
            const Positioned.fill(child: IgnorePointer(child: _DropOverlay())),
        ],
      ),
    );
  }
}

@visibleForTesting
List<String> localChessDropPaths(Iterable<String> rawPaths) {
  return rawPaths
      .where(
        (path) =>
            path.trim().isNotEmpty &&
            (looksLikeLocalChessFile(path) || Directory(path).existsSync()),
      )
      .toList(growable: false);
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kPrimaryColor.withValues(alpha: 0.10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kPrimaryColor, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 32,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.file_download_rounded,
                size: 36,
                color: kPrimaryColor,
              ),
              const SizedBox(height: 12),
              const Text(
                'Drop chess files or folders',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                localChessDropFormatsMessage,
                style: TextStyle(color: kLightGreyColor, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
