# Guest to permanent account merge: backend contract

Status: **proposed, not deployed.** The desktop client does not call anything
described here. It ships a seam (`GuestAccountServerMerge` in
`lib/desktop/services/auth/desktop_guest_account_merger.dart`) whose only
implementation reports the server merge as unavailable.

## What the client does today

When a guest signs in from desktop (reminder, required sign-in, Settings, or
purchase):

1. While still the anonymous user, it reads the guest's rows from
   `user_favorite_players`, `user_favorite_events`, `user_folders`,
   `user_saved_analyses`, `book_subscriptions`, `user_engine_settings` and
   `user_notification_preferences`, and writes a snapshot file to application
   support. If that read fails the sign-in is not started.
2. After the switch it reads the destination's rows, plans the writes with
   `planGuestAccountMerge`, and applies them as the new user:
   - documents get deterministic ids (`deriveGuestMergeRowId`) and are upserted
     on `id` with `ignoreDuplicates`, so a retry is a no-op;
   - relationships reuse existing conflict targets
     (`user_id,player_name`, `user_id,event_id`), or ignore `23505` for
     `book_subscriptions`;
   - settings rows are written only when the destination has none;
   - no quota is applied, nothing is trimmed, nothing of the guest is deleted.
3. The snapshot is deleted only after every write succeeded. A failure keeps
   it and the next sign-in replays it.

This covers both a brand-new identity and an existing account, for everything
the guest could read before signing in.

## Why a server merge is still needed

The client cannot:

- prove to the database that the person now signed in controlled the guest;
- read or re-own guest rows after the switch (RLS hides them), so data written
  by the guest from another device after the snapshot is not carried;
- clean up the orphaned anonymous user and its rows;
- carry tables it has no RLS write path for.

## Proposed schema and RPCs

Names below are proposals. Rename freely; the client seam does not assume them.

```sql
-- One-time claim minted by the guest before signing in.
create table if not exists public.guest_merge_claims (
  token_hash      text primary key,
  guest_user_id   uuid not null references auth.users (id) on delete cascade,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null default now() + interval '30 minutes',
  consumed_at     timestamptz,
  target_user_id  uuid references auth.users (id),
  result          jsonb
);

alter table public.guest_merge_claims enable row level security;
-- No policies: only the security definer functions below touch this table.

-- Called while signed in as the guest. Returns the raw token once.
create or replace function public.create_guest_merge_claim()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_token text := encode(gen_random_bytes(32), 'hex');
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  if not coalesce((select is_anonymous from auth.users where id = v_uid), false) then
    raise exception 'only a guest can create a merge claim' using errcode = '42501';
  end if;
  insert into guest_merge_claims (token_hash, guest_user_id)
  values (encode(digest(v_token, 'sha256'), 'hex'), v_uid);
  return v_token;
end;
$$;

-- Called after signing in as the permanent account. Idempotent: replaying a
-- consumed claim for the same target returns the stored result.
create or replace function public.merge_guest_account(p_claim_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target uuid := auth.uid();
  v_claim guest_merge_claims%rowtype;
  v_result jsonb;
begin
  if v_target is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  if coalesce((select is_anonymous from auth.users where id = v_target), true) then
    raise exception 'target must be a permanent account' using errcode = '42501';
  end if;

  select * into v_claim
  from guest_merge_claims
  where token_hash = encode(digest(p_claim_token, 'sha256'), 'hex')
  for update;

  if not found then
    raise exception 'unknown claim' using errcode = '42501';
  end if;
  if v_claim.consumed_at is not null then
    if v_claim.target_user_id = v_target then
      return v_claim.result;
    end if;
    raise exception 'claim already used' using errcode = '42501';
  end if;
  if v_claim.expires_at < now() then
    raise exception 'claim expired' using errcode = '42501';
  end if;
  if v_claim.guest_user_id = v_target then
    raise exception 'guest and target are the same user' using errcode = '22023';
  end if;

  -- Relationships: destination wins, duplicates merge.
  insert into user_favorite_players (user_id, fide_id, player_name, metadata)
  select v_target, fide_id, player_name, metadata
  from user_favorite_players where user_id = v_claim.guest_user_id
  on conflict (user_id, player_name) do nothing;

  insert into user_favorite_events (user_id, event_id, event_name, metadata)
  select v_target, event_id, event_name, metadata
  from user_favorite_events where user_id = v_claim.guest_user_id
  on conflict (user_id, event_id) do nothing;

  insert into book_subscriptions (folder_id, subscriber_id)
  select folder_id, v_target
  from book_subscriptions where subscriber_id = v_claim.guest_user_id
  on conflict do nothing;

  -- Documents: re-own rather than copy, so ids, parents and folder links are
  -- preserved exactly. Adjust permanent-folder handling (My Folder,
  -- My Database, and the is_liked_games collection) to match the client
  -- planner before deploying: map guest permanent folders onto the target's
  -- and move their children, instead of re-owning a second copy.
  update user_saved_analyses set user_id = v_target
  where user_id = v_claim.guest_user_id;
  update user_folders set user_id = v_target, share_token = null
  where user_id = v_claim.guest_user_id;

  -- Settings: only when the target has none.
  insert into user_engine_settings
  select (jsonb_populate_record(null::user_engine_settings,
          to_jsonb(s) || jsonb_build_object('user_id', v_target))).*
  from user_engine_settings s where s.user_id = v_claim.guest_user_id
  on conflict (user_id) do nothing;

  insert into user_notification_preferences
  select (jsonb_populate_record(null::user_notification_preferences,
          to_jsonb(p) || jsonb_build_object('user_id', v_target))).*
  from user_notification_preferences p where p.user_id = v_claim.guest_user_id
  on conflict (user_id) do nothing;

  -- Never touched: subscriptions / entitlements of either user.

  v_result := jsonb_build_object(
    'guest_user_id', v_claim.guest_user_id,
    'target_user_id', v_target,
    'merged_at', now()
  );
  update guest_merge_claims
  set consumed_at = now(), target_user_id = v_target, result = v_result
  where token_hash = v_claim.token_hash;
  return v_result;
end;
$$;

revoke all on function public.create_guest_merge_claim() from public;
revoke all on function public.merge_guest_account(text) from public;
grant execute on function public.create_guest_merge_claim() to authenticated;
grant execute on function public.merge_guest_account(text) to authenticated;
```

Before deploying, confirm against the live schema:

- the unique indexes `user_favorite_players (user_id, player_name)`,
  `user_favorite_events (user_id, event_id)`, `user_engine_settings (user_id)`,
  `user_notification_preferences (user_id)` and a unique key on
  `book_subscriptions (folder_id, subscriber_id)`;
- that `pgcrypto` is enabled (`gen_random_bytes`, `digest`);
- that anonymous users get the `authenticated` role (Supabase default).

## Client work once deployed

1. Call `create_guest_merge_claim()` in `DesktopGuestAccountMerger.captureGuest`
   and keep the token inside the pending snapshot file.
2. Implement `GuestAccountServerMerge` with `merge_guest_account(token)` and
   pass it to the merger. It is used only when the sign-in landed on an
   existing account; the client replay stays as the fallback.
