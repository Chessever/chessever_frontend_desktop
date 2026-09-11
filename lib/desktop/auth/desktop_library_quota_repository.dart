import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/desktop/auth/desktop_quota_queue.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';

/// COUNT plus INSERT is serialized within this process. Separate devices and
/// detached processes still require an atomic backend quota transaction.
class DesktopLibraryRepository extends LibraryRepository {
  DesktopLibraryRepository(this.access);
  final DesktopAccess Function() access;
  static final _inserts = DesktopQuotaQueue();
  bool disposed = false;

  Future<int> ownedDatabaseCount(String account) => supabase
      .from('user_folders')
      .count(CountOption.exact)
      .eq('user_id', account)
      .or('node_type.eq.database,node_type.is.null');

  @override
  Future<LibraryFolder> createFolder({
    required String name,
    String? color,
    String? icon,
    int? orderIndex,
    String? parentId,
  }) {
    final account = supabase.auth.currentUser?.id;
    return _inserts.run(() async {
      void ensureAccount() {
        if (disposed ||
            account == null ||
            supabase.auth.currentUser?.id != account) {
          throw StateError('Sign in again before creating a database.');
        }
      }

      ensureAccount();
      final database = icon == 'database';
      if (database && access() != DesktopAccess.allowed) {
        final count = await ownedDatabaseCount(account!);
        ensureAccount();
        if (access() != DesktopAccess.allowed &&
            count >= desktopFreeCloudDatabases) {
          throw StateError(
            'Free accounts can create 3 cloud databases. Premium unlocks more.',
          );
        }
      }
      final folders =
          orderIndex == null ? await getFolders() : <LibraryFolder>[];
      ensureAccount();
      final order =
          orderIndex ??
          folders.fold<int>(
                -1,
                (largest, folder) =>
                    folder.orderIndex > largest ? folder.orderIndex : largest,
              ) +
              1;
      // node_type is the current phone contract, not an icon heuristic on read.
      final row =
          await supabase
              .from('user_folders')
              .insert({
                'user_id': account,
                'name': name,
                'color': color ?? '#0FB4E5',
                'icon': icon ?? 'folder_container',
                'order_index': order,
                'parent_id': parentId,
                'node_type': database ? 'database' : 'folder',
              })
              .select()
              .single();
      return LibraryFolder.fromSupabase(row);
    });
  }

  Future<T> _insert<T>(int additions, Future<T> Function() write) {
    final account = supabase.auth.currentUser?.id;
    return _inserts.run(() async {
      void ensureAccount() {
        if (disposed ||
            account == null ||
            supabase.auth.currentUser?.id != account) {
          throw StateError('Sign in again before saving.');
        }
      }

      ensureAccount();
      var status = access();
      if (status != DesktopAccess.allowed) {
        final count = await getTotalAnalysisCountForCurrentUser();
        ensureAccount();
        status = access();
        if (status != DesktopAccess.allowed &&
            !desktopQuotaFits(count, additions, desktopFreeCloudGames)) {
          throw StateError(
            'Free accounts can save 10 cloud games. Premium unlocks more.',
          );
        }
      }
      ensureAccount();
      return write();
    });
  }

  @override
  Future<SavedAnalysis> createSavedAnalysis(SavedAnalysis analysis) =>
      _insert(1, () => super.createSavedAnalysis(analysis));
  @override
  Future<void> createSavedAnalysesBulk(List<SavedAnalysis> analyses) {
    final snapshot = List<SavedAnalysis>.unmodifiable(analyses);
    if (snapshot.isEmpty) return Future.value();
    return _insert(
      snapshot.length,
      () => super.createSavedAnalysesBulk(snapshot),
    );
  }

  // Updates, deletion, organization and export keep the inherited free path.
}

final desktopLibraryRepositoryOverride = libraryRepositoryProvider.overrideWith(
  (ref) {
    ref.keepAlive();
    final repository = DesktopLibraryRepository(
      () => ref.read(desktopPremiumAccessProvider),
    );
    ref.onDispose(() => repository.disposed = true);
    return repository;
  },
);
