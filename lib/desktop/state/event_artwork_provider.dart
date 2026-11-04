import 'dart:async';

import 'package:chessever/desktop/services/event_artwork_loader.dart';
import 'package:chessever/widgets/event_card/event_image_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final eventArtworkLoaderProvider = Provider<EventArtworkLoader>((ref) {
  return EventArtworkLoader(
    source: EventArtworkSource(client: () => Supabase.instance.client),
  );
});

/// Covers do not depend on player metadata. Successful results survive scroll
/// recycling and tab switches; failed requests can recover without a reload.
final eventArtworkProvider = FutureProvider.autoDispose
    .family<EventImageData, String>((ref, eventId) async {
      var disposed = false;
      ref.onDispose(() => disposed = true);
      final loader = ref.watch(eventArtworkLoaderProvider);
      EventArtwork artwork;
      try {
        artwork = await loader.load(eventId);
      } catch (_) {
        if (disposed) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (disposed) rethrow;
        artwork = await loader.load(eventId);
      }

      var data = EventImageData(
        imageUrl: artwork.imageUrl,
        location: artwork.location,
        fallbackCountryCode: extractCountryFromLocation(artwork.location),
      );
      // Only events with neither artwork nor a location need the heavier
      // player-federation fallback. Keep the established fallback behavior.
      if (!data.hasVisual && !disposed) {
        data = await ref
            .read(eventImageProvider(eventId).future)
            .timeout(const Duration(seconds: 8), onTimeout: () => data);
      }
      if (!disposed && data.hasVisual) {
        final link = ref.keepAlive();
        final timer = Timer(const Duration(minutes: 10), link.close);
        ref.onDispose(timer.cancel);
      }
      return data;
    });
