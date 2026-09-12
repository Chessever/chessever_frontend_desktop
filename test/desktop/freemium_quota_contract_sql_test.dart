import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static guarantees of `docs/freemium_quota_contract.sql`. The function is
/// not deployed from this repo, so these pin the contract's shape: the
/// behavioural rules (what is charged, what is never deleted) must stay
/// visible in the SQL a backend owner applies.
void main() {
  final sql = File('docs/freemium_quota_contract.sql').readAsStringSync();
  final code = sql
      .split('\n')
      .map((line) {
        final comment = line.indexOf('--');
        return comment < 0 ? line : line.substring(0, comment);
      })
      .join('\n');

  String body(String functionName) {
    final start = code.indexOf('FUNCTION public.$functionName(');
    expect(start, isNonNegative, reason: '$functionName is defined');
    final end = code.indexOf(r'$$;', start);
    return code.substring(start, end);
  }

  test('the RPC keeps the deployed report-quota security shape', () {
    final rpc = body('check_freemium_quota');
    expect(rpc, contains('p_kind text'));
    expect(rpc, contains('p_additions integer'));
    expect(rpc, contains('RETURNS jsonb'));
    expect(rpc, contains('SECURITY DEFINER'));
    expect(rpc, contains('SET search_path = public'));
    expect(
      code,
      contains(
        'REVOKE ALL ON FUNCTION public.check_freemium_quota(text, integer) '
        'FROM PUBLIC, anon;',
      ),
    );
    expect(
      code,
      contains(
        'GRANT EXECUTE ON FUNCTION public.check_freemium_quota(text, integer) '
        'TO authenticated;',
      ),
    );
    final decision = body('_freemium_quota_decision');
    for (final key in ['allowed', 'reason', 'used', 'limit', 'is_premium']) {
      expect(decision, contains("'$key'"));
    }
    expect(decision, contains('public._user_has_premium('));
    expect(code, isNot(contains('FUNCTION public._user_has_premium(')));
  });

  test('quota changes are serialized per account and recounted', () {
    expect(body('_freemium_quota_lock'), contains('pg_advisory_xact_lock'));
    final assertion = body('_freemium_quota_assert');
    expect(
      assertion.indexOf('_freemium_quota_lock'),
      lessThan(assertion.indexOf('_freemium_quota_used')),
    );
    expect(body('_freemium_quota_used'), contains('VOLATILE'));
  });

  test('canonical counts exclude Likes, folders and other owners', () {
    final used = body('_freemium_quota_used');
    expect(used, contains('NOT f.is_liked_games'));
    expect(used, contains("f.node_type = 'database'"));
    expect(used, contains('f.user_id = p_user_id'));
    expect(
      body('_freemium_is_counted_game_folder'),
      contains('NOT f.is_liked_games'),
    );
  });

  test('ordinary updates are free and moves into counted storage are charged', () {
    final update = body('_freemium_saved_games_after_update');
    expect(update, contains('IS DISTINCT FROM (o.folder_id, o.user_id)'));
    expect(
      update,
      contains('_freemium_is_counted_game_folder(n.user_id, n.folder_id)'),
    );
    expect(
      update,
      contains('_freemium_is_counted_game_folder(o.user_id, o.folder_id)'),
    );
    expect(update, contains('HAVING sum(moved.delta) > 0'));
    expect(body('_freemium_folders_after_update'), contains('NOT o.is_liked_games'));
  });

  test('nothing is ever deleted and removals are never gated', () {
    expect(code, isNot(matches(RegExp(r'\bDELETE\s+FROM\b', caseSensitive: false))));
    expect(code, isNot(matches(RegExp(r'\b(AFTER|BEFORE)\s+DELETE\b', caseSensitive: false))));
    for (final trim in [
      'trim_favorite_players_to_top_n',
      'trim_saved_analyses_to_recent_n',
    ]) {
      expect(body(trim), contains('RETURN 0;'), reason: trim);
    }
  });

  test('favourite events carry no quota', () {
    expect(code, isNot(contains('user_favorite_events')));
  });
}
