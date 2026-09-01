import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart';

abstract class ApiException implements Exception {
  final String message;

  ApiException(this.message);

  @override
  String toString() => message;
}

class NetworkException extends ApiException {
  NetworkException(super.message);
}

/// Local HTTP / socket / timeout / address failures, not Postgrest or 5xx.
///
/// `package:http` wraps OS bind failures such as "Can't assign requested
/// address" in [ClientException], which is not a [SocketException], so the
/// shared API wrapper has to classify it explicitly.
bool isLocalNetworkFailure(Object error) {
  if (error is NetworkException ||
      error is SocketException ||
      error is TimeoutException ||
      error is ClientException ||
      error is HandshakeException ||
      error is TlsException ||
      error is HttpException) {
    return true;
  }
  // GoTrue retryable fetch with no HTTP status never got a response: DNS,
  // bind, connection-refused, and the same ClientException wrap.
  if (error is AuthRetryableFetchException) {
    return error.statusCode == null;
  }
  return false;
}

String localNetworkFailureMessage(Object error) {
  if (error is TimeoutException) {
    return 'Request timeout';
  }
  return 'No internet connection';
}

/// Maps a thrown API-call error to [NetworkException] or [GenericApiException].
///
/// Postgrest errors are handled by the caller before this mapping.
Exception exceptionFromApiCallFailure(Object error) {
  if (isLocalNetworkFailure(error)) {
    return NetworkException(localNetworkFailureMessage(error));
  }
  return GenericApiException('Unexpected error: ${error.toString()}');
}

class RateLimitException extends ApiException {
  RateLimitException(super.message);
}

class NotFoundException extends ApiException {
  NotFoundException(super.message);
}

class ParsingException extends ApiException {
  ParsingException(super.message);
}

class GenericApiException extends ApiException {
  GenericApiException(super.message);
}
