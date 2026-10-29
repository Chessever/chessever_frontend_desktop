-- Apply only after reviewing the deployment checklist in supabase/ACCOUNT_DELETION.md.
-- No network calls occur in the identity transaction. Outboxes survive auth deletion.
BEGIN;

CREATE SCHEMA IF NOT EXISTS private;
-- Existing public SECURITY INVOKER partner RPCs call private definer helpers.
-- Preserve authenticated USAGE already granted to that schema in production;
-- isolate the new token tables/functions with their own ACLs instead.
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon;
REVOKE CREATE ON SCHEMA private FROM authenticated;

CREATE TABLE private.apple_tokens (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  apple_sub text NOT NULL CHECK (length(apple_sub) BETWEEN 1 AND 512),
  client_id text NOT NULL CHECK (length(client_id) BETWEEN 1 AND 512),
  encrypted_tokens text NOT NULL CHECK (length(encrypted_tokens) BETWEEN 1 AND 65536),
  key_id text NOT NULL CHECK (length(key_id) BETWEEN 1 AND 128),
  captured_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (user_id, client_id)
);

CREATE TABLE private.apple_revoke_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL, -- deliberately no identity FK
  apple_sub text NOT NULL,
  client_id text NOT NULL,
  encrypted_tokens text NOT NULL,
  key_id text NOT NULL,
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_until timestamptz,
  lease_token uuid,
  last_error_code text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX apple_revoke_jobs_due ON private.apple_revoke_jobs(next_attempt_at);
CREATE INDEX apple_revoke_jobs_user ON private.apple_revoke_jobs(user_id);

CREATE TABLE private.apple_notification_receipts (
  jti text PRIMARY KEY CHECK (length(jti) BETWEEN 1 AND 512),
  event_type text NOT NULL,
  event_time bigint NOT NULL,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE private.account_cleanup_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL, -- deliberately no identity FK
  kind text NOT NULL CHECK (kind IN ('storage', 'revenuecat', 'onesignal', 'gamebase', 'ga4', 'appsflyer')),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_until timestamptz,
  lease_token uuid,
  last_error_code text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX account_cleanup_jobs_due ON private.account_cleanup_jobs(next_attempt_at);
CREATE INDEX account_cleanup_jobs_user ON private.account_cleanup_jobs(user_id);

ALTER TABLE private.apple_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.apple_revoke_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.apple_notification_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.account_cleanup_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.apple_tokens, private.apple_revoke_jobs,
  private.apple_notification_receipts, private.account_cleanup_jobs
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.apple_store_tokens(
  p_user_id uuid, p_apple_sub text, p_client_id text,
  p_encrypted_tokens text, p_key_id text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  -- Same lock as deletion: a late registration cannot outlive the identity.
  PERFORM 1 FROM auth.users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Account no longer exists';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM auth.identities
    WHERE user_id = p_user_id AND provider = 'apple'
      AND provider_id = p_apple_sub
      AND (identity_data->>'sub' IS NULL OR identity_data->>'sub' = p_apple_sub)
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Apple identity mismatch';
  END IF;
  INSERT INTO private.apple_tokens(user_id, apple_sub, client_id, encrypted_tokens, key_id)
  VALUES (p_user_id, p_apple_sub, p_client_id, p_encrypted_tokens, p_key_id)
  ON CONFLICT (user_id, client_id) DO UPDATE SET
    apple_sub = EXCLUDED.apple_sub, encrypted_tokens = EXCLUDED.encrypted_tokens,
    key_id = EXCLUDED.key_id, captured_at = clock_timestamp();
END;
$$;

CREATE FUNCTION public.apple_claim_revoke_jobs(p_user_id uuid DEFAULT NULL, p_limit integer DEFAULT 10)
RETURNS SETOF private.apple_revoke_jobs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  RETURN QUERY
  WITH due AS (
    SELECT j.id FROM private.apple_revoke_jobs j
    WHERE (p_user_id IS NULL OR j.user_id = p_user_id)
      AND j.next_attempt_at <= clock_timestamp()
      AND (j.lease_until IS NULL OR j.lease_until <= clock_timestamp())
    ORDER BY j.next_attempt_at, j.id
    LIMIT greatest(1, least(coalesce(p_limit, 10), 100))
    FOR UPDATE SKIP LOCKED
  )
  UPDATE private.apple_revoke_jobs j SET
    lease_until = clock_timestamp() + interval '2 minutes', lease_token = gen_random_uuid(),
    attempts = j.attempts + 1
  FROM due WHERE j.id = due.id RETURNING j.*;
END;
$$;

CREATE FUNCTION public.apple_finish_revoke_job(
  p_id uuid, p_lease_token uuid, p_success boolean, p_error_code text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF p_success THEN
    DELETE FROM private.apple_revoke_jobs
    WHERE id = p_id AND lease_token = p_lease_token AND lease_until > clock_timestamp();
  ELSE
    UPDATE private.apple_revoke_jobs SET lease_token = NULL, lease_until = NULL,
      next_attempt_at = clock_timestamp() + make_interval(secs => least(86400,
        30 * power(2::numeric, least(attempts, 12)))::integer),
      last_error_code = CASE WHEN p_error_code IN
        ('configuration_missing','apple_unavailable','token_decryption_failed','rate_limited','invalid_token','request_failed')
        THEN p_error_code ELSE 'request_failed' END
    WHERE id = p_id AND lease_token = p_lease_token AND lease_until > clock_timestamp();
  END IF;
END;
$$;

CREATE FUNCTION public.account_claim_cleanup_jobs(p_user_id uuid DEFAULT NULL, p_limit integer DEFAULT 10)
RETURNS SETOF private.account_cleanup_jobs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  RETURN QUERY
  WITH due AS (
    SELECT j.id FROM private.account_cleanup_jobs j
    WHERE (p_user_id IS NULL OR j.user_id = p_user_id)
      AND j.next_attempt_at <= clock_timestamp()
      AND (j.lease_until IS NULL OR j.lease_until <= clock_timestamp())
    ORDER BY j.next_attempt_at, j.id
    LIMIT greatest(1, least(coalesce(p_limit, 10), 100))
    FOR UPDATE SKIP LOCKED
  )
  UPDATE private.account_cleanup_jobs j SET
    lease_until = clock_timestamp() + interval '2 minutes', lease_token = gen_random_uuid(),
    attempts = j.attempts + 1
  FROM due WHERE j.id = due.id RETURNING j.*;
END;
$$;

CREATE FUNCTION public.account_finish_cleanup_job(
  p_id uuid, p_lease_token uuid, p_success boolean, p_error_code text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF p_success THEN
    DELETE FROM private.account_cleanup_jobs
    WHERE id = p_id AND lease_token = p_lease_token AND lease_until > clock_timestamp();
  ELSE
    UPDATE private.account_cleanup_jobs SET lease_token = NULL, lease_until = NULL,
      next_attempt_at = clock_timestamp() + make_interval(secs => least(86400,
        30 * power(2::numeric, least(attempts, 12)))::integer),
      last_error_code = CASE WHEN p_error_code IN
        ('configuration_missing','provider_unavailable','rate_limited','invalid_payload','integration_required','request_failed')
        THEN p_error_code ELSE 'request_failed' END
    WHERE id = p_id AND lease_token = p_lease_token AND lease_until > clock_timestamp();
  END IF;
END;
$$;

CREATE FUNCTION public.account_cleanup_pending(p_user_id uuid)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM private.account_cleanup_jobs WHERE user_id = p_user_id);
$$;

CREATE FUNCTION public.apple_lifecycle_health(p_key_ids text[])
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE signature text; function_oid oid;
BEGIN
  IF coalesce(cardinality(p_key_ids), 0) = 0 OR array_position(p_key_ids, NULL) IS NOT NULL THEN RETURN false; END IF;
  -- Read-only readiness: neither claims nor inserts a job, even for empty queues.
  PERFORM 1 FROM private.apple_tokens LIMIT 1;
  PERFORM 1 FROM private.apple_revoke_jobs LIMIT 1;
  PERFORM 1 FROM private.apple_notification_receipts LIMIT 1;
  IF EXISTS (SELECT 1 FROM private.apple_tokens WHERE NOT (key_id = ANY(p_key_ids)))
    OR EXISTS (SELECT 1 FROM private.apple_revoke_jobs WHERE NOT (key_id = ANY(p_key_ids))) THEN RETURN false; END IF;
  FOREACH signature IN ARRAY ARRAY[
    'public.apple_store_tokens(uuid,text,text,text,text)',
    'public.apple_claim_revoke_jobs(uuid,integer)',
    'public.apple_finish_revoke_job(uuid,uuid,boolean,text)',
    'public.apple_process_notification(text,text,text,bigint)'
  ] LOOP
    function_oid := to_regprocedure(signature);
    IF function_oid IS NULL OR NOT has_function_privilege('service_role', function_oid, 'EXECUTE')
      OR has_function_privilege('anon', function_oid, 'EXECUTE')
      OR has_function_privilege('authenticated', function_oid, 'EXECUTE') THEN RETURN false; END IF;
  END LOOP;
  RETURN NOT has_table_privilege('anon', 'private.apple_tokens', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'private.apple_tokens', 'SELECT')
    AND NOT has_table_privilege('anon', 'private.apple_revoke_jobs', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'private.apple_revoke_jobs', 'SELECT');
END;
$$;

-- Finance is a ledger, not an app profile. Preserve transaction/commission facts
-- while severing the auth link instead of the former destructive FK cascade.
ALTER TABLE public.affiliate_conversions ALTER COLUMN referred_user_id DROP NOT NULL;
DO $$
DECLARE constraint_name text;
BEGIN
  FOR constraint_name IN
    SELECT c.conname FROM pg_constraint c
    WHERE c.conrelid = 'public.affiliate_conversions'::regclass
      AND c.confrelid = 'auth.users'::regclass AND c.contype = 'f'
  LOOP
    EXECUTE format('ALTER TABLE public.affiliate_conversions DROP CONSTRAINT %I', constraint_name);
  END LOOP;
END;
$$;
ALTER TABLE public.affiliate_conversions ADD CONSTRAINT affiliate_conversions_deleted_user_fk
  FOREIGN KEY (referred_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE FUNCTION private.before_account_deleted()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE object_row record;
BEGIN
  -- Any insert failure aborts the entire DELETE, including every cascade.
  INSERT INTO private.apple_revoke_jobs(user_id, apple_sub, client_id, encrypted_tokens, key_id)
    SELECT user_id, apple_sub, client_id, encrypted_tokens, key_id
    FROM private.apple_tokens WHERE user_id = OLD.id;

  -- Storage metadata must NEVER be SQL-deleted: only the Storage API removes bytes.
  FOR object_row IN
    SELECT bucket_id, name FROM storage.objects
    WHERE owner_id = OLD.id::text OR owner = OLD.id
      OR (bucket_id = 'profile-avatars' AND split_part(name, '/', 1) = OLD.id::text)
  LOOP
    INSERT INTO private.account_cleanup_jobs(user_id, kind, payload)
    VALUES (OLD.id, 'storage', jsonb_build_object('bucket_id', object_row.bucket_id, 'path', object_row.name));
  END LOOP;

  -- Stable UUID is the account identifier in these SDK integrations. Do not
  -- enqueue shared/aliased rc_original_app_user_id belonging to another account.
  INSERT INTO private.account_cleanup_jobs(user_id, kind) VALUES
    (OLD.id, 'revenuecat'), (OLD.id, 'onesignal'), (OLD.id, 'gamebase'), (OLD.id, 'ga4');
  INSERT INTO private.account_cleanup_jobs(user_id, kind, payload)
    SELECT OLD.id, 'appsflyer', jsonb_build_object('identities', coalesce(
      jsonb_agg(DISTINCT jsonb_build_object('appsflyer_id', appsflyer_id, 'app_id', app_id))
      FILTER (WHERE appsflyer_id IS NOT NULL), '[]'::jsonb))
    FROM public.payment_analytics_outbox WHERE user_id = OLD.id;

  DELETE FROM public.app_feedback WHERE user_id = OLD.id;
  DELETE FROM public.notification_user_windows WHERE user_id = OLD.id;
  DELETE FROM public.user_notification_sends WHERE user_id = OLD.id;
  -- Analytics delivery is not a statutory payment ledger. Stop further sending.
  DELETE FROM public.payment_analytics_outbox WHERE user_id = OLD.id;
  -- Catalog/key-only audit found accounting corrections, commission and Stripe
  -- invoice facts in this JSON. Preserve those; remove observed profile copies.
  UPDATE public.affiliate_conversions SET referred_user_id = NULL,
    purchase_metadata = (purchase_metadata - ARRAY['attribution','email','display_name','user_id','supabase_user_id'])
      #- '{product,supabase_user_id}' #- '{subscription_metadata,supabase_user_id}'
    WHERE referred_user_id = OLD.id;
  UPDATE public.affiliate_discount_codes SET created_by = NULL WHERE created_by = OLD.id::text;
  UPDATE public.affiliate_payouts SET uploaded_by = NULL WHERE uploaded_by = OLD.id::text;
  UPDATE public.broadcast_tournaments SET created_by = NULL WHERE created_by = OLD.id::text;

  -- Operational audit actor FKs already SET NULL, but their copied email does not.
  UPDATE broadcasting_private.event_delegation_events SET actor_email = NULL WHERE actor_id = OLD.id;
  UPDATE broadcasting_private.game_override_events SET actor_email = NULL WHERE actor_id = OLD.id;
  UPDATE broadcasting_private.tour_approval_events SET actor_email = NULL WHERE actor_id = OLD.id;
  DELETE FROM broadcasting_private.video_stream_events WHERE actor_id = OLD.id;
  UPDATE broadcasting_private.event_writer_preparations SET prepared_by_email = NULL WHERE prepared_by = OLD.id;
  UPDATE broadcasting_private.event_writer_transitions SET requested_by_email = NULL WHERE requested_by = OLD.id;

  -- Old refresh-token rows need not have a session_id, so do not rely only on
  -- the session cascade. No still-valid JWT may authorize a second deletion:
  -- the public wrapper additionally requires a live auth.users row.
  DELETE FROM auth.refresh_tokens WHERE user_id = OLD.id::text;
  RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION private.before_account_deleted() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER account_deletion_cleanup BEFORE DELETE ON auth.users
  FOR EACH ROW EXECUTE FUNCTION private.before_account_deleted();

-- Deliberately no CASCADE: unexpected function dependencies must block review,
-- never be silently dropped. Read-only production audit found no dependencies.
DROP FUNCTION public.delete_user_account();
CREATE FUNCTION public.delete_user_account()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE current_user_id uuid := auth.uid(); manual_required boolean;
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Not authenticated';
  END IF;
  PERFORM 1 FROM auth.users WHERE id = current_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Account no longer exists';
  END IF;
  manual_required := EXISTS (SELECT 1 FROM auth.identities WHERE user_id = current_user_id AND provider = 'apple')
    AND NOT EXISTS (SELECT 1 FROM private.apple_tokens WHERE user_id = current_user_id);
  DELETE FROM auth.users WHERE id = current_user_id;
  RETURN jsonb_build_object('deleted', true, 'apple_manual_revoke_required', manual_required);
END;
$$;
REVOKE ALL ON FUNCTION public.delete_user_account() FROM PUBLIC, anon;
-- Preserve the old production grants, with identity still derived from auth.uid().
GRANT EXECUTE ON FUNCTION public.delete_user_account() TO authenticated, service_role;

CREATE FUNCTION public.apple_process_notification(
  p_jti text, p_apple_sub text, p_event_type text, p_event_time bigint
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE account_row record;
BEGIN
  IF p_event_type NOT IN ('consent-revoked', 'account-deleted', 'email-disabled', 'email-enabled')
    OR p_event_type IS NULL OR p_event_time IS NULL OR p_event_time < 0
    OR p_event_time > extract(epoch FROM clock_timestamp())::bigint + 300 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Invalid Apple notification';
  END IF;
  INSERT INTO private.apple_notification_receipts(jti, event_type, event_time)
    VALUES (p_jti, p_event_type, p_event_time) ON CONFLICT DO NOTHING;
  IF NOT FOUND OR p_event_type NOT IN ('consent-revoked', 'account-deleted') THEN RETURN; END IF;
  FOR account_row IN
    SELECT DISTINCT u.id FROM auth.users u JOIN auth.identities i ON i.user_id = u.id
    WHERE i.provider = 'apple' AND i.provider_id = p_apple_sub
  LOOP
    PERFORM 1 FROM auth.users WHERE id = account_row.id FOR UPDATE;
    -- A delayed event from an earlier authorization must not erase a later one.
    IF EXISTS (SELECT 1 FROM auth.users WHERE id = account_row.id
      AND extract(epoch FROM created_at)::bigint <= p_event_time)
      AND NOT EXISTS (SELECT 1 FROM private.apple_tokens WHERE user_id = account_row.id
        AND extract(epoch FROM captured_at) > p_event_time)
    THEN
      DELETE FROM auth.users WHERE id = account_row.id;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.apple_store_tokens(uuid,text,text,text,text),
  public.apple_claim_revoke_jobs(uuid,integer), public.apple_finish_revoke_job(uuid,uuid,boolean,text),
  public.apple_process_notification(text,text,text,bigint),
  public.account_claim_cleanup_jobs(uuid,integer), public.account_finish_cleanup_job(uuid,uuid,boolean,text),
  public.account_cleanup_pending(uuid), public.apple_lifecycle_health(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apple_store_tokens(uuid,text,text,text,text),
  public.apple_claim_revoke_jobs(uuid,integer), public.apple_finish_revoke_job(uuid,uuid,boolean,text),
  public.apple_process_notification(text,text,text,bigint),
  public.account_claim_cleanup_jobs(uuid,integer), public.account_finish_cleanup_job(uuid,uuid,boolean,text),
  public.account_cleanup_pending(uuid), public.apple_lifecycle_health(text[]) TO service_role;

-- Remove pre-existing ordinary orphans, then enforce referential cleanup even
-- when an account is deleted through a different trusted Auth administration path.
DELETE FROM public.app_feedback t WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = t.user_id);
DELETE FROM public.notification_user_windows t WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = t.user_id);
DELETE FROM public.user_notification_sends t WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = t.user_id);
ALTER TABLE public.app_feedback ADD CONSTRAINT app_feedback_account_fk
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE public.notification_user_windows ADD CONSTRAINT notification_user_windows_account_fk
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE public.user_notification_sends ADD CONSTRAINT user_notification_sends_account_fk
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

COMMIT;
