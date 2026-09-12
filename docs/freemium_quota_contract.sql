-- =============================================================================
-- Freemium storage quota contract (desktop PR 3)
--
-- STATUS: NOT DEPLOYED. This file is the proposed migration. The desktop client
-- ships with a clearly-labelled temporary fallback that is used only while
-- `public.check_freemium_quota` does not exist (see
-- docs/freemium_quota_contract.md and lib/repository/freemium/).
--
-- Modelled on the deployed report quota migration
-- (chessever-frontend: 20260723120000_game_analysis_report_daily_quota.sql):
-- SECURITY DEFINER, SET search_path = public, REVOKE from PUBLIC/anon, EXECUTE
-- for authenticated, jsonb result with a stable `reason` string, and the
-- existing `public._user_has_premium(uuid)` premium predicate.
--
-- Guarantees
--   * Limits live in public.freemium_quota_limits, never in a client.
--   * Every quota-changing statement takes a per-account transaction advisory
--     lock, then recounts from committed state. Two devices cannot both take
--     the last slot: the second waits for the first to commit and then sees
--     its rows. (Requires READ COMMITTED, which is PostgREST's default.)
--   * Canonical counts EXCLUDE: the Likes collection (is_liked_games), folder
--     nodes (node_type = 'folder'), anything the account does not own
--     (followed/subscribed books live under another user_id), and the
--     synthetic TWIC book (a client-side id, never a row).
--   * Only POSITIVE changes in counted storage are charged. Ordinary updates
--     are free. A move from an excluded collection (Likes) into counted
--     storage is a positive change and is charged.
--   * Over-limit accounts (for example after a downgrade) keep every record.
--     Reads, edits, removals and exports never touch a quota path, and this
--     file deletes nothing. The legacy trim functions become no-ops.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Limits (server-owned)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.freemium_quota_limits (
  quota_kind text PRIMARY KEY,
  free_limit integer NOT NULL CHECK (free_limit >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT freemium_quota_limits_kind_check
    CHECK (quota_kind IN ('saved_games', 'favorite_players', 'owned_databases'))
);

ALTER TABLE public.freemium_quota_limits ENABLE ROW LEVEL SECURITY;
-- No policies on purpose: clients learn limits only through check_freemium_quota.

-- Values follow the product spec: 10 saved games across all databases,
-- 3 favourite players (favourite EVENTS are unlimited and never counted),
-- 3 owned cloud databases including the default personal database.
INSERT INTO public.freemium_quota_limits (quota_kind, free_limit) VALUES
  ('saved_games', 10),
  ('favorite_players', 3),
  ('owned_databases', 3)
ON CONFLICT (quota_kind) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 1. One-time, non-destructive data repair
--
-- Desktop builds up to 20.32.16 created organisational folders without sending
-- node_type, so the column default stored them as 'database' until a child was
-- added. Empty nodes carrying the desktop folder icon are organisational
-- folders. Nothing is deleted; a node holding games is never touched.
-- Runs before the triggers below exist.
-- -----------------------------------------------------------------------------
UPDATE public.user_folders f
SET node_type = 'folder'
WHERE f.node_type = 'database'
  AND NOT f.is_liked_games
  AND f.icon = 'folder_container'
  AND NOT EXISTS (
    SELECT 1 FROM public.user_saved_analyses a WHERE a.folder_id = f.id
  );

-- -----------------------------------------------------------------------------
-- 2. Internal helpers
--
-- All helpers are VOLATILE on purpose. STABLE functions reuse the snapshot of
-- the calling query, which would hide rows committed by a concurrent session
-- while this one waited on the advisory lock.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._freemium_quota_lock(p_user_id uuid)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT pg_advisory_xact_lock(
    hashtextextended('freemium_quota:' || p_user_id::text, 0)
  );
$$;

CREATE OR REPLACE FUNCTION public._freemium_quota_limit(p_kind text)
RETURNS integer
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT l.free_limit
  FROM public.freemium_quota_limits l
  WHERE l.quota_kind = p_kind;
$$;

-- Whether a game stored in [p_folder_id] counts against [p_user_id]'s
-- saved-games quota: the folder must be owned by that account and must not be
-- the Likes collection.
CREATE OR REPLACE FUNCTION public._freemium_is_counted_game_folder(
  p_user_id uuid,
  p_folder_id uuid
)
RETURNS boolean
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_folders f
    WHERE f.id = p_folder_id
      AND f.user_id = p_user_id
      AND NOT f.is_liked_games
  );
$$;

-- Canonical usage. NULL for an unknown kind.
CREATE OR REPLACE FUNCTION public._freemium_quota_used(p_user_id uuid, p_kind text)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_kind = 'saved_games' THEN
    RETURN (
      SELECT count(*)::integer
      FROM public.user_saved_analyses a
      JOIN public.user_folders f ON f.id = a.folder_id
      WHERE a.user_id = p_user_id
        AND f.user_id = p_user_id
        AND NOT f.is_liked_games
    );
  ELSIF p_kind = 'favorite_players' THEN
    RETURN (
      SELECT count(*)::integer
      FROM public.user_favorite_players p
      WHERE p.user_id = p_user_id
    );
  ELSIF p_kind = 'owned_databases' THEN
    RETURN (
      SELECT count(*)::integer
      FROM public.user_folders f
      WHERE f.user_id = p_user_id
        AND f.node_type = 'database'
        AND NOT f.is_liked_games
    );
  END IF;
  RETURN NULL;
END;
$$;

-- The single decision used by both the pre-flight RPC and the enforcement
-- triggers. [p_used_before] is the committed usage before the change; when
-- NULL it is read now.
CREATE OR REPLACE FUNCTION public._freemium_quota_decision(
  p_user_id uuid,
  p_kind text,
  p_additions integer,
  p_used_before integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit integer := public._freemium_quota_limit(p_kind);
  v_used integer;
  v_premium boolean;
BEGIN
  IF v_limit IS NULL THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'reason', 'invalid_kind',
      'used', NULL,
      'limit', NULL,
      'is_premium', false,
      'kind', p_kind,
      'requested', p_additions
    );
  END IF;

  v_used := coalesce(p_used_before, public._freemium_quota_used(p_user_id, p_kind));
  v_premium := public._user_has_premium(p_user_id);

  IF v_premium THEN
    RETURN jsonb_build_object(
      'allowed', true, 'reason', 'premium', 'used', v_used, 'limit', v_limit,
      'is_premium', true, 'kind', p_kind, 'requested', p_additions
    );
  END IF;

  -- Zero additions never claim a slot: edits, renames, removals, exports and
  -- moves within counted storage are always allowed, even when over the limit.
  IF p_additions <= 0 THEN
    RETURN jsonb_build_object(
      'allowed', true, 'reason', 'no_new_slot', 'used', v_used, 'limit', v_limit,
      'is_premium', false, 'kind', p_kind, 'requested', p_additions
    );
  END IF;

  IF v_used + p_additions <= v_limit THEN
    RETURN jsonb_build_object(
      'allowed', true, 'reason', 'within_limit', 'used', v_used, 'limit', v_limit,
      'is_premium', false, 'kind', p_kind, 'requested', p_additions
    );
  END IF;

  RETURN jsonb_build_object(
    'allowed', false, 'reason', 'quota_exceeded', 'used', v_used, 'limit', v_limit,
    'is_premium', false, 'kind', p_kind, 'requested', p_additions
  );
END;
$$;

-- Called from AFTER STATEMENT triggers, so the statement's own rows are
-- already visible. Locks, recounts, and raises when a positive change leaves a
-- free account above its limit.
CREATE OR REPLACE FUNCTION public._freemium_quota_assert(
  p_user_id uuid,
  p_kind text,
  p_delta integer
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_used_after integer;
  v_decision jsonb;
BEGIN
  IF p_user_id IS NULL OR coalesce(p_delta, 0) <= 0 THEN
    RETURN;
  END IF;

  PERFORM public._freemium_quota_lock(p_user_id);
  -- Fresh snapshot (VOLATILE): includes rows committed while we waited.
  v_used_after := public._freemium_quota_used(p_user_id, p_kind);
  v_decision := public._freemium_quota_decision(
    p_user_id, p_kind, p_delta, v_used_after - p_delta
  );

  IF NOT coalesce((v_decision ->> 'allowed')::boolean, false) THEN
    RAISE EXCEPTION 'freemium_quota_exceeded'
      USING ERRCODE = 'P0001',
            DETAIL = v_decision::text,
            HINT = p_kind;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._freemium_quota_lock(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._freemium_quota_limit(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._freemium_is_counted_game_folder(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._freemium_quota_used(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._freemium_quota_decision(uuid, text, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._freemium_quota_assert(uuid, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._freemium_quota_used(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public._freemium_quota_decision(uuid, text, integer, integer) TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Public pre-flight RPC
--
-- Signature: public.check_freemium_quota(p_kind text, p_additions integer)
-- Returns:   {allowed, reason, used, limit, is_premium, kind, requested}
-- reason:    auth_required | invalid_kind | invalid_additions | premium |
--            no_new_slot | within_limit | quota_exceeded
--
-- The pre-flight lets the UI say "10 of 10 saved games used" before any work
-- starts. It is not a reservation: the triggers in section 4 are the atomic
-- authority, and a write that loses a race fails with `freemium_quota_exceeded`
-- carrying the same jsonb in DETAIL.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_freemium_quota(
  p_kind text,
  p_additions integer DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object(
      'allowed', false, 'reason', 'auth_required', 'used', NULL, 'limit', NULL,
      'is_premium', false, 'kind', p_kind, 'requested', p_additions
    );
  END IF;

  IF p_additions IS NULL OR p_additions < 0 THEN
    RETURN jsonb_build_object(
      'allowed', false, 'reason', 'invalid_additions', 'used', NULL, 'limit', NULL,
      'is_premium', false, 'kind', p_kind, 'requested', p_additions
    );
  END IF;

  -- Wait for this account's in-flight quota writes so `used` is current.
  PERFORM public._freemium_quota_lock(v_uid);
  RETURN public._freemium_quota_decision(v_uid, p_kind, p_additions, NULL);
END;
$$;

REVOKE ALL ON FUNCTION public.check_freemium_quota(text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_freemium_quota(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_freemium_quota(text, integer) TO service_role;

-- -----------------------------------------------------------------------------
-- 4. Atomic enforcement (statement-level AFTER triggers, transition tables)
--
-- Server contexts (service_role jobs, migrations: auth.uid() IS NULL) are
-- exempt; client writes always carry auth.uid() because RLS requires it.
-- No DELETE trigger exists: removing data is never gated.
-- -----------------------------------------------------------------------------

-- 4a. Saved games: INSERT. Every destination copy of a bulk save counts.
CREATE OR REPLACE FUNCTION public._freemium_saved_games_after_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NULL;
  END IF;
  FOR r IN
    SELECT n.user_id, count(*)::integer AS delta
    FROM freemium_new_rows n
    WHERE public._freemium_is_counted_game_folder(n.user_id, n.folder_id)
    GROUP BY n.user_id
    ORDER BY n.user_id
  LOOP
    PERFORM public._freemium_quota_assert(r.user_id, 'saved_games', r.delta);
  END LOOP;
  RETURN NULL;
END;
$$;

-- 4b. Saved games: UPDATE. Only rows whose folder or owner changed are
-- considered, so ordinary edits never lock or count. Net positive change per
-- account is charged (Likes -> database is +1, database -> database is 0).
CREATE OR REPLACE FUNCTION public._freemium_saved_games_after_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NULL;
  END IF;
  FOR r IN
    SELECT moved.user_id, sum(moved.delta)::integer AS delta
    FROM (
      SELECT n.user_id, 1 AS delta
      FROM freemium_new_rows n
      JOIN freemium_old_rows o ON o.id = n.id
      WHERE (n.folder_id, n.user_id) IS DISTINCT FROM (o.folder_id, o.user_id)
        AND public._freemium_is_counted_game_folder(n.user_id, n.folder_id)
      UNION ALL
      SELECT o.user_id, -1 AS delta
      FROM freemium_new_rows n
      JOIN freemium_old_rows o ON o.id = n.id
      WHERE (n.folder_id, n.user_id) IS DISTINCT FROM (o.folder_id, o.user_id)
        AND public._freemium_is_counted_game_folder(o.user_id, o.folder_id)
    ) moved
    GROUP BY moved.user_id
    HAVING sum(moved.delta) > 0
    ORDER BY moved.user_id
  LOOP
    PERFORM public._freemium_quota_assert(r.user_id, 'saved_games', r.delta);
  END LOOP;
  RETURN NULL;
END;
$$;

-- 4c. Owned databases: INSERT.
CREATE OR REPLACE FUNCTION public._freemium_folders_after_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NULL;
  END IF;
  FOR r IN
    SELECT n.user_id, count(*)::integer AS delta
    FROM freemium_new_rows n
    WHERE n.node_type = 'database'
      AND NOT n.is_liked_games
    GROUP BY n.user_id
    ORDER BY n.user_id
  LOOP
    PERFORM public._freemium_quota_assert(r.user_id, 'owned_databases', r.delta);
  END LOOP;
  RETURN NULL;
END;
$$;

-- 4d. Owned databases and saved games: UPDATE of a node.
--   * folder -> database, or leaving the Likes flag, is a new database.
--   * leaving the Likes flag also moves that collection's games into counted
--     storage, which is charged against saved games.
CREATE OR REPLACE FUNCTION public._freemium_folders_after_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NULL;
  END IF;

  FOR r IN
    SELECT changed.user_id, sum(changed.delta)::integer AS delta
    FROM (
      SELECT n.user_id, 1 AS delta
      FROM freemium_new_rows n
      JOIN freemium_old_rows o ON o.id = n.id
      WHERE (n.node_type, n.is_liked_games, n.user_id)
              IS DISTINCT FROM (o.node_type, o.is_liked_games, o.user_id)
        AND n.node_type = 'database' AND NOT n.is_liked_games
      UNION ALL
      SELECT o.user_id, -1 AS delta
      FROM freemium_new_rows n
      JOIN freemium_old_rows o ON o.id = n.id
      WHERE (n.node_type, n.is_liked_games, n.user_id)
              IS DISTINCT FROM (o.node_type, o.is_liked_games, o.user_id)
        AND o.node_type = 'database' AND NOT o.is_liked_games
    ) changed
    GROUP BY changed.user_id
    HAVING sum(changed.delta) > 0
    ORDER BY changed.user_id
  LOOP
    PERFORM public._freemium_quota_assert(r.user_id, 'owned_databases', r.delta);
  END LOOP;

  FOR r IN
    SELECT changed.user_id, sum(changed.delta)::integer AS delta
    FROM (
      SELECT n.user_id,
             (SELECT count(*) FROM public.user_saved_analyses a
               WHERE a.folder_id = n.id AND a.user_id = n.user_id)::integer AS delta
      FROM freemium_new_rows n
      JOIN freemium_old_rows o ON o.id = n.id
      WHERE (n.is_liked_games, n.user_id) IS DISTINCT FROM (o.is_liked_games, o.user_id)
        AND NOT n.is_liked_games
      UNION ALL
      SELECT o.user_id,
             -(SELECT count(*) FROM public.user_saved_analyses a
                WHERE a.folder_id = o.id AND a.user_id = o.user_id)::integer AS delta
      FROM freemium_new_rows n
      JOIN freemium_old_rows o ON o.id = n.id
      WHERE (n.is_liked_games, n.user_id) IS DISTINCT FROM (o.is_liked_games, o.user_id)
        AND NOT o.is_liked_games
    ) changed
    GROUP BY changed.user_id
    HAVING sum(changed.delta) > 0
    ORDER BY changed.user_id
  LOOP
    PERFORM public._freemium_quota_assert(r.user_id, 'saved_games', r.delta);
  END LOOP;

  RETURN NULL;
END;
$$;

-- 4e. Favourite players: INSERT. Favourite EVENTS have no trigger and no cap.
CREATE OR REPLACE FUNCTION public._freemium_favorite_players_after_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NULL;
  END IF;
  FOR r IN
    SELECT n.user_id, count(*)::integer AS delta
    FROM freemium_new_rows n
    GROUP BY n.user_id
    ORDER BY n.user_id
  LOOP
    PERFORM public._freemium_quota_assert(r.user_id, 'favorite_players', r.delta);
  END LOOP;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public._freemium_saved_games_after_insert() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._freemium_saved_games_after_update() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._freemium_folders_after_insert() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._freemium_folders_after_update() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._freemium_favorite_players_after_insert() FROM PUBLIC, anon, authenticated;

-- Transition tables require one event per trigger.
DROP TRIGGER IF EXISTS freemium_saved_games_insert_quota ON public.user_saved_analyses;
CREATE TRIGGER freemium_saved_games_insert_quota
  AFTER INSERT ON public.user_saved_analyses
  REFERENCING NEW TABLE AS freemium_new_rows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public._freemium_saved_games_after_insert();

DROP TRIGGER IF EXISTS freemium_saved_games_update_quota ON public.user_saved_analyses;
CREATE TRIGGER freemium_saved_games_update_quota
  AFTER UPDATE ON public.user_saved_analyses
  REFERENCING OLD TABLE AS freemium_old_rows NEW TABLE AS freemium_new_rows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public._freemium_saved_games_after_update();

DROP TRIGGER IF EXISTS freemium_folders_insert_quota ON public.user_folders;
CREATE TRIGGER freemium_folders_insert_quota
  AFTER INSERT ON public.user_folders
  REFERENCING NEW TABLE AS freemium_new_rows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public._freemium_folders_after_insert();

DROP TRIGGER IF EXISTS freemium_folders_update_quota ON public.user_folders;
CREATE TRIGGER freemium_folders_update_quota
  AFTER UPDATE ON public.user_folders
  REFERENCING OLD TABLE AS freemium_old_rows NEW TABLE AS freemium_new_rows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public._freemium_folders_after_update();

DROP TRIGGER IF EXISTS freemium_favorite_players_insert_quota ON public.user_favorite_players;
CREATE TRIGGER freemium_favorite_players_insert_quota
  AFTER INSERT ON public.user_favorite_players
  REFERENCING NEW TABLE AS freemium_new_rows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public._freemium_favorite_players_after_insert();

-- -----------------------------------------------------------------------------
-- 5. REQUIRED DATA-LOSS FIX: legacy trim entry points become non-destructive
--
-- Deployed today, the RevenueCat webhook calls these on EXPIRATION and
-- DELETES a lapsed subscriber's favourite players and saved analyses. The
-- policy is that downgrade never deletes data. Signatures and grants are kept
-- so older callers still receive a valid integer instead of an error, but the
-- functions no longer touch any row. The webhook's EXPIRATION call and the
-- `trim-overlimit-free-users` admin function must also be removed at source;
-- redefining these is the safety net for callers that are not redeployed.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trim_favorite_players_to_top_n(
  p_user_id uuid,
  p_keep int
) RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Intentionally a no-op: over-limit favourites are preserved, never trimmed.
  RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.trim_saved_analyses_to_recent_n(
  p_user_id uuid,
  p_keep int
) RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Intentionally a no-op: over-limit saved games are preserved, never trimmed.
  RETURN 0;
END;
$$;

REVOKE ALL ON FUNCTION public.trim_favorite_players_to_top_n(uuid, int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trim_saved_analyses_to_recent_n(uuid, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.trim_favorite_players_to_top_n(uuid, int) TO service_role;
GRANT EXECUTE ON FUNCTION public.trim_saved_analyses_to_recent_n(uuid, int) TO service_role;

COMMIT;
