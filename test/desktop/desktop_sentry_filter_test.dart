import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:chessever/desktop/services/desktop_sentry_filter.dart';

SentryEvent _eventFor(Object error) => SentryEvent(throwable: error);

void main() {
  test('offline, abandoned sign-in and image-cache races are dropped', () {
    expect(
      shouldDropDesktopSentryEvent(
        _eventFor(const SocketException('Failed host lookup: example.com')),
      ),
      isTrue,
    );
    expect(
      shouldDropDesktopSentryEvent(
        _eventFor(TimeoutException('OAuth flow timed out.')),
      ),
      isTrue,
    );
    expect(
      shouldDropDesktopSentryEvent(
        SentryEvent(
          exceptions: [
            SentryException(
              type: 'HTTPClientError',
              value: 'HTTP Client Error with status code: 502',
            ),
          ],
        ),
      ),
      isTrue,
    );
  });

  test('real faults still reach Sentry', () {
    expect(
      shouldDropDesktopSentryEvent(_eventFor(StateError('Bad state'))),
      isFalse,
    );
    expect(
      shouldDropDesktopSentryEvent(
        _eventFor(TimeoutException('Future not completed')),
      ),
      isFalse,
    );
  });
}
