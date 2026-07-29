import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chessever/desktop/services/engine/macos_release_arch.dart';
import 'package:chessever/theme/app_theme.dart';

/// Resolves the host machine arch for wrong-chip detection.
///
/// Inject [machineResolver] in tests; production shells out to `uname -m`.
typedef MacOsHostMachineResolver = Future<String> Function();

Future<String> defaultMacOsHostMachine() async {
  final result = await Process.run('uname', const ['-m']);
  if (result.exitCode != 0) {
    return '';
  }
  return (result.stdout as String).trim();
}

/// Pure decision: should we block/warn about a wrong Mac package.
@immutable
class MacOsChipMismatch {
  const MacOsChipMismatch({
    required this.buildFlavor,
    required this.hostArch,
  });

  final MacOsReleaseArch buildFlavor;
  final MacOsReleaseArch hostArch;

  String get message => wrongMacOsChipMessage(
    buildFlavor: buildFlavor,
    hostArch: hostArch,
  );

  Uri get recoveryDownloadUri => hostArch.downloadUri;
}

MacOsChipMismatch? evaluateMacOsChipMismatch({
  required MacOsReleaseArch buildFlavor,
  required String hostMachine,
  bool isMacOS = true,
}) {
  if (!isMacOS) return null;
  final host = hostMacOsArchFromMachine(hostMachine);
  if (!isWrongMacOsChip(buildFlavor: buildFlavor, hostArch: host)) {
    return null;
  }
  return MacOsChipMismatch(buildFlavor: buildFlavor, hostArch: host!);
}

Future<MacOsChipMismatch?> detectMacOsChipMismatch({
  MacOsReleaseArch? buildFlavor,
  MacOsHostMachineResolver machineResolver = defaultMacOsHostMachine,
}) async {
  if (!Platform.isMacOS) return null;
  final flavor = buildFlavor ?? macosReleaseArchFromDefine();
  final machine = await machineResolver();
  return evaluateMacOsChipMismatch(
    buildFlavor: flavor,
    hostMachine: machine,
  );
}

/// Modal shown when the installed package's engine arch cannot run here.
Future<void> showMacOsWrongChipDialog(
  BuildContext context, {
  required MacOsChipMismatch mismatch,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: kBlack2Color,
        title: const Text(
          'Wrong Mac package',
          style: TextStyle(color: kWhiteColor, fontWeight: FontWeight.w600),
        ),
        content: Text(
          mismatch.message,
          style: const TextStyle(color: kWhiteColor70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Dismiss'),
          ),
          FilledButton(
            onPressed: () async {
              final uri = mismatch.recoveryDownloadUri;
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: Text('Download ${mismatch.hostArch.humanLabel} build'),
          ),
        ],
      );
    },
  );
}

/// Runs once after first frame when a mismatch is detected.
void scheduleMacOsWrongChipCheck({
  required GlobalKey<NavigatorState> navigatorKey,
  MacOsReleaseArch? buildFlavor,
  MacOsHostMachineResolver machineResolver = defaultMacOsHostMachine,
}) {
  if (!Platform.isMacOS) return;
  unawaited(() async {
    try {
      final mismatch = await detectMacOsChipMismatch(
        buildFlavor: buildFlavor,
        machineResolver: machineResolver,
      );
      if (mismatch == null) return;
      // Wait for the navigator to mount.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final nav = navigatorKey.currentContext;
      if (nav == null || !nav.mounted) return;
      await showMacOsWrongChipDialog(nav, mismatch: mismatch);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('macOS chip guard failed: $e\n$st');
      }
    }
  }());
}
