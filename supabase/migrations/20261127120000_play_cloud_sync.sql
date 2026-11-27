-- Play mode in the cloud: everything a player builds in Play is kept on the
-- server, so any ChessEver frontend can show it later. Additive only: new
-- nullable columns, new defaulted jsonb columns and one new table.
--
-- Contract: docs/play_supabase_schema.md.

-- Glicko-2 state per ladder. Rating, peak and the W/D/L counts were already
-- here; without RD, volatility and the last game date a second device could
-- only estimate how settled a rating is.
ALTER TABLE public.user_play_profiles
  ADD COLUMN IF NOT EXISTS rd_bullet double precision,
  ADD COLUMN IF NOT EXISTS rd_blitz double precision,
  ADD COLUMN IF NOT EXISTS rd_rapid double precision,
  ADD COLUMN IF NOT EXISTS rd_classical double precision,
  ADD COLUMN IF NOT EXISTS volatility_bullet double precision,
  ADD COLUMN IF NOT EXISTS volatility_blitz double precision,
  ADD COLUMN IF NOT EXISTS volatility_rapid double precision,
  ADD COLUMN IF NOT EXISTS volatility_classical double precision,
  ADD COLUMN IF NOT EXISTS last_played_bullet timestamptz,
  ADD COLUMN IF NOT EXISTS last_played_blitz timestamptz,
  ADD COLUMN IF NOT EXISTS last_played_rapid timestamptz,
  ADD COLUMN IF NOT EXISTS last_played_classical timestamptz,
  -- XP, level, badge tracks and tiers, claims and recent unlocks: the
  -- client's whole rewards state (`PlayAchievementsState`), versioned.
  ADD COLUMN IF NOT EXISTS rewards jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- When the rewards state last changed on the writing device, so two
  -- devices merge by the newer one.
  ADD COLUMN IF NOT EXISTS rewards_updated_at timestamptz,
  -- Play preferences that follow the player between devices and apps: help
  -- style, chosen help modules.
  ADD COLUMN IF NOT EXISTS settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS settings_updated_at timestamptz;

ALTER TABLE public.user_play_rating_history
  ADD COLUMN IF NOT EXISTS rd double precision,
  ADD COLUMN IF NOT EXISTS volatility double precision;

-- Tournaments the player ran against bots: one row per event, its full
-- snapshot (pairings, standings, results) in `snapshot`.
CREATE TABLE IF NOT EXISTS public.user_play_tournaments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  local_event_key text NOT NULL CHECK (length(local_event_key) BETWEEN 1 AND 200),
  title text,
  format text,
  status text,
  started_at timestamptz,
  finished_at timestamptz,
  rounds integer,
  players integer,
  user_rank integer,
  user_score numeric,
  snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, local_event_key)
);

CREATE INDEX IF NOT EXISTS user_play_tournaments_user_started_idx
  ON public.user_play_tournaments (user_id, started_at DESC);

ALTER TABLE public.user_play_tournaments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read their own play tournaments"
  ON public.user_play_tournaments;
CREATE POLICY "Users can read their own play tournaments"
  ON public.user_play_tournaments FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "Users can insert their own play tournaments"
  ON public.user_play_tournaments;
CREATE POLICY "Users can insert their own play tournaments"
  ON public.user_play_tournaments FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "Users can update their own play tournaments"
  ON public.user_play_tournaments;
CREATE POLICY "Users can update their own play tournaments"
  ON public.user_play_tournaments FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

GRANT SELECT, INSERT, UPDATE ON public.user_play_tournaments TO authenticated;
