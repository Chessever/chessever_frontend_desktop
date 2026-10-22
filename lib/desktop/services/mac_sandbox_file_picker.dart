import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'package:chessever/desktop/services/mac_app_store.dart';

/// Retains user-selected file/folder access across sandboxed app launches.
/// The native side owns security-scoped URLs for the lifetime of the process.
class MacSandboxFilePicker extends FilePicker {
  MacSandboxFilePicker(this._delegate);

  final FilePicker _delegate;
  static const _channel = MethodChannel('chessever.desktop/sandbox_files');

  static Future<void> initialize() async {
    if (!isMacAppStore || FilePicker.platform is MacSandboxFilePicker) return;
    await _channel.invokeMethod<void>('restore');
    FilePicker.platform = MacSandboxFilePicker(FilePicker.platform);
  }

  static Future<void> retain(Iterable<String> paths) async {
    if (!isMacAppStore) return;
    await _channel.invokeMethod<void>('retain', paths.toList(growable: false));
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    final result = await _delegate.pickFiles(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      type: type,
      allowedExtensions: allowedExtensions,
      onFileLoading: onFileLoading,
      allowCompression: allowCompression,
      compressionQuality: compressionQuality,
      allowMultiple: allowMultiple,
      withData: withData,
      withReadStream: withReadStream,
      lockParentWindow: lockParentWindow,
      readSequential: readSequential,
    );
    if (result != null) await retain(result.paths.whereType<String>());
    return result;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    final path = await _delegate.getDirectoryPath(
      dialogTitle: dialogTitle,
      lockParentWindow: lockParentWindow,
      initialDirectory: initialDirectory,
    );
    if (path != null) await retain([path]);
    return path;
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) => _delegate.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    initialDirectory: initialDirectory,
    type: type,
    allowedExtensions: allowedExtensions,
    bytes: bytes,
    lockParentWindow: lockParentWindow,
  );

  @override
  Future<bool?> clearTemporaryFiles() => _delegate.clearTemporaryFiles();
}
