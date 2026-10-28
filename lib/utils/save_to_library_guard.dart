import 'package:chessever/repository/freemium/freemium_quota.dart';
import 'package:chessever/utils/freemium_quota_guard.dart';
import 'package:flutter/material.dart';

/// Server-authorized admission for saving [gamesToAdd] cloud rows.
///
/// [gamesToAdd] is every destination copy this operation writes: saving 4
/// games into 3 databases is 12. Likes never reach this guard and are never
/// counted. The answer comes from `check_freemium_quota` (see
/// `FreemiumQuotaRepository`), and the returned result carries `used` /
/// `limit` so callers can name the exhausted allowance.
Future<FreemiumQuotaResult> requestSaveGamesQuota(
  BuildContext context, {
  int gamesToAdd = 1,
}) => requestFreemiumQuota(
  context,
  FreemiumQuotaKind.savedGames,
  additions: gamesToAdd,
);

/// Boolean form of [requestSaveGamesQuota] for callers that do not render
/// capacity.
Future<bool> canSaveMoreGames(
  BuildContext context, {
  int gamesToAdd = 1,
}) async =>
    (await requestSaveGamesQuota(context, gamesToAdd: gamesToAdd)).isAllowed;
