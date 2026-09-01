import 'dart:async';
import 'dart:io';

import 'package:chessever/repository/api_utils/api_exceptions.dart';
import 'package:chessever/repository/supabase/base_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Drives the real [BaseRepository.handleApiCall] without hitting the network.
class _HandleApiCallRepository extends BaseRepository {
  Future<T> invoke<T>(Future<T> Function() apiCall) => handleApiCall(apiCall);
}

Future<Object> _thrownBy(Future<void> Function() body) async {
  try {
    await body();
    fail('expected handleApiCall to throw');
  } catch (error) {
    return error;
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder-anon-key',
    );
  });

  late _HandleApiCallRepository repo;

  setUp(() => repo = _HandleApiCallRepository());

  final addressFailureUri = Uri.parse(
    'https://example.supabase.co/rest/v1/rpc/get_for_you_group_broadcasts',
  );

  test(
    'ClientException address failure becomes NetworkException, not GenericApiException',
    () async {
      final thrown = await _thrownBy(
        () => repo.invoke(() async {
          throw ClientException(
            "Can't assign requested address",
            addressFailureUri,
          );
        }),
      );

      expect(thrown, isA<NetworkException>());
      expect(thrown, isNot(isA<GenericApiException>()));
    },
  );

  test('SocketException becomes NetworkException', () async {
    final thrown = await _thrownBy(
      () => repo.invoke(() async {
        throw const SocketException('Connection failed');
      }),
    );

    expect(thrown, isA<NetworkException>());
    expect(thrown, isNot(isA<GenericApiException>()));
  });

  test('TimeoutException stays a network failure', () async {
    final thrown = await _thrownBy(
      () => repo.invoke(() async {
        throw TimeoutException('Future not completed');
      }),
    );

    expect(thrown, isA<NetworkException>());
    expect(thrown, isNot(isA<GenericApiException>()));
  });

  test(
    'AuthRetryableFetchException without HTTP status is a network failure',
    () async {
      final thrown = await _thrownBy(
        () => repo.invoke(() async {
          throw AuthRetryableFetchException(
            message:
                "ClientException with SocketException: Failed host lookup: "
                "'example.supabase.co' (OS Error: nodename nor servname "
                'provided, or not known, errno = 8)',
          );
        }),
      );

      expect(thrown, isA<NetworkException>());
      expect(thrown, isNot(isA<GenericApiException>()));
    },
  );

  test(
    'AuthRetryableFetchException with 5xx status stays unexpected',
    () async {
      final thrown = await _thrownBy(
        () => repo.invoke(() async {
          throw AuthRetryableFetchException(
            message: 'internal server error',
            statusCode: '500',
          );
        }),
      );

      expect(thrown, isA<GenericApiException>());
      expect(thrown, isNot(isA<NetworkException>()));
    },
  );

  test('StateError becomes GenericApiException', () async {
    final thrown = await _thrownBy(
      () => repo.invoke(() async {
        throw StateError('unexpected repository state');
      }),
    );

    expect(thrown, isA<GenericApiException>());
    expect(thrown, isNot(isA<NetworkException>()));
  });

  test('plain Exception becomes GenericApiException', () async {
    final thrown = await _thrownBy(
      () => repo.invoke(() async {
        throw Exception('rpc failed');
      }),
    );

    expect(thrown, isA<GenericApiException>());
    expect(thrown, isNot(isA<NetworkException>()));
  });

  test('successful callback value is returned', () async {
    final value = await repo.invoke(() async => 42);
    expect(value, 42);
  });
}
