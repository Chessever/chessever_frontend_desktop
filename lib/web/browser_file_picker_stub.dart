import 'package:chessever/web/picked_web_file.dart';

Future<List<PickedWebFile>?> pickWebFiles({
  required List<String> allowedExtensions,
  required bool allowMultiple,
  required String label,
}) => throw UnsupportedError('Browser files exist only in the web build.');

Future<List<PickedWebFile>?> pickWebFolder({
  bool Function(String relativePath)? accept,
}) => throw UnsupportedError('Folder picking exists only in the web build.');
