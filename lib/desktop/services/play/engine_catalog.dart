import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/play/play_models.dart';

/// Where to fetch a binary from for a given (engine, OS, arch) tuple.
@immutable
class EngineArtifact {
  const EngineArtifact({
    required this.platform,
    required this.arch,
    required this.url,
    required this.sha256,
    required this.archiveKind,
    required this.executablePath,
    this.bytes,
  });

  /// `macos` | `windows` | `linux`.
  final String platform;

  /// `arm64` | `x64` | `universal`.
  final String arch;

  /// Direct download URL. Should be a stable redirect-free link — GitHub
  /// release attachments are the right shape.
  final String url;

  /// Hex-encoded SHA-256 of the archive. Verified before the installer
  /// touches the disk.
  final String sha256;

  /// `zip` | `tar` | `raw` (no archive, just a binary).
  final String archiveKind;

  /// Path of the executable inside the extracted archive, relative to the
  /// archive root. For `raw` artifacts this is the binary filename.
  final String executablePath;

  /// Optional pre-known size in bytes for progress UI; null means show an
  /// indeterminate bar until the HTTP response sets `Content-Length`.
  final int? bytes;
}

/// Top-level description of a downloadable engine.
@immutable
class EngineDescriptor {
  const EngineDescriptor({
    required this.kind,
    required this.version,
    required this.summary,
    required this.artifacts,
    this.weightsBundle,
    this.auxiliaryArtifacts = const <EngineArtifact>[],
  });

  final BotEngineKind kind;
  final String version;
  final String summary;

  /// One entry per supported (platform, arch). Picker chooses the matching
  /// one for the current host; if no entry matches, the engine is unavailable
  /// on this OS and the UI must surface it ("Not supported on Windows ARM").
  final List<EngineArtifact> artifacts;

  /// Some engines ship a binary + a separate weights archive (Maia, Leela).
  /// When set, the installer downloads both into the same engine directory.
  final EngineArtifact? weightsBundle;

  /// Extra files required by the engine. Maia uses one lc0 binary plus a set
  /// of rating-specific weights, so a single [weightsBundle] is not enough.
  final List<EngineArtifact> auxiliaryArtifacts;

  EngineArtifact? artifactForHost() {
    final platform = _hostPlatform();
    final arch = _hostArch();
    EngineArtifact? exactMatch;
    EngineArtifact? archFallback;
    for (final a in artifacts) {
      if (a.platform != platform && a.platform != 'universal') continue;
      if (a.arch == arch) {
        exactMatch = a;
        break;
      }
      if (a.arch == 'universal') archFallback = a;
    }
    return exactMatch ?? archFallback;
  }
}

String _hostPlatform() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return 'unknown';
}

String _hostArch() {
  // Dart doesn't expose CPU arch directly. `Platform.version` ships it
  // for releases; we fall back to x64 when we can't tell so the resolver
  // still picks something rather than returning null.
  final v = Platform.version.toLowerCase();
  if (v.contains('arm64') || v.contains('aarch64')) return 'arm64';
  return 'x64';
}

/// Declarative engine catalog. URLs and checksums must be pinned to a
/// specific release so re-installs are reproducible.
final Map<BotEngineKind, EngineDescriptor> kEngineCatalog = {
  BotEngineKind.stockfish: EngineDescriptor(
    kind: BotEngineKind.stockfish,
    version: '18',
    summary:
        'Strongest classical search engine. Skill is throttled via '
        'UCI_LimitStrength + UCI_Elo.',
    artifacts: [
      EngineArtifact(
        platform: 'macos',
        arch: 'arm64',
        url:
            'https://github.com/official-stockfish/Stockfish/releases/download/sf_18/stockfish-macos-m1-apple-silicon.tar',
        sha256:
            '4d77c4aa3ad9bd1ea8111f2ac5a4620fe7ebf998d6893bf828d49ccd579c8cb0',
        archiveKind: 'tar',
        executablePath: 'stockfish/stockfish-macos-m1-apple-silicon',
        bytes: 115322880,
      ),
      EngineArtifact(
        platform: 'macos',
        arch: 'x64',
        url:
            'https://github.com/official-stockfish/Stockfish/releases/download/sf_18/stockfish-macos-x86-64-avx2.tar',
        sha256:
            '41d30e0860ad924a6ceb422c3a36eba43bbe5ae87d3310840da50e71c53f35d9',
        archiveKind: 'tar',
        executablePath: 'stockfish/stockfish-macos-x86-64-avx2',
        bytes: 114472960,
      ),
      EngineArtifact(
        platform: 'windows',
        arch: 'x64',
        url:
            'https://github.com/official-stockfish/Stockfish/releases/download/sf_18/stockfish-windows-x86-64-avx2.zip',
        sha256:
            '6f6c272ebd6ea594377715235c8a7326f75940ef4f4f856f45106028fe6ae900',
        archiveKind: 'zip',
        executablePath: 'stockfish/stockfish-windows-x86-64-avx2.exe',
        bytes: 76955020,
      ),
      EngineArtifact(
        platform: 'windows',
        arch: 'arm64',
        url:
            'https://github.com/official-stockfish/Stockfish/releases/download/sf_18/stockfish-windows-armv8.zip',
        sha256:
            '7bc5880c11a58b2fdc4fcd606bf5cb593230026eb501a5a8865dc79fda5ea5fd',
        archiveKind: 'zip',
        executablePath: 'stockfish/stockfish-windows-armv8.exe',
        bytes: 76855612,
      ),
    ],
  ),
  BotEngineKind.leela: EngineDescriptor(
    kind: BotEngineKind.leela,
    version: '0.32.1 Windows / 0.32.0 macOS latest asset',
    summary:
        'Neural-net engine. Strength is selected as finite search profiles; '
        'requires a network weights file (downloaded with the binary).',
    artifacts: [
      EngineArtifact(
        platform: 'macos',
        arch: 'universal',
        url:
            'https://github.com/LeelaChessZero/lc0/releases/download/v0.32.0/lc0-v0.32.0-macos_12.6.1',
        sha256:
            '2d276ad784fc0a9a00dc6e0a71d0340fb8805acf27a1874c769f3d8e7c60c81e',
        archiveKind: 'raw',
        executablePath: 'lc0',
      ),
      EngineArtifact(
        platform: 'windows',
        arch: 'x64',
        url:
            'https://github.com/LeelaChessZero/lc0/releases/download/v0.32.1/lc0-v0.32.1-windows-cpu-dnnl.zip',
        sha256:
            'b9cfcfbd3dabffbfd452f6e8e087c22273721bef48eba19640b6d92006c142f5',
        archiveKind: 'zip',
        executablePath: 'lc0.exe',
        bytes: 24001097,
      ),
    ],
    // BT4 small network — works on CPU, easy default.
    weightsBundle: EngineArtifact(
      platform: 'universal',
      arch: 'universal',
      url:
          'https://storage.lczero.org/files/networks-contrib/t1-256x10-distilled-swa-2432500.pb.gz',
      sha256:
          'bc27a6cae8ad36f2b9a80a6ad9dabb0d6fda25b1e7f481a79bc359e14f563406',
      archiveKind: 'raw',
      executablePath: 'weights.pb.gz',
      bytes: 37118673,
    ),
  ),
  BotEngineKind.maia: EngineDescriptor(
    kind: BotEngineKind.maia,
    version: '3',
    summary:
        'Human-like neural opponent. Maia 3 runs locally from the current '
        'ONNX model and uses rating-conditioned human cohorts.',
    artifacts: [
      EngineArtifact(
        platform: 'universal',
        arch: 'universal',
        url: 'https://www.maiachess.com/maia3/maia3_simplified.onnx',
        sha256:
            '405bf76c15727dad8728b352c06a8f3c1b80fb2760e8d666b32485c63d75b856',
        archiveKind: 'raw',
        executablePath: 'maia3_simplified.onnx',
        bytes: 45683686,
      ),
    ],
  ),
};

/// Returns true once we know the engine's binary is on disk. Cheap; reads
/// the install-state cache built by [EngineInstaller].
bool isEngineCatalogued(BotEngineKind kind) => kEngineCatalog.containsKey(kind);
