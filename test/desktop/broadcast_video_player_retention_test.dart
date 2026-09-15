import 'package:chessever/desktop/widgets/broadcast_video_player_retention.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveBroadcastVideoPlayerRetention', () {
    test(
      'keeps a loaded player offstage when the Board tab is backgrounded',
      () {
        expect(
          resolveBroadcastVideoPlayerRetention(
            tabActive: false,
            windowVisible: true,
            hasPreservedPlayer: true,
            streamsResolved: true,
            languageReady: true,
            hasPlayableStream: true,
            userHidden: false,
          ),
          BroadcastVideoPlayerRetention.preserveOffstage,
        );
      },
    );

    test('keeps a loaded player offstage when the window is hidden', () {
      expect(
        resolveBroadcastVideoPlayerRetention(
          tabActive: true,
          windowVisible: false,
          hasPreservedPlayer: true,
          streamsResolved: true,
          languageReady: true,
          hasPlayableStream: true,
          userHidden: false,
        ),
        BroadcastVideoPlayerRetention.preserveOffstage,
      );
    });

    test('does not park a player that was never loaded', () {
      expect(
        resolveBroadcastVideoPlayerRetention(
          tabActive: false,
          windowVisible: true,
          hasPreservedPlayer: false,
          streamsResolved: true,
          languageReady: true,
          hasPlayableStream: true,
          userHidden: false,
        ),
        BroadcastVideoPlayerRetention.hide,
      );
    });

    test(
      'keeps showing a loaded player while the streams family is refetching',
      () {
        // Switching away from a later Board tab drops the autoDispose
        // listener. Coming back rebuilds the family at AsyncLoading; that
        // gap used to blank the webview and the broadcast restarted.
        expect(
          resolveBroadcastVideoPlayerRetention(
            tabActive: true,
            windowVisible: true,
            hasPreservedPlayer: true,
            streamsResolved: false,
            languageReady: true,
            hasPlayableStream: false,
            userHidden: false,
          ),
          BroadcastVideoPlayerRetention.show,
        );
      },
    );

    test('keeps showing a loaded player while language prefs are loading', () {
      expect(
        resolveBroadcastVideoPlayerRetention(
          tabActive: true,
          windowVisible: true,
          hasPreservedPlayer: true,
          streamsResolved: true,
          languageReady: false,
          hasPlayableStream: false,
          userHidden: false,
        ),
        BroadcastVideoPlayerRetention.show,
      );
    });

    test('hides when the spectator collapsed the player', () {
      expect(
        resolveBroadcastVideoPlayerRetention(
          tabActive: true,
          windowVisible: true,
          hasPreservedPlayer: true,
          streamsResolved: true,
          languageReady: true,
          hasPlayableStream: true,
          userHidden: true,
        ),
        BroadcastVideoPlayerRetention.hide,
      );
    });

    test('hides when the scope has no playable stream', () {
      expect(
        resolveBroadcastVideoPlayerRetention(
          tabActive: true,
          windowVisible: true,
          hasPreservedPlayer: true,
          streamsResolved: true,
          languageReady: true,
          hasPlayableStream: false,
          userHidden: false,
        ),
        BroadcastVideoPlayerRetention.hide,
      );
    });

    test('shows the player on a visible tab with a resolved stream', () {
      expect(
        resolveBroadcastVideoPlayerRetention(
          tabActive: true,
          windowVisible: true,
          hasPreservedPlayer: false,
          streamsResolved: true,
          languageReady: true,
          hasPlayableStream: true,
          userHidden: false,
        ),
        BroadcastVideoPlayerRetention.show,
      );
    });
  });

  group('shouldReloadBroadcastVideoEmbed', () {
    test('does not reload the same embed after a tab switch', () {
      const url =
          'https://chessever.com/embed/video/round/r1/twitch-chess?autoplay=1';
      expect(
        shouldReloadBroadcastVideoEmbed(loadedEmbedUrl: url, nextEmbedUrl: url),
        isFalse,
      );
    });

    test('reloads when the selected stream changes', () {
      expect(
        shouldReloadBroadcastVideoEmbed(
          loadedEmbedUrl:
              'https://chessever.com/embed/video/round/r1/a?autoplay=1',
          nextEmbedUrl:
              'https://chessever.com/embed/video/round/r1/b?autoplay=1',
        ),
        isTrue,
      );
    });

    test('loads after the stop-grace blanked the player', () {
      expect(
        shouldReloadBroadcastVideoEmbed(
          loadedEmbedUrl: null,
          nextEmbedUrl:
              'https://chessever.com/embed/video/round/r1/a?autoplay=1',
        ),
        isTrue,
      );
    });
  });
}
