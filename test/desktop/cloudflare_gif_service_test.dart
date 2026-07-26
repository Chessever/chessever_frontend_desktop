import 'dart:convert';

import 'package:chessever/desktop/services/cloudflare_gif_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('submits an authenticated versioned GIF request', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'jobId': 'job-1',
          'status': 'queued',
          'stage': 'queued',
          'completedFrames': 0,
          'totalFrames': 5,
          'expiresAt': '2026-07-27T12:00:00Z',
        }),
        202,
      );
    });
    final service = CloudflareGifService(
      baseUri: Uri.parse('https://cloudflare.example.test'),
      accessTokenProvider: () async => 'access-token',
      client: client,
    );

    final job = await service.submitJob(
      pgn: '1. e4 e5 *',
      flipped: true,
      metadata: const {'white': 'Alice', 'black': 'Bob'},
    );

    expect(captured.url.path, '/v1/gif-jobs');
    expect(captured.headers['authorization'], 'Bearer access-token');
    expect(jsonDecode(captured.body)['schemaVersion'], 1);
    expect(jsonDecode(captured.body)['flipped'], isTrue);
    expect(job.id, 'job-1');
    expect(job.totalFrames, 5);
    service.close();
  });

  test('polls until the workflow succeeds and reports progress', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      final succeeded = calls > 1;
      return http.Response(
        jsonEncode({
          'jobId': 'job-2',
          'status': succeeded ? 'succeeded' : 'rendering',
          'stage': succeeded ? 'succeeded' : 'rendering',
          'completedFrames': succeeded ? 8 : 4,
          'totalFrames': 8,
          'expiresAt': '2026-07-27T12:00:00Z',
        }),
        200,
      );
    });
    final service = CloudflareGifService(
      baseUri: Uri.parse('https://cloudflare.example.test/'),
      accessTokenProvider: () async => 'access-token',
      client: client,
    );
    final progress = <CloudflareGifJob>[];

    final completed = await service.waitUntilComplete(
      'job-2',
      onProgress: progress.add,
      initialPollInterval: Duration.zero,
    );

    expect(completed.status, CloudflareGifJobStatus.succeeded);
    expect(progress.map((job) => job.completedFrames), [4, 8]);
    service.close();
  });

  test('surfaces stable API errors', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'error': {
            'code': 'active_job_limit',
            'message': 'Finish the active GIF job first.',
          },
        }),
        409,
      ),
    );
    final service = CloudflareGifService(
      baseUri: Uri.parse('https://cloudflare.example.test/'),
      accessTokenProvider: () async => 'access-token',
      client: client,
    );

    expect(
      () => service.getJob('job-3'),
      throwsA(
        isA<CloudflareGifException>().having(
          (error) => error.code,
          'code',
          'active_job_limit',
        ),
      ),
    );
    service.close();
  });

  test(
    'refreshes the Supabase token once after an unauthorized response',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) {
          expect(request.headers['authorization'], 'Bearer stale-token');
          return http.Response(
            jsonEncode({
              'error': {'code': 'invalid_token', 'message': 'Expired'},
            }),
            401,
          );
        }
        expect(request.headers['authorization'], 'Bearer fresh-token');
        return http.Response(
          jsonEncode({
            'jobId': 'job-4',
            'status': 'queued',
            'stage': 'queued',
            'completedFrames': 0,
            'totalFrames': 0,
            'expiresAt': '2026-07-27T12:00:00Z',
          }),
          200,
        );
      });
      final service = CloudflareGifService(
        baseUri: Uri.parse('https://cloudflare.example.test/'),
        accessTokenProvider: () async => 'stale-token',
        refreshAccessTokenProvider: () async => 'fresh-token',
        client: client,
      );

      final job = await service.getJob('job-4');

      expect(job.id, 'job-4');
      expect(calls, 2);
      service.close();
    },
  );
}
