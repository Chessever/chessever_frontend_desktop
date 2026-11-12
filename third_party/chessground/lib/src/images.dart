import 'dart:async';
import 'dart:convert' show base64;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dartchess/dartchess.dart' show PieceKind;
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'models.dart';

/// A singleton cache for chess piece images.
///
/// This is useful to avoid using the global flutter image cache and the standard
/// [Image] widget which can be unpredictable, and can cause images to blink.
///
/// The board widgets will automatically call [loadAll] on first render if the
/// cache does not already contain the required images. Pieces are hidden until
/// loading completes. For zero-latency first render, pre-populate the cache
/// before the board is displayed:
///
/// ```dart
/// // in main.dart
/// final PieceAssets assets = getPieceAssets();
/// final devicePixelRatio = WidgetsBinding
///         .instance.platformDispatcher.implicitView?.devicePixelRatio ?? 1.0;
/// await ChessgroundImages.instance.loadAll(assets, devicePixelRatio: devicePixelRatio);
/// ```
///
/// The [PieceWidget] class will display the piece image using the [RawImage]
/// widget once the image is available in the cache.
///
/// This is the responsibility of the user to dispose of the cache when it is no
/// longer needed, or when changing the piece set, using the [clear] method.
class ChessgroundImages extends ChangeNotifier {
  ChessgroundImages._();

  static final instance = ChessgroundImages._();

  final Map<AssetImage, _ImageEntry> _assets = {};
  final List<_AtlasEntry> _atlases = [];

  /// A borrowed sprite sheet for a loaded piece set; the cache owns its image.
  /// Until it is ready, painters keep drawing the original images. Packing
  /// runs once per set, not per board.
  PieceAtlas? atlasFor(PieceAssets assets) => _atlasEntry(assets)?.atlas;

  _AtlasEntry? _atlasEntry(PieceAssets assets) {
    for (final entry in _atlases) {
      if (mapEquals(entry.assets, assets)) return entry;
    }
    if (assets.isEmpty || !isAllLoaded(assets)) return null;
    // Bounded independently of the original image cache. A settings change
    // must not retain every sprite sheet the reader ever tried.
    if (_atlases.length >= 3) _atlases.removeAt(0).atlas?.image.dispose();
    final entry = _AtlasEntry(Map.unmodifiable(assets));
    _atlases.add(entry);
    entry.ready = _buildAtlas(entry);
    return entry;
  }

  Future<void> _buildAtlas(_AtlasEntry entry) async {
    // Never pack a sheet synchronously inside a board's paint callback.
    await Future<void>.value();
    if (!_atlases.contains(entry)) return;
    final sources = <PieceKind, ui.Image>{
      for (final item in entry.assets.entries)
        if (get(item.value) case final image?) item.key: image,
    };
    // Atlas transforms scale uniformly. Preserve custom non-square images
    // through the original drawImageRect path, without stretching changes.
    if (sources.length != entry.assets.length ||
        sources.values.any((image) => image.width != image.height)) {
      return;
    }
    final edge = sources.values.map((image) => image.width).reduce(math.max);
    // Medium filtering uses mipmaps for small previews. Leave enough empty
    // texels that a reduced mip never samples a neighbouring piece.
    final padding = math.max(2, (edge / 4).ceil());
    final tile = edge + padding * 2;
    final columns = math.min(4, sources.length);
    final rows = (sources.length / columns).ceil();
    if (tile * columns > 2048 || tile * rows > 2048) return;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final rects = <PieceKind, ui.Rect>{};
    var index = 0;
    for (final source in sources.entries) {
      final offset = ui.Offset(
        ((index % columns) * tile + padding).toDouble(),
        ((index ~/ columns) * tile + padding).toDouble(),
      );
      canvas.drawImage(source.value, offset, ui.Paint());
      rects[source.key] =
          offset & ui.Size.square(source.value.width.toDouble());
      index++;
    }
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(tile * columns, tile * rows);
      if (!_atlases.contains(entry)) {
        image.dispose();
        return;
      }
      entry.atlas = PieceAtlas._(image, Map.unmodifiable(rects));
      notifyListeners();
    } catch (_) {
      // A renderer without offscreen image support keeps the original path.
    } finally {
      picture.dispose();
    }
  }

  void _clearAtlases({AssetImage? changedAsset}) {
    _atlases.removeWhere((entry) {
      if (changedAsset != null && !entry.assets.containsValue(changedAsset)) {
        return false;
      }
      entry.atlas?.image.dispose();
      return true;
    });
  }

  /// Adds the [image] into the cache under the key [asset].
  ///
  /// The cache will assume the ownership of the [image], and will properly
  /// dispose of it at the end.
  void add(AssetImage asset, ui.Image image) {
    _clearAtlases(changedAsset: asset);
    _assets[asset]?.dispose();
    _assets[asset] = _ImageEntry.fromImage(image);
  }

  /// Removes the image [asset] from the cache.
  ///
  /// No error is raised if the image [asset] is not present in the cache.
  ///
  /// This calls [ui.Image.dispose], so make sure that you don't use the previously
  /// cached image once it is cleared (removed) from the cache.
  void evict(AssetImage asset) {
    _clearAtlases(changedAsset: asset);
    final removedAsset = _assets.remove(asset);
    removedAsset?.dispose();
  }

  /// Removes all cached images.
  ///
  /// This calls [ui.Image.dispose] for all images in the cache, so make sure that
  /// you don't use any of the previously cached images once [clear] has
  /// been called.
  void clear() {
    _clearAtlases();
    _assets.forEach((_, asset) => asset.dispose());
    _assets.clear();
  }

  /// Returns the image [asset] from the cache if it exists.
  ///
  /// The image returned can be used as long as it remains in the cache, but
  /// doesn't need to be explicitly disposed.
  ///
  /// If you want to retain the image even after you remove it from the cache,
  /// then you can call [ui.Image.clone] on it.
  ui.Image? get(AssetImage asset) {
    return _assets[asset]?.image;
  }

  /// Loads the specified [asset] into the cache.
  ///
  /// The image is loaded using the [AssetBundle] specified in the [asset], or
  /// the [rootBundle] if the [asset] doesn't specify a bundle.
  ///
  /// The [devicePixelRatio] can be specified to load the image at a different
  /// resolution than the default.
  Future<ui.Image> load(AssetImage asset, {double? devicePixelRatio}) async {
    final cached = _assets[asset];
    if (cached != null) return cached.retrieveAsync();
    final key = await asset.obtainKey(
      ImageConfiguration(devicePixelRatio: devicePixelRatio),
    );
    return (_assets[asset] ??= _ImageEntry.future(
          _fetchToMemory(asset.bundle ?? rootBundle, key.name),
        ))
        .retrieveAsync();
  }

  /// Loads the specified [base64] image into the cache.
  Future<ui.Image> loadBase64(AssetImage asset, String base64) {
    return (_assets[asset] ??= _ImageEntry.future(_fetchFromBase64(base64)))
        .retrieveAsync();
  }

  /// Whether the cache contains the specified [key] or not.
  bool containsKey(AssetImage key) => _assets.containsKey(key);

  /// Returns true if all images in [assets] are currently loaded in the cache.
  bool isAllLoaded(PieceAssets assets) =>
      assets.values.every((AssetImage a) => _assets[a]?.image != null);

  /// Loads all images in [assets], awaiting any already in-flight loads.
  Future<void> loadAll(PieceAssets assets, {double? devicePixelRatio}) async {
    await Future.wait([
      for (final asset in assets.values)
        load(asset, devicePixelRatio: devicePixelRatio),
    ]);
    await _atlasEntry(assets)?.ready;
  }

  /// Returns the list of keys in the cache.
  List<AssetImage> get keys => _assets.keys.toList();

  AssetImage? findKeyForImage(ui.Image image) {
    return _assets.keys.firstWhere(
      (k) => _assets[k]?.image?.isCloneOf(image) ?? false,
    );
  }

  /// Waits until all currently pending image loading operations complete.
  Future<void> ready() {
    return Future.wait(_assets.values.map((asset) => asset.retrieveAsync()));
  }

  Future<ui.Image> _fetchFromBase64(String base64Data) {
    final data = base64Data.substring(base64Data.indexOf(',') + 1);
    final bytes = base64.decode(data);
    return decodeImageFromList(bytes);
  }

  Future<ui.Image> _fetchToMemory(AssetBundle bundle, String name) async {
    final data = await bundle.load(name);
    final bytes = Uint8List.view(data.buffer);
    return decodeImageFromList(bytes);
  }
}

/// One texture and the source rectangle of each piece kind within it.
class PieceAtlas {
  PieceAtlas._(this.image, this.rects);

  final ui.Image image;
  final Map<PieceKind, ui.Rect> rects;
}

class _AtlasEntry {
  _AtlasEntry(this.assets);

  final PieceAssets assets;
  late final Future<void> ready;
  PieceAtlas? atlas;
}

/// Individual entry in the [ChessgroundImages] cache.
///
/// This class owns the [ui.Image] object, which can be disposed of using the
/// [dispose] method.
class _ImageEntry {
  _ImageEntry.future(Future<ui.Image> future) : _future = future {
    _future!.then((image) {
      _image = image;
      _future = null;
    });
  }

  _ImageEntry.fromImage(ui.Image image) : _image = image;

  ui.Image? get image => _image;
  ui.Image? _image;

  Future<ui.Image>? _future;

  Future<ui.Image> retrieveAsync() => _future ?? Future.value(_image);

  /// Properly dispose of an image asset.
  void dispose() {
    if (_image != null) {
      _image!.dispose();
      _image = null;
    }
    if (_future != null) {
      _future!.then((image) => image.dispose());
      _future = null;
    }
  }
}
