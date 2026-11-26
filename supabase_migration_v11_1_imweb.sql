-- 우리사이 v11.1: 아임웹 결제 → 속마음 리포트 자동 열기 (server-side poller state).
-- Run AFTER supabase_migration_v11_paywall.sql. Safe to run more than once. Rollback: supabase_migration_v11_1_imweb_down.sql
-- Tests: scripts/test_v11_1.sql (scripts/run_local_sql_tests.sh). Scheduler: supabase_cron_v11_1_imweb.sql (separate, run after deploy).
--
-- Flow
-- * Edge Function imweb-poll (supabase/functions/imweb-poll) runs every minute (pg_cron + pg_net, shared secret header).
--   It reads recent 아임웹 orders for prodNo 11, extracts the buyer's 결제 확인 코드 (UR-XXXXXX) and calls
--   public.imweb_poll_apply(...) per order item with action 'paid' | 'revoke' | 'no_code'.
-- * Each order item is remembered in private.imweb_order_items with its last state, so repeats are no-ops.
-- * 'paid'  -> private.set_couple_paid(code, true, 'imweb', '<orderNo>/<itemKey>', 30 * qty): one pass per order item,
--   30 days per unit of the item's quantity (qty 1..12; the 아임웹 product allows 1 per order today)
--   (v11 private.couple_passes; buying again stacks). Unknown code -> state 'unknown_code', nothing unlocked.
-- * 'revoke' (refund / cancel / return) -> only if THIS order item had been applied as paid: takes back that item's pass
--   (set_couple_paid(code, false, 'imweb', ref)) and paid_until is replayed from the passes left, so other orders and
--   manual unlocks keep their days. A revoke for an item we never saw paid only records the state.
-- * paid again after a revoke (e.g. cancel request rejected) brings the same pass back (same paid_at), never a second one.
-- * 아임웹 OAuth tokens live in private.imweb_oauth (single row). The refresh token rotates: the function writes the new pair
--   back with compare-and-swap on the old refresh token (public.imweb_poll_save_tokens), under a short lease that keeps two
--   runs from refreshing at once.
--
-- Security
-- * New tables in schema private, RLS on, no policies, nothing granted to anon/authenticated/PUBLIC.
-- * public.imweb_poll_* : SECURITY DEFINER, pinned search_path, EXECUTE for service_role only (the Edge Function).
-- * private.imweb_seed_tokens: postgres only (owner seeds the first token pair once from the SQL editor / psql).
-- * Tokens are never returned except by imweb_poll_lease (service_role); nothing here logs codes or buyer data.

begin;

-- paid_source / pass source gain 'imweb'
alter table private.couple_entitlements drop constraint if exists couple_entitlements_paid_source_check;
alter table private.couple_entitlements add constraint couple_entitlements_paid_source_check
  check (paid_source in ('manual', 'portone', 'inicis', 'payapp', 'imweb'));
alter table private.couple_passes drop constraint if exists couple_passes_source_check;
alter table private.couple_passes add constraint couple_passes_source_check
  check (source in ('manual', 'portone', 'inicis', 'payapp', 'imweb'));

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists private.imweb_oauth (
  id boolean primary key default true check (id),
  access_token text check (access_token is null or char_length(access_token) between 1 and 4000),
  refresh_token text not null check (char_length(refresh_token) between 1 and 4000),
  token_updated_at timestamptz not null default now(),
  lease_id uuid,
  lease_until timestamptz,
  last_run_at timestamptz,
  last_ok_at timestamptz,
  last_status text check (last_status is null or last_status ~ '^[a-z_]{1,40}$'),
  updated_at timestamptz not null default now()
);

create table if not exists private.imweb_order_items (
  order_no bigint not null check (order_no > 0),
  item_key text not null check (char_length(item_key) between 1 and 100),
  pay_code text check (pay_code is null or pay_code ~ '^UR-[A-Z0-9]{6}$'),
  state text not null check (state in ('paid', 'revoked', 'unknown_code', 'no_code')),
  qty integer not null default 1 check (qty between 1 and 12),
  first_seen_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (order_no, item_key)
);
alter table private.imweb_order_items add column if not exists qty integer not null default 1 check (qty between 1 and 12);
create index if not exists imweb_order_items_code_idx on private.imweb_order_items(pay_code) where state = 'paid';

alter table private.imweb_oauth enable row level security;
alter table private.imweb_order_items enable row level security;
revoke all on private.imweb_oauth, private.imweb_order_items from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Owner: seed / replace the token pair (postgres only)
--   select private.imweb_seed_tokens(:'access', :'refresh');
-- ---------------------------------------------------------------------------
create or replace function private.imweb_seed_tokens(p_access text, p_refresh text)
returns boolean language plpgsql volatile security definer set search_path = private, pg_temp as $$
begin
  if p_refresh is null or char_length(btrim(p_refresh)) = 0 then raise exception 'refresh_token_required'; end if;
  -- validate here (generic message) so a CHECK violation can never echo token values in an error DETAIL / server log
  if char_length(btrim(p_refresh)) > 4000 or char_length(coalesce(btrim(p_access), '')) > 4000 then
    raise exception 'token_too_long';
  end if;
  insert into private.imweb_oauth(id, access_token, refresh_token) values (true, nullif(btrim(p_access), ''), btrim(p_refresh))
  on conflict (id) do update set access_token = excluded.access_token, refresh_token = excluded.refresh_token,
    token_updated_at = now(), lease_id = null, lease_until = null, updated_at = now();
  return true;
end $$;
revoke all on function private.imweb_seed_tokens(text, text) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Poller RPCs (service_role only)
-- ---------------------------------------------------------------------------
-- Take the run lease. Returns {lease, access_token, refresh_token} or null when another run holds it / not seeded.
create or replace function public.imweb_poll_lease(p_seconds integer default 55)
returns jsonb language plpgsql volatile security definer set search_path = private, pg_temp as $$
declare o private.imweb_oauth; v_lease uuid := gen_random_uuid();
begin
  update private.imweb_oauth set lease_id = v_lease,
    lease_until = now() + make_interval(secs => least(greatest(coalesce(p_seconds, 55), 10), 300)),
    last_run_at = now(), updated_at = now()
  where id and (lease_until is null or lease_until < now())
  returning * into o;
  if not found then return null; end if;
  return jsonb_build_object('lease', o.lease_id, 'access_token', o.access_token, 'refresh_token', o.refresh_token);
end $$;

-- Write a refreshed token pair. Compare-and-swap on the refresh token that was used, so a rotated token is never
-- overwritten by a stale run. Returns false when the stored refresh token changed in the meantime.
-- p_lease is deliberately NOT part of the condition: by the time this runs 아임웹 has already spent p_old_refresh, so if the
-- DB still holds p_old_refresh the new pair is the only valid one and must be kept even if this run's lease expired
-- (dropping it would strand the DB on a dead refresh token). The refresh-token CAS alone stops stale overwrites.
-- Lengths are checked here so a CHECK violation can never echo token values in an error DETAIL / server log.
create or replace function public.imweb_poll_save_tokens(p_lease uuid, p_old_refresh text, p_access text, p_refresh text)
returns boolean language plpgsql volatile security definer set search_path = private, pg_temp as $$
begin
  if p_old_refresh is null or p_access is null or char_length(p_access) not between 1 and 4000
     or char_length(coalesce(p_refresh, '')) > 4000 then return false; end if;
  update private.imweb_oauth set access_token = p_access,
    refresh_token = coalesce(nullif(p_refresh, ''), refresh_token),
    token_updated_at = now(), updated_at = now()
  where id and refresh_token = p_old_refresh;
  return found;
end $$;

-- Apply one order item. p_action: 'paid' | 'revoke' | 'no_code'. p_qty: the item's quantity (pass = 30 * p_qty days).
-- Returns one of 'unlocked', 'revoked', 'recorded', 'unknown_code', 'no_code', 'unchanged', 'bad_input', 'no_lease'.
drop function if exists public.imweb_poll_apply(uuid, bigint, text, text, text); -- pre-quantity signature
create or replace function public.imweb_poll_apply(p_lease uuid, p_order_no bigint, p_item_key text, p_action text, p_pay_code text,
  p_qty integer default 1)
returns text language plpgsql volatile security definer set search_path = private, pg_temp as $$
declare
  r private.imweb_order_items;
  v_code text := nullif(upper(btrim(coalesce(p_pay_code, ''))), '');
  v_ref text := p_order_no::text || '/' || p_item_key; -- the 30-day pass this item adds
begin
  if not exists (select 1 from private.imweb_oauth where id and lease_id = p_lease and lease_until > now()) then
    return 'no_lease';
  end if;
  if p_order_no is null or p_order_no <= 0 or p_item_key is null or char_length(p_item_key) not between 1 and 100
     or p_action not in ('paid', 'revoke', 'no_code') or p_qty is null or p_qty not between 1 and 12
     or (v_code is not null and v_code !~ '^UR-[A-Z0-9]{6}$') then
    return 'bad_input';
  end if;

  -- serialize work on this item
  perform pg_advisory_xact_lock(hashtextextended('imweb:' || p_order_no || ':' || p_item_key, 0));
  select * into r from private.imweb_order_items where order_no = p_order_no and item_key = p_item_key;

  if p_action = 'no_code' then
    if found and r.state = 'no_code' then return 'unchanged'; end if;
    if found and r.state = 'paid' then return 'unchanged'; end if; -- never downgrade a paid item on a parse miss
    insert into private.imweb_order_items(order_no, item_key, pay_code, state) values (p_order_no, p_item_key, null, 'no_code')
    on conflict (order_no, item_key) do update set state = 'no_code', updated_at = now();
    return 'no_code';
  end if;

  if p_action = 'paid' then
    if v_code is null then return 'bad_input'; end if;
    if found and r.state = 'paid' and r.pay_code = v_code and r.qty = p_qty then return 'unchanged'; end if;
    if found and r.state = 'unknown_code' and r.pay_code = v_code and r.qty = p_qty then return 'unchanged'; end if;
    begin
      perform private.set_couple_paid(v_code, true, 'imweb', v_ref, 30 * p_qty);
    exception when sqlstate 'P0002' then
      insert into private.imweb_order_items(order_no, item_key, pay_code, state, qty) values (p_order_no, p_item_key, v_code, 'unknown_code', p_qty)
      on conflict (order_no, item_key) do update set pay_code = excluded.pay_code, state = 'unknown_code', qty = excluded.qty, updated_at = now();
      return 'unknown_code';
    end;
    insert into private.imweb_order_items(order_no, item_key, pay_code, state, qty) values (p_order_no, p_item_key, v_code, 'paid', p_qty)
    on conflict (order_no, item_key) do update set pay_code = excluded.pay_code, state = 'paid', qty = excluded.qty, updated_at = now();
    return 'unlocked';
  end if;

  -- revoke
  if found and r.state = 'revoked' then return 'unchanged'; end if;
  if not found or r.state <> 'paid' then
    insert into private.imweb_order_items(order_no, item_key, pay_code, state) values (p_order_no, p_item_key, coalesce(r.pay_code, v_code), 'revoked')
    on conflict (order_no, item_key) do update set state = 'revoked', updated_at = now();
    return 'recorded';
  end if;
  v_code := r.pay_code; -- the code this item unlocked
  update private.imweb_order_items set state = 'revoked', updated_at = now() where order_no = p_order_no and item_key = p_item_key;
  begin
    -- takes back this item's 30 days only; other orders and manual unlocks keep theirs
    perform private.set_couple_paid(v_code, false, 'imweb', v_ref);
  exception when sqlstate 'P0002' then
    return 'revoked'; -- couple deleted meanwhile
  end;
  return 'revoked';
end $$;

-- Release the lease and record a short status code (no buyer data).
create or replace function public.imweb_poll_finish(p_lease uuid, p_status text)
returns boolean language plpgsql volatile security definer set search_path = private, pg_temp as $$
declare v_status text := case when p_status ~ '^[a-z_]{1,40}$' then p_status else 'invalid_status' end;
begin
  update private.imweb_oauth set lease_id = null, lease_until = null, last_status = v_status,
    last_ok_at = case when v_status = 'ok' then now() else last_ok_at end, updated_at = now()
  where id and lease_id = p_lease;
  return found;
end $$;

revoke all on function public.imweb_poll_lease(integer), public.imweb_poll_save_tokens(uuid, text, text, text),
  public.imweb_poll_apply(uuid, bigint, text, text, text, integer), public.imweb_poll_finish(uuid, text)
  from public, anon, authenticated;
grant execute on function public.imweb_poll_lease(integer), public.imweb_poll_save_tokens(uuid, text, text, text),
  public.imweb_poll_apply(uuid, bigint, text, text, text, integer), public.imweb_poll_finish(uuid, text)
  to service_role;

commit;

-- Owner checks (SQL editor, as postgres):
--   select last_run_at, last_ok_at, last_status, token_updated_at from private.imweb_oauth;
--   select order_no, state, updated_at from private.imweb_order_items order by updated_at desc limit 20;
