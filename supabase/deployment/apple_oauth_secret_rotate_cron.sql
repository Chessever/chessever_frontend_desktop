-- OPERATOR-APPLIED ONLY, after the apple-oauth-secret-rotate function and its
-- secrets (APPLE_OAUTH_ROTATION_SECRET, SUPABASE_MANAGEMENT_TOKEN) are live.
-- Never put a secret value in this file or in cron.job.command.
-- Prerequisites: pg_cron + pg_net enabled; Vault names provisioned securely:
--   account_cleanup_project_url  = the project's public HTTPS API base URL
--                                  (already provisioned for account cleanup)
--   apple_oauth_rotation_secret  = same value as APPLE_OAUTH_ROTATION_SECRET
--
-- Weekly: each run signs a 150-day Apple client secret, so the live one is
-- always months from expiry and a few failed runs (alerted to Telegram) still
-- leave time to fix them.
BEGIN;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name='account_cleanup_project_url')
    OR NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name='apple_oauth_rotation_secret') THEN
    RAISE EXCEPTION 'Configure Vault entries before installing cron';
  END IF;
END;
$$;
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname='apple-oauth-secret-rotate';
SELECT cron.schedule('apple-oauth-secret-rotate', '17 4 * * 1', $job$
  SELECT net.http_post(
    url := (SELECT rtrim(decrypted_secret, '/') FROM vault.decrypted_secrets
      WHERE name='account_cleanup_project_url') || '/functions/v1/apple-oauth-secret-rotate',
    headers := jsonb_build_object('Content-Type','application/json','Authorization',
      'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets
        WHERE name='apple_oauth_rotation_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
$job$);
COMMIT;
