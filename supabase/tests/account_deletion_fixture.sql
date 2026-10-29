-- Minimal production-shaped schema. Used only by the isolated local runner.
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role;
CREATE SCHEMA auth;
CREATE SCHEMA storage;
CREATE SCHEMA broadcasting_private;
-- Existing production pattern: public invoker wrappers require private USAGE.
CREATE SCHEMA private;
GRANT USAGE ON SCHEMA private TO authenticated;
CREATE FUNCTION private.existing_partner_api_probe() RETURNS text
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ SELECT 'preserved'::text; $$;
REVOKE ALL ON FUNCTION private.existing_partner_api_probe() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.existing_partner_api_probe() TO authenticated;
CREATE FUNCTION public.existing_partner_api_probe() RETURNS text
LANGUAGE sql SECURITY INVOKER AS $$ SELECT private.existing_partner_api_probe(); $$;
CREATE TABLE auth.users(id uuid PRIMARY KEY, created_at timestamptz DEFAULT now(), is_anonymous boolean DEFAULT false);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
CREATE TABLE auth.identities(user_id uuid REFERENCES auth.users ON DELETE CASCADE,
  provider text, provider_id text, identity_data jsonb DEFAULT '{}');
CREATE TABLE auth.sessions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid REFERENCES auth.users ON DELETE CASCADE);
CREATE TABLE auth.refresh_tokens(user_id text, session_id uuid REFERENCES auth.sessions ON DELETE CASCADE);
CREATE TABLE storage.objects(bucket_id text, name text, owner_id text, owner uuid);
CREATE TABLE public.app_feedback(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL, feedback text);
CREATE TABLE public.notification_user_windows(user_id uuid NOT NULL);
CREATE TABLE public.user_notification_sends(user_id uuid NOT NULL);
CREATE TABLE public.payment_analytics_outbox(user_id uuid, appsflyer_id text, app_id text);
CREATE TABLE public.affiliate_conversions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referred_user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  revenue_usd numeric, purchase_metadata jsonb NOT NULL DEFAULT '{}');
CREATE TABLE public.affiliate_discount_codes(created_by text);
CREATE TABLE public.affiliate_payouts(uploaded_by text, amount_usd numeric);
CREATE TABLE public.broadcast_tournaments(created_by text, name text);
CREATE TABLE public.partner_agreement_acceptances(user_id uuid, email text, version text);
CREATE TABLE public.chat_conversations(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid REFERENCES auth.users ON DELETE CASCADE);
CREATE TABLE public.chat_messages(id uuid DEFAULT gen_random_uuid(), conversation_id uuid REFERENCES public.chat_conversations ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users ON DELETE CASCADE, content text);
CREATE TABLE public.user_folders(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid REFERENCES auth.users ON DELETE CASCADE);
CREATE TABLE public.user_saved_analyses(user_id uuid REFERENCES auth.users ON DELETE CASCADE, folder_id uuid REFERENCES public.user_folders ON DELETE CASCADE);
CREATE TABLE broadcasting_private.event_delegation_events(actor_id uuid REFERENCES auth.users ON DELETE SET NULL, actor_email text);
CREATE TABLE broadcasting_private.game_override_events(actor_id uuid REFERENCES auth.users ON DELETE SET NULL, actor_email text);
CREATE TABLE broadcasting_private.tour_approval_events(actor_id uuid REFERENCES auth.users ON DELETE SET NULL, actor_email text);
CREATE TABLE broadcasting_private.video_stream_events(actor_id uuid NOT NULL, actor_email text);
CREATE TABLE broadcasting_private.event_writer_preparations(prepared_by uuid REFERENCES auth.users ON DELETE SET NULL, prepared_by_email text);
CREATE TABLE broadcasting_private.event_writer_transitions(requested_by uuid REFERENCES auth.users ON DELETE SET NULL, requested_by_email text);
CREATE FUNCTION public.delete_user_account() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN DELETE FROM auth.users WHERE id=auth.uid(); END;
$$;
REVOKE ALL ON FUNCTION public.delete_user_account() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_user_account() TO authenticated,service_role;
-- Historical ordinary orphans must be removed by the migration.
INSERT INTO public.app_feedback(user_id,feedback) VALUES ('00000000-0000-4000-8000-000000000099','orphan');
INSERT INTO public.notification_user_windows VALUES ('00000000-0000-4000-8000-000000000099');
INSERT INTO public.user_notification_sends VALUES ('00000000-0000-4000-8000-000000000099');
