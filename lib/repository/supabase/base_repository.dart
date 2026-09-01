import 'package:chessever/repository/api_utils/api_exceptions.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract class BaseRepository {
  final SupabaseClient _supabase = Supabase.instance.client;

  SupabaseClient get supabase => _supabase;

  Future<T> handleApiCall<T>(Future<T> Function() apiCall) async {
    try {
      return await apiCall();
    } on PostgrestException catch (e) {
      throw _handlePostgrestException(e);
    } catch (e) {
      throw exceptionFromApiCallFailure(e);
    }
  }

  Exception _handlePostgrestException(PostgrestException e) {
    switch (e.code) {
      case '23503':
        return NotFoundException('Referenced resource not found');
      case '23505':
        return GenericApiException('Duplicate entry');
      case '42P01':
        return GenericApiException('Table does not exist');
      case 'PGRST116':
        return NotFoundException('No rows found');
      default:
        if (e.message.toLowerCase().contains('rate limit')) {
          return RateLimitException('Too many requests');
        }
        return GenericApiException('Database error: ${e.message}');
    }
  }
}
