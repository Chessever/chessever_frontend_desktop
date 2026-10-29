\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, description text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', description; END IF; END;
$$;
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM public.app_feedback), 'historical feedback orphan removed');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM public.notification_user_windows), 'historical window orphan removed');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM public.user_notification_sends), 'historical send orphan removed');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.delete_user_account()','EXECUTE'), 'anonymous role denied');
SELECT pg_temp.assert_true(has_function_privilege('authenticated','public.delete_user_account()','EXECUTE'), 'old authenticated grant retained');
SELECT pg_temp.assert_true(has_function_privilege('service_role','public.delete_user_account()','EXECUTE'), 'old service grant retained');
SELECT pg_temp.assert_true(NOT has_table_privilege('authenticated','private.apple_tokens','SELECT'), 'token table inaccessible');
SELECT pg_temp.assert_true(NOT has_table_privilege('authenticated','private.apple_revoke_jobs','SELECT'), 'revocation table inaccessible');
SET LOCAL ROLE authenticated;
SELECT public.existing_partner_api_probe() AS existing_partner_result \gset
RESET ROLE;
SELECT pg_temp.assert_true(:'existing_partner_result'='preserved', 'existing public invoker/private definer API survives');
SELECT pg_temp.assert_true(public.apple_lifecycle_health(ARRAY['test-v1']), 'read-only lifecycle health');
SELECT pg_temp.assert_true(NOT public.apple_lifecycle_health(ARRAY[]::text[]), 'health requires configured encryption keys');
SELECT pg_temp.assert_true(NOT EXISTS (
  SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND (p.proname LIKE 'apple_%' OR p.proname LIKE 'account_%')
  AND (has_function_privilege('authenticated',p.oid,'EXECUTE') OR has_function_privilege('anon',p.oid,'EXECUTE'))
), 'all token and cleanup RPCs service-only');
SET LOCAL ROLE service_role;
SELECT count(*) FROM public.apple_claim_revoke_jobs('00000000-0000-4000-8000-000000000098',1);
SELECT count(*) FROM public.account_claim_cleanup_jobs('00000000-0000-4000-8000-000000000098',1);
SELECT public.apple_lifecycle_health(ARRAY['test-v1']);
RESET ROLE;

INSERT INTO auth.users(id) VALUES
 ('00000000-0000-4000-8000-000000000001'),('00000000-0000-4000-8000-000000000002'),
 ('00000000-0000-4000-8000-000000000003'),('00000000-0000-4000-8000-000000000004'),
 ('00000000-0000-4000-8000-000000000005'),('00000000-0000-4000-8000-000000000006');
INSERT INTO auth.identities(user_id,provider,provider_id) VALUES
 ('00000000-0000-4000-8000-000000000001','apple','test-apple-one'),
 ('00000000-0000-4000-8000-000000000003','apple','test-legacy'),
 ('00000000-0000-4000-8000-000000000004','apple','test-rollback'),
 ('00000000-0000-4000-8000-000000000005','apple','test-notification'),
 ('00000000-0000-4000-8000-000000000006','apple','test-new-auth');

DO $$ BEGIN
  BEGIN PERFORM public.apple_store_tokens('00000000-0000-4000-8000-000000000001','test-legacy','test-client','ciphertext-test','test-v1');
    RAISE EXCEPTION 'identity mismatch accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.delete_user_account(); RAISE EXCEPTION 'no auth accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END; $$;
SET LOCAL ROLE service_role;
SELECT public.apple_store_tokens('00000000-0000-4000-8000-000000000001','test-apple-one','test-client','ciphertext-test','test-v1');
SELECT public.apple_store_tokens('00000000-0000-4000-8000-000000000001','test-apple-one','test-client','ciphertext-test','test-v1');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM private.apple_tokens), 'same client capture idempotent');
SELECT pg_temp.assert_true(NOT public.apple_lifecycle_health(ARRAY['missing-key']), 'health detects retained token key missing');
INSERT INTO public.app_feedback(user_id,feedback) VALUES ('00000000-0000-4000-8000-000000000001','private feedback'),('00000000-0000-4000-8000-000000000002','other user');
INSERT INTO public.notification_user_windows VALUES ('00000000-0000-4000-8000-000000000001');
INSERT INTO public.user_notification_sends VALUES ('00000000-0000-4000-8000-000000000001');
INSERT INTO public.payment_analytics_outbox VALUES ('00000000-0000-4000-8000-000000000001','test-device','synthetic-app');
INSERT INTO public.affiliate_conversions(referred_user_id,revenue_usd,purchase_metadata)
 VALUES ('00000000-0000-4000-8000-000000000001',19.99,
  '{"email":"synthetic@example.invalid","attribution":{"campaign_name":"private-campaign"},"ledger_correction":{"canonical_conversion_id":"test-correction"},"commission":{"revenue_usd":19.99},"product":{"tier":1,"supabase_user_id":"00000000-0000-4000-8000-000000000001"},"subscription_metadata":{"interval":"month","supabase_user_id":"00000000-0000-4000-8000-000000000001"}}');
INSERT INTO public.partner_agreement_acceptances VALUES ('00000000-0000-4000-8000-000000000001','synthetic@example.invalid','test-v1');
INSERT INTO public.broadcast_tournaments VALUES ('00000000-0000-4000-8000-000000000001','shared tournament');
INSERT INTO broadcasting_private.event_delegation_events VALUES ('00000000-0000-4000-8000-000000000001','synthetic@example.invalid');
INSERT INTO broadcasting_private.video_stream_events VALUES ('00000000-0000-4000-8000-000000000001','synthetic@example.invalid');
INSERT INTO auth.sessions(user_id) VALUES ('00000000-0000-4000-8000-000000000001');
INSERT INTO auth.refresh_tokens(user_id) VALUES ('00000000-0000-4000-8000-000000000001');
INSERT INTO public.chat_conversations(user_id) VALUES ('00000000-0000-4000-8000-000000000001');
INSERT INTO public.chat_messages(conversation_id,user_id,content)
 SELECT id,user_id,'private chat' FROM public.chat_conversations;
INSERT INTO public.user_folders(user_id) VALUES ('00000000-0000-4000-8000-000000000001');
INSERT INTO public.user_saved_analyses SELECT user_id,id FROM public.user_folders;
INSERT INTO storage.objects(bucket_id,name) VALUES
 ('profile-avatars','00000000-0000-4000-8000-000000000001/10000000-0000-4000-8000-000000000001.jpg'),
 ('profile-avatars','00000000-0000-4000-8000-000000000002/10000000-0000-4000-8000-000000000002.jpg'),
 ('payout-receipts','legally-retained.pdf');
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
-- A malicious temp name cannot shadow any fully qualified cleanup target.
CREATE TEMP TABLE app_feedback(user_id uuid);
SET LOCAL ROLE authenticated;
SELECT public.delete_user_account() AS deletion_result \gset
RESET ROLE;
SELECT pg_temp.assert_true(:'deletion_result'::jsonb = '{"deleted":true,"apple_manual_revoke_required":false}', 'stored Apple deletion result');
SELECT pg_temp.assert_true(EXISTS(SELECT FROM auth.users WHERE id='00000000-0000-4000-8000-000000000002'), 'another identity preserved');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.app_feedback), 'only caller feedback removed');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM public.notification_user_windows), 'windows removed');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM public.user_notification_sends), 'sends removed');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM public.payment_analytics_outbox), 'analytics outbox removed');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM auth.sessions), 'sessions cascade removed');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM auth.refresh_tokens), 'legacy refresh rows removed');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM public.chat_messages), 'private chat cascade removed');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM public.user_saved_analyses), 'private analysis cascade removed');
SELECT pg_temp.assert_true((SELECT referred_user_id IS NULL AND revenue_usd=19.99
  AND purchase_metadata='{"ledger_correction":{"canonical_conversion_id":"test-correction"},"commission":{"revenue_usd":19.99},"product":{"tier":1},"subscription_metadata":{"interval":"month"}}'::jsonb
  FROM public.affiliate_conversions), 'finance metadata and ledger corrections retained without observed profile copies');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.partner_agreement_acceptances), 'legal evidence retained');
SELECT pg_temp.assert_true((SELECT created_by IS NULL AND name='shared tournament' FROM public.broadcast_tournaments), 'shared content credit unlinked');
SELECT pg_temp.assert_true((SELECT actor_id IS NULL AND actor_email IS NULL FROM broadcasting_private.event_delegation_events), 'audit ordinary email removed');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM broadcasting_private.video_stream_events), 'video audit removed');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM private.apple_revoke_jobs), 'encrypted Apple handoff survives auth deletion');
SELECT pg_temp.assert_true(NOT public.apple_lifecycle_health(ARRAY['missing-key']), 'health detects queued ciphertext key missing');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM private.apple_tokens), 'active token cascade removed');
SELECT pg_temp.assert_true((SELECT count(*)=3 FROM storage.objects), 'SQL never deletes storage metadata');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM private.account_cleanup_jobs WHERE kind='storage'), 'only own service-uploaded avatar queued');
SELECT pg_temp.assert_true(EXISTS(SELECT FROM private.account_cleanup_jobs WHERE kind='appsflyer'
  AND payload->'identities' @> '[{"appsflyer_id":"test-device","app_id":"synthetic-app"}]'::jsonb), 'processor identity mapping survives source cleanup');

-- A stale JWT cannot target an alternate user or replay deletion.
DO $$ BEGIN
  BEGIN PERFORM public.delete_user_account(); RAISE EXCEPTION 'deleted JWT accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.apple_store_tokens('00000000-0000-4000-8000-000000000001','test-apple-one','test-client','ciphertext-test','test-v1');
    RAISE EXCEPTION 'late capture accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
END; $$;

-- Legacy Apple still deletes, without requiring reauthentication or credentials.
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000003',true);
SELECT pg_temp.assert_true(public.delete_user_account() = '{"deleted":true,"apple_manual_revoke_required":true}'::jsonb, 'legacy Apple fallback allowed');
UPDATE auth.users SET is_anonymous=true WHERE id='00000000-0000-4000-8000-000000000002';
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
SELECT pg_temp.assert_true(public.delete_user_account() = '{"deleted":true,"apple_manual_revoke_required":false}'::jsonb, 'guest deletion supported');

-- Inject handoff failure: no identity, token, feedback, or session may disappear.
SELECT public.apple_store_tokens('00000000-0000-4000-8000-000000000004','test-rollback','test-client','ciphertext-rollback','test-v1');
INSERT INTO public.app_feedback(user_id,feedback) VALUES ('00000000-0000-4000-8000-000000000004','must survive');
CREATE FUNCTION pg_temp.reject_handoff() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic handoff failure'; END; $$;
CREATE TRIGGER reject_handoff BEFORE INSERT ON private.apple_revoke_jobs FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_handoff();
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000004',true);
DO $$ BEGIN
  BEGIN PERFORM public.delete_user_account(); RAISE EXCEPTION 'unexpected delete success';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'synthetic handoff failure' THEN RAISE; END IF; END;
END; $$;
SELECT pg_temp.assert_true(EXISTS(SELECT FROM auth.users WHERE id='00000000-0000-4000-8000-000000000004'), 'handoff failure identity rollback');
SELECT pg_temp.assert_true(EXISTS(SELECT FROM public.app_feedback WHERE feedback='must survive'), 'handoff failure data rollback');
SELECT pg_temp.assert_true(EXISTS(SELECT FROM private.apple_tokens WHERE user_id='00000000-0000-4000-8000-000000000004'), 'handoff failure token rollback');
DROP TRIGGER reject_handoff ON private.apple_revoke_jobs;
-- A later generic cleanup handoff failure also rolls the earlier Apple enqueue
-- back, proving the transaction cannot leave half an account or duplicate jobs.
CREATE TRIGGER reject_cleanup BEFORE INSERT ON private.account_cleanup_jobs FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_handoff();
DO $$ BEGIN
  BEGIN PERFORM public.delete_user_account(); RAISE EXCEPTION 'unexpected delete success';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'synthetic handoff failure' THEN RAISE; END IF; END;
END; $$;
SELECT pg_temp.assert_true(EXISTS(SELECT FROM auth.users WHERE id='00000000-0000-4000-8000-000000000004'), 'cleanup handoff failure identity rollback');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM private.apple_revoke_jobs WHERE user_id='00000000-0000-4000-8000-000000000004'), 'cleanup failure rolls earlier Apple enqueue back');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM private.account_cleanup_jobs WHERE user_id='00000000-0000-4000-8000-000000000004'), 'cleanup failure leaves no partial jobs');
DROP TRIGGER reject_cleanup ON private.account_cleanup_jobs;

-- Lease claiming, bounded retries, stale acknowledgements and deletion of secrets.
CREATE TEMP TABLE first_claim AS SELECT * FROM public.apple_claim_revoke_jobs(NULL,10);
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM first_claim), 'claim returns available job');
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM public.apple_claim_revoke_jobs(NULL,10)), 'active lease excluded');
UPDATE private.apple_revoke_jobs SET lease_until=clock_timestamp()-interval '1 second';
CREATE TEMP TABLE second_claim AS SELECT * FROM public.apple_claim_revoke_jobs(NULL,10);
SELECT public.apple_finish_revoke_job(id,lease_token,true,NULL) FROM first_claim;
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM private.apple_revoke_jobs), 'stale worker cannot acknowledge reassigned job');
SELECT public.apple_finish_revoke_job(id,lease_token,false,'DO NOT STORE UPSTREAM BODY') FROM second_claim;
SELECT pg_temp.assert_true((SELECT last_error_code='request_failed' AND next_attempt_at>now() AND lease_token IS NULL FROM private.apple_revoke_jobs), 'safe error and retry backoff');
UPDATE private.apple_revoke_jobs SET next_attempt_at=clock_timestamp();
SELECT public.apple_finish_revoke_job(id,lease_token,true,NULL) FROM public.apple_claim_revoke_jobs(NULL,10);
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM private.apple_revoke_jobs), 'successful ack destroys ciphertext');
INSERT INTO private.apple_revoke_jobs(user_id,apple_sub,client_id,encrypted_tokens,key_id)
 SELECT '00000000-0000-4000-8000-000000000009','synthetic-limit','test-client','synthetic-limit-cipher','test-v1' FROM generate_series(1,150);
SELECT pg_temp.assert_true((SELECT count(*)=100 FROM public.apple_claim_revoke_jobs('00000000-0000-4000-8000-000000000009',10000)), 'SQL claim max limit enforced');
SELECT pg_temp.assert_true((SELECT count(*)=50 FROM public.apple_claim_revoke_jobs('00000000-0000-4000-8000-000000000009',10000)), 'leased rows skipped in bounded batch');

CREATE TEMP TABLE cleanup_claim AS SELECT * FROM public.account_claim_cleanup_jobs('00000000-0000-4000-8000-000000000001',1000);
SELECT pg_temp.assert_true((SELECT count(*)=6 FROM cleanup_claim), 'cleanup claims only selected account');
UPDATE private.account_cleanup_jobs SET lease_until=clock_timestamp()-interval '1 second' WHERE user_id='00000000-0000-4000-8000-000000000001';
CREATE TEMP TABLE cleanup_reclaim AS SELECT * FROM public.account_claim_cleanup_jobs('00000000-0000-4000-8000-000000000001',10);
SELECT public.account_finish_cleanup_job(id,lease_token,true,NULL) FROM cleanup_claim;
SELECT pg_temp.assert_true(public.account_cleanup_pending('00000000-0000-4000-8000-000000000001'), 'stale cleanup ack cannot erase work');
SELECT public.account_finish_cleanup_job(id,lease_token,true,NULL) FROM cleanup_reclaim;
SELECT pg_temp.assert_true(NOT public.account_cleanup_pending('00000000-0000-4000-8000-000000000001'), 'cleanup status clears after all jobs');

-- Signed Apple notifications have service-only dedupe and stale-authorization guard.
SELECT public.apple_store_tokens('00000000-0000-4000-8000-000000000006','test-new-auth','test-client','ciphertext-new','test-v1');
SELECT public.apple_process_notification('test-old-event','test-new-auth','consent-revoked',extract(epoch FROM now())::bigint-3600);
SELECT pg_temp.assert_true(EXISTS(SELECT FROM auth.users WHERE id='00000000-0000-4000-8000-000000000006'), 'old event preserves later authorization');
UPDATE private.apple_tokens SET captured_at=date_trunc('second',clock_timestamp())+interval '900 milliseconds'
  WHERE user_id='00000000-0000-4000-8000-000000000006';
SELECT public.apple_process_notification('test-same-second-event','test-new-auth','consent-revoked',
  floor(extract(epoch FROM clock_timestamp()))::bigint);
SELECT pg_temp.assert_true(EXISTS(SELECT FROM auth.users WHERE id='00000000-0000-4000-8000-000000000006'), 'same-second delayed event preserves newer capture');
SELECT public.apple_process_notification('test-delete-event','test-notification','account-deleted',extract(epoch FROM clock_timestamp())::bigint);
SELECT public.apple_process_notification('test-delete-event','test-notification','account-deleted',extract(epoch FROM clock_timestamp())::bigint);
SELECT pg_temp.assert_true(NOT EXISTS(SELECT FROM auth.users WHERE id='00000000-0000-4000-8000-000000000005'), 'Apple account-deleted performs same cleanup');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM private.apple_notification_receipts WHERE jti='test-delete-event'), 'notification replay deduplicated');
ROLLBACK;
\echo Account deletion SQL regression checks passed.
