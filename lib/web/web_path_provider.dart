import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// App folders for the browser build, inside the virtual filesystem
/// (web_file_system.dart), so desktop code asking path_provider for its
/// support, cache or documents folder keeps working.
class WebPathProvider extends PathProviderPlatform {
  static const String root = '/home/chessever';

  static const List<String> folders = [
    '$root/support',
    '$root/cache',
    '$root/documents',
    '$root/downloads',
    '/tmp',
  ];

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/documents';

  @override
  Future<String?> getLibraryPath() async => '$root/support';

  @override
  Future<String?> getDownloadsPath() async => '$root/downloads';

  @override
  Future<String?> getTemporaryPath() async => '/tmp';
}
