-- OPERATOR-APPLIED ONLY, after migration, secrets and function deployment.
-- Never put a secret value in this file or in cron.job.command.
-- Prerequisites: pg_cron + pg_net enabled; Vault names provisioned securely:
--   account_cleanup_project_url = the project's public HTTPS API base URL
--   account_cleanup_worker_secret = same as ACCOUNT_CLEANUP_CRON_SECRET
BEGIN;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name='account_cleanup_project_url')
    OR NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name='account_cleanup_worker_secret') THEN
    RAISE EXCEPTION 'Configure cleanup Vault entries before installing cron';
  END IF;
END;
$$;
-- Replace by name on repeated operator setup, never create duplicate workers.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname='account-data-cleanup';
SELECT cron.schedule('account-data-cleanup', '* * * * *', $job$
  SELECT net.http_post(
    url := (SELECT rtrim(decrypted_secret, '/') FROM vault.decrypted_secrets
      WHERE name='account_cleanup_project_url') || '/functions/v1/account-data-cleanup',
    headers := jsonb_build_object('Content-Type','application/json','Authorization',
      'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets
        WHERE name='account_cleanup_worker_secret')),
    body := '{"limit":10}'::jsonb,
    timeout_milliseconds := 60000
  );
$job$);
COMMIT;
