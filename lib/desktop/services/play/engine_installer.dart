import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chessever/desktop/services/engine/uci_engine.dart';
import 'package:chessever/desktop/services/play/engine_catalog.dart';
import 'package:chessever/desktop/services/play/play_models.dart';

/// One-step bot readiness state for the Play setup screen.
enum EngineInstallStatus {
  /// Catalogued but never installed.
  notInstalled,

  /// Currently downloading (see [EngineInstallState.progress]).
  downloading,

  /// Currently verifying checksum / extracting.
  verifying,

  /// Binary is on disk and usable.
  installed,

  /// Last install attempt failed; user can retry.
  failed,

  /// No artifact published for this OS/arch.
  unsupported,
}

@immutable
class EngineInstallState {
  const EngineInstallState({
    required this.kind,
    required this.status,
    this.progress = 0.0,
    this.bytesDownloaded = 0,
    this.totalBytes,
    this.error,
    this.binaryPath,
  });

  final BotEngineKind kind;
  final EngineInstallStatus status;
  final double progress;
  final int bytesDownloaded;
  final int? totalBytes;
  final String? error;
  final String? binaryPath;

  EngineInstallState copyWith({
    EngineInstallStatus? status,
    double? progress,
    int? bytesDownloaded,
    int? totalBytes,
    String? error,
    String? binaryPath,
    bool clearError = false,
  }) {
    return EngineInstallState(
      kind: kind,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      totalBytes: totalBytes ?? this.totalBytes,
      error: clearError ? null : (error ?? this.error),
      binaryPath: binaryPath ?? this.binaryPath,
    );
  }
}

/// Per-engine install state. Built lazily; the first read seeds itself by
/// scanning the on-disk engine directory + (for Stockfish) the existing
/// [findStockfishBinary] PATH-lookup, so users with Homebrew Stockfish see
/// it as ready without making users prepare it again.
class EngineInstallNotifier extends StateNotifier<EngineInstallState> {
  EngineInstallNotifier(this.kind)
    : super(
        EngineInstallState(
          kind: kind,
          status:
              kEngineCatalog[kind]?.artifactForHost() == null &&
                      kind != BotEngineKind.stockfish
                  ? EngineInstallStatus.unsupported
                  : EngineInstallStatus.notInstalled,
        ),
      ) {
    unawaited(_seed());
  }

  final BotEngineKind kind;
  HttpClient? _client;

  Future<void> _seed() async {
    // Fast path for Stockfish: the existing facade already discovers
    // Homebrew + PATH installs. Reuse it so the Play UI doesn't force a
    // download on users who already have an engine.
    if (kind == BotEngineKind.stockfish) {
      final discovered = await findStockfishBinary();
      if (discovered != null) {
        state = state.copyWith(
          status: EngineInstallStatus.installed,
          binaryPath: discovered,
          progress: 1.0,
        );
        return;
      }
    }
    // Otherwise look for a previously installed copy under app-support.
    final dir = await _engineDir();
    final descriptor = kEngineCatalog[kind];
    final artifact = descriptor?.artifactForHost();
    if (descriptor == null) return;
    if (artifact == null && descriptor.weightsBundle == null) {
      state = state.copyWith(status: EngineInstallStatus.unsupported);
      return;
    }
    if (artifact == null) return;
    final binary = await _installedBinaryFile(dir, artifact);
    if (binary != null &&
        await _requiredAuxiliaryFilesPresent(descriptor, dir)) {
      state = state.copyWith(
        status: EngineInstallStatus.installed,
        binaryPath: binary.path,
      );
    }
  }

  /// Kick off a download. Idempotent — re-entrant calls during an in-progress
  /// download are ignored.
  Future<void> install() async {
    if (state.status == EngineInstallStatus.downloading ||
        state.status == EngineInstallStatus.verifying) {
      return;
    }
    final descriptor = kEngineCatalog[kind];
    final artifact = descriptor?.artifactForHost();
    if (descriptor == null || artifact == null) {
      state = state.copyWith(
        status: EngineInstallStatus.unsupported,
        error: 'Unavailable on this computer.',
      );
      return;
    }
    state = state.copyWith(
      status: EngineInstallStatus.downloading,
      progress: 0,
      bytesDownloaded: 0,
      totalBytes: artifact.bytes,
      clearError: true,
    );
    try {
      final bytes = await _downloadWithProgress(
        artifact.url,
        expectedBytes: artifact.bytes,
      );
      state = state.copyWith(status: EngineInstallStatus.verifying);
      if (artifact.sha256 != 'pending') {
        final actual = sha256.convert(bytes).toString();
        if (actual != artifact.sha256) {
          state = state.copyWith(
            status: EngineInstallStatus.failed,
            error: 'The bot could not be prepared safely.',
          );
          return;
        }
      } else if (kDebugMode) {
        // Catalog entries still using `pending` checksums skip verification —
        // dev builds only. Logging keeps it from being silent.
        debugPrint(
          '⚠️ Skipping checksum verification for ${kind.displayName} '
          '(catalog has sha256: pending).',
        );
      }
      final engineDir = await _engineDir();
      final binaryPath = await _extractToDisk(
        bytes: bytes,
        artifact: artifact,
        targetDir: engineDir,
      );
      if (descriptor.weightsBundle != null) {
        await _installAuxiliaryArtifact(
          descriptor.weightsBundle!,
          targetDir: engineDir,
        );
      }
      for (final auxiliary in descriptor.auxiliaryArtifacts) {
        await _installAuxiliaryArtifact(auxiliary, targetDir: engineDir);
      }
      state = state.copyWith(
        status: EngineInstallStatus.installed,
        binaryPath: binaryPath,
        progress: 1.0,
      );
    } catch (e, st) {
      if (kDebugMode) debugPrint('Bot preparation failed: $e\n$st');
      state = state.copyWith(
        status: EngineInstallStatus.failed,
        error: _friendlyBotPreparationError(e),
      );
    }
  }

  Future<List<int>> _downloadWithProgress(
    String url, {
    int? expectedBytes,
  }) async {
    _client ??= HttpClient();
    final request = await _client!.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('GET $url returned ${response.statusCode}');
    }
    final total = expectedBytes ?? response.contentLength;
    final builder = BytesBuilder();
    var received = 0;
    await for (final chunk in response) {
      builder.add(chunk);
      received += chunk.length;
      state = state.copyWith(
        bytesDownloaded: received,
        totalBytes: total > 0 ? total : null,
        progress: total > 0 ? received / total : 0,
      );
    }
    return builder.toBytes();
  }

  Future<String> _extractToDisk({
    required List<int> bytes,
    required EngineArtifact artifact,
    required Directory targetDir,
  }) async {
    final binaryName = p.basename(artifact.executablePath);
    final outPath = p.join(targetDir.path, binaryName);

    switch (artifact.archiveKind) {
      case 'raw':
        await File(outPath).writeAsBytes(bytes, flush: true);
        break;
      case 'zip':
        final archive = ZipDecoder().decodeBytes(bytes);
        return _extractArchive(archive, artifact, targetDir);
      case 'tar':
        final tarBytes =
            artifact.url.endsWith('.gz')
                ? GZipDecoder().decodeBytes(bytes)
                : bytes;
        final archive = TarDecoder().decodeBytes(tarBytes);
        return _extractArchive(archive, artifact, targetDir);
      default:
        throw const FormatException('Could not prepare bot package.');
    }
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', outPath]);
    }
    return outPath;
  }

  Future<String> _extractArchive(
    Archive archive,
    EngineArtifact artifact,
    Directory targetDir,
  ) async {
    ArchiveFile? executable;
    final expected = _normalizeArchivePath(artifact.executablePath);

    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final normalized = _normalizeArchivePath(entry.name);
      final destination = File(
        p.joinAll([targetDir.path, ...normalized.split('/')]),
      );
      if (!p.isWithin(targetDir.path, destination.path) &&
          p.normalize(destination.path) != p.normalize(targetDir.path)) {
        throw FormatException('Unsafe archive entry path: ${entry.name}');
      }
      if (!await destination.parent.exists()) {
        await destination.parent.create(recursive: true);
      }
      await destination.writeAsBytes(entry.content as List<int>, flush: true);
      if (normalized == expected ||
          p.basename(normalized) == p.basename(expected)) {
        executable = entry;
      }
    }

    if (executable == null) {
      throw const FormatException('Expected executable not in archive');
    }

    final executablePath = p.joinAll([
      targetDir.path,
      ..._normalizeArchivePath(executable.name).split('/'),
    ]);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', executablePath]);
    }
    return executablePath;
  }

  Future<void> _installAuxiliaryArtifact(
    EngineArtifact artifact, {
    required Directory targetDir,
  }) async {
    final bytes = await _downloadWithProgress(
      artifact.url,
      expectedBytes: artifact.bytes,
    );
    if (artifact.sha256 != 'pending') {
      final actual = sha256.convert(bytes).toString();
      if (actual != artifact.sha256) {
        throw StateError('Bot package safety check failed.');
      }
    }
    await _extractToDisk(
      bytes: bytes,
      artifact: artifact,
      targetDir: targetDir,
    );
  }

  Future<File?> _installedBinaryFile(
    Directory dir,
    EngineArtifact artifact,
  ) async {
    final exact = File(
      p.joinAll([
        dir.path,
        ..._normalizeArchivePath(artifact.executablePath).split('/'),
      ]),
    );
    if (await exact.exists()) return exact;

    final basename = p.basename(artifact.executablePath);
    if (!await dir.exists()) return null;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && p.basename(entity.path) == basename) {
        return entity;
      }
    }
    return null;
  }

  Future<bool> _requiredAuxiliaryFilesPresent(
    EngineDescriptor descriptor,
    Directory dir,
  ) async {
    final required = <EngineArtifact>[
      if (descriptor.weightsBundle != null) descriptor.weightsBundle!,
      ...descriptor.auxiliaryArtifacts,
    ];
    for (final artifact in required) {
      final file = File(p.join(dir.path, p.basename(artifact.executablePath)));
      if (!await file.exists()) return false;
    }
    return true;
  }

  Future<Directory> _engineDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'engines', kind.name));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  @override
  void dispose() {
    _client?.close(force: true);
    super.dispose();
  }
}

final engineInstallProvider = StateNotifierProvider.family<
  EngineInstallNotifier,
  EngineInstallState,
  BotEngineKind
>((ref, kind) => EngineInstallNotifier(kind));

String _normalizeArchivePath(String path) =>
    path.replaceAll('\\', '/').split('/').where((p) => p.isNotEmpty).join('/');

/// Snapshot helper: a single boolean answer to "is this engine ready to
/// play a game right now?". Reads the installer state if present; otherwise
/// returns false.
bool engineReady(EngineInstallState state) =>
    state.status == EngineInstallStatus.installed && state.binaryPath != null;

List<String> engineLaunchArguments(
  BotEngineKind kind,
  String binaryPath,
  int elo,
) {
  final dir = p.dirname(binaryPath);
  switch (kind) {
    case BotEngineKind.stockfish:
      return const <String>[];
    case BotEngineKind.leela:
      final weights = File(p.join(dir, 'weights.pb.gz'));
      return weights.existsSync()
          ? <String>['--weights=${weights.path}']
          : const <String>[];
    case BotEngineKind.maia:
      if (isMaia3ModelPath(binaryPath)) return const <String>[];
      final weights = File(
        p.join(dir, 'maia-${nearestMaiaLegacyElo(elo)}.pb.gz'),
      );
      return <String>['--weights=${weights.path}'];
  }
}

List<String> engineStrengthOptionCommands(BotEngineKind kind, int elo) {
  switch (kind) {
    case BotEngineKind.stockfish:
      return <String>[
        'setoption name UCI_LimitStrength value true',
        'setoption name UCI_Elo value $elo',
        'setoption name Skill Level value ${stockfishSkillLevelForElo(elo)}',
      ];
    case BotEngineKind.leela:
      return <String>[
        'setoption name PolicyTemperature value '
            '${leelaPolicyTemperatureForElo(elo).toStringAsFixed(2)}',
      ];
    case BotEngineKind.maia:
      return const <String>[];
  }
}

int stockfishSkillLevelForElo(int elo) {
  final f = ((elo - 1320) / (3190 - 1320)) * 20;
  return f.clamp(0, 20).round();
}

double leelaPolicyTemperatureForElo(int elo) {
  final t = 1.5 - ((elo - 800) / (3200 - 800)) * 1.5;
  return t.clamp(0.0, 1.5).toDouble();
}

String engineWorkingDirectory(String binaryPath) => p.dirname(binaryPath);

String engineGoCommand(
  BotEngineKind kind, {
  required int elo,
  required int whiteMillis,
  required int blackMillis,
  required int incrementMillis,
  required Side sideToMove,
  int? baseMillis,
  int ply = 20,
  math.Random? random,
}) {
  final clock = _uciClockFields(
    whiteMillis: whiteMillis,
    blackMillis: blackMillis,
    incrementMillis: incrementMillis,
  );
  final ownMillis = sideToMove == Side.white ? whiteMillis : blackMillis;
  switch (kind) {
    case BotEngineKind.stockfish:
      final moveTime = stockfishMoveTimeMillis(
        elo: elo,
        whiteMillis: whiteMillis,
        blackMillis: blackMillis,
        incrementMillis: incrementMillis,
        sideToMove: sideToMove,
        baseMillis: baseMillis,
        ply: ply,
        random: random,
      );
      return 'go $clock movetime $moveTime';
    case BotEngineKind.leela:
      final moveTime = clockAwareMoveTimeMillis(
        elo: elo,
        ownMillis: ownMillis,
        incrementMillis: incrementMillis,
        baseMillis: baseMillis,
        ply: ply,
        random: random,
      );
      return 'go $clock movetime $moveTime '
          'nodes ${leelaNodeBudgetForElo(elo, ownMillis: ownMillis)}';
    case BotEngineKind.maia:
      final moveTime = clockAwareMoveTimeMillis(
        elo: elo,
        ownMillis: ownMillis,
        incrementMillis: incrementMillis,
        baseMillis: baseMillis,
        ply: ply,
        random: random,
      );
      return 'go $clock movetime $moveTime '
          'nodes ${maiaLegacyNodeBudgetForElo(elo, ownMillis: ownMillis)}';
  }
}

String _uciClockFields({
  required int whiteMillis,
  required int blackMillis,
  required int incrementMillis,
}) {
  return 'wtime ${whiteMillis.clamp(0, 1 << 31)} '
      'btime ${blackMillis.clamp(0, 1 << 31)} '
      'winc ${incrementMillis.clamp(0, 1 << 31)} '
      'binc ${incrementMillis.clamp(0, 1 << 31)}';
}

int stockfishMoveTimeMillis({
  required int elo,
  required int whiteMillis,
  required int blackMillis,
  required int incrementMillis,
  Side sideToMove = Side.white,
  int? baseMillis,
  int ply = 20,
  math.Random? random,
}) {
  final ownMillis = sideToMove == Side.white ? whiteMillis : blackMillis;
  return clockAwareMoveTimeMillis(
    elo: elo,
    ownMillis: ownMillis,
    incrementMillis: incrementMillis,
    baseMillis: baseMillis,
    ply: ply,
    random: random,
  );
}

int clockAwareMoveTimeMillis({
  required int elo,
  required int ownMillis,
  required int incrementMillis,
  int? baseMillis,
  int ply = 20,
  math.Random? random,
}) {
  if (ownMillis <= 0) return 20;
  if (ownMillis <= 1000) {
    return (ownMillis ~/ 7).clamp(20, 140).toInt();
  }
  final inferredBase = math.max(baseMillis ?? ownMillis, ownMillis);
  final clampedElo = elo.clamp(800, 3200);
  final eloFactor = (clampedElo - 800) / (3200 - 800);
  final lowEloFactor = 1.0 - eloFactor;
  final categoryBase = _humanBaseThinkMillis(inferredBase);
  final phaseFactor = _phaseThinkFactor(ply);
  final pressureFactor = _clockPressureFactor(
    ownMillis: ownMillis,
    baseMillis: inferredBase,
  );
  final eloThinkFactor = 0.82 + (eloFactor * 0.46) + (lowEloFactor * 0.16);
  final incrementBudget = incrementMillis * (0.35 + eloFactor * 0.25);
  final clockBudget = ownMillis * _clockSpendShare(inferredBase);
  var budget =
      (categoryBase * phaseFactor * eloThinkFactor + incrementBudget)
          .clamp(80, clockBudget)
          .toDouble();
  budget *= pressureFactor;
  budget *= _humanThinkJitter(
    random: random,
    lowEloFactor: lowEloFactor,
    pressureFactor: pressureFactor,
  );

  final safety = math.max(120, math.min(1200, (ownMillis * 0.08).round()));
  final hardCap = math.max(20, ownMillis - safety);
  final absoluteCap = _absoluteMoveTimeCap(inferredBase);
  final floor = ownMillis < 5000 ? 40 : 140;
  return budget.clamp(floor, math.min(absoluteCap, hardCap)).round();
}

double _humanBaseThinkMillis(int baseMillis) {
  if (baseMillis <= 120000) return 360;
  if (baseMillis <= 300000) return 1300;
  if (baseMillis <= 1800000) return 3000;
  return 6500;
}

int _absoluteMoveTimeCap(int baseMillis) {
  if (baseMillis <= 120000) return 1400;
  if (baseMillis <= 300000) return 4200;
  if (baseMillis <= 1800000) return 12000;
  return 22000;
}

double _clockSpendShare(int baseMillis) {
  if (baseMillis <= 120000) return 0.030;
  if (baseMillis <= 300000) return 0.038;
  if (baseMillis <= 1800000) return 0.045;
  return 0.055;
}

double _phaseThinkFactor(int ply) {
  if (ply < 8) return 0.62;
  if (ply < 20) return 0.92;
  if (ply < 70) return 1.10;
  return 0.82;
}

double _clockPressureFactor({required int ownMillis, required int baseMillis}) {
  final remaining = ownMillis / math.max(baseMillis, 1);
  if (ownMillis <= 3000) return 0.18;
  if (ownMillis <= 10000) return 0.32;
  if (ownMillis <= 30000) return 0.52;
  if (remaining <= 0.08) return 0.55;
  if (remaining <= 0.18) return 0.72;
  return 1.0;
}

double _humanThinkJitter({
  required math.Random? random,
  required double lowEloFactor,
  required double pressureFactor,
}) {
  if (random == null) return 1.0;
  final spread = 0.16 + lowEloFactor * 0.24;
  var factor = 1.0 - spread + random.nextDouble() * spread * 2;
  if (pressureFactor >= 0.9 && lowEloFactor > 0.45) {
    if (random.nextDouble() < 0.12 + lowEloFactor * 0.08) {
      factor *= 1.25 + random.nextDouble() * 0.85;
    }
  } else if (pressureFactor < 0.55 && lowEloFactor > 0.35) {
    if (random.nextDouble() < 0.28) {
      factor *= 0.45 + random.nextDouble() * 0.25;
    }
  }
  return factor.clamp(0.28, 2.15).toDouble();
}

int leelaNodeBudgetForElo(int elo, {int? ownMillis}) {
  final clampedElo = elo.clamp(800, 3200);
  final strength = (clampedElo - 800) / (3200 - 800);
  final base = (8 + strength * 40).round().clamp(8, 48).toInt();
  return _clockScaledNodes(base, ownMillis: ownMillis);
}

int maiaLegacyNodeBudgetForElo(int elo, {int? ownMillis}) {
  final clampedElo = elo.clamp(1100, 1900);
  final strength = (clampedElo - 1100) / (1900 - 1100);
  final base = (6 + strength * 26).round().clamp(6, 32).toInt();
  return _clockScaledNodes(base, ownMillis: ownMillis);
}

int _clockScaledNodes(int base, {required int? ownMillis}) {
  if (ownMillis == null) return base;
  if (ownMillis <= 1000) return math.max(4, (base * 0.35).round());
  if (ownMillis <= 3000) return math.max(4, (base * 0.55).round());
  if (ownMillis <= 10000) return math.max(4, (base * 0.75).round());
  return base;
}

bool isMaia3ModelPath(String path) =>
    p.basename(path).toLowerCase() == 'maia3_simplified.onnx';

int nearestMaiaLegacyElo(int elo) {
  return ((elo / 100).round() * 100).clamp(1100, 1900);
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Convenience for the Play setup screen: a per-engine summary line.
String describeEngineState(EngineInstallState s) {
  switch (s.status) {
    case EngineInstallStatus.installed:
      return 'Ready';
    case EngineInstallStatus.downloading:
      if (s.progress <= 0 || s.progress >= 1) {
        return 'Preparing…';
      }
      return 'Preparing… ${(s.progress * 100).clamp(1, 99).round()}%';
    case EngineInstallStatus.verifying:
      return 'Checking…';
    case EngineInstallStatus.failed:
      return 'Could not prepare';
    case EngineInstallStatus.notInstalled:
      return 'Not ready';
    case EngineInstallStatus.unsupported:
      return 'Unavailable on this computer';
  }
}

String _friendlyBotPreparationError(Object error) {
  final raw = error.toString();
  if (raw.contains('safety check')) {
    return 'The bot could not be prepared safely.';
  }
  if (raw.contains('Unavailable') || raw.contains('Unsupported')) {
    return 'Unavailable on this computer.';
  }
  if (raw.contains('SocketException') || raw.contains('HttpException')) {
    return 'Could not prepare the bot. Check your connection and try again.';
  }
  return 'Could not prepare the bot.';
}

// Silence unused json import warning while reserved for future state
// persistence (we'll cache the install-state map under app-support so
// status survives app restarts without re-running [_seed] over the network).
// ignore: unused_element
String _stubJsonRefForFutureCache() => jsonEncode(<String, dynamic>{});
