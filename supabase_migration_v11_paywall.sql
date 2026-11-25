-- 우리사이 v11: 심층 리포트(마음 날씨) + 결제 화면(아임웹 링크) — 서버 플래그로 꺼진 상태로 배포.
-- Run AFTER supabase_migration_v10_share_quiz.sql. Safe to run more than once. Rollback: supabase_migration_v11_paywall_down.sql
-- Tests: scripts/test_v11.sql (scripts/run_local_sql_tests.sh)
--
-- Server flag
-- * private.paywall_config is a single row. enabled=false, price_krw/checkout_url/unlock_eta = null after this migration.
-- * The feature counts as ON only when enabled = true AND price_krw, checkout_url, unlock_eta are all filled.
--   Otherwise every RPC below answers {"enabled": false} and the app renders nothing new.
-- * Owner turns it on later (SQL editor, as postgres):
--     update private.paywall_config set price_krw = 4900, checkout_url = 'https://<아임웹 상품 링크>',
--       unlock_eta = '<열리는 시간>', enabled = true, updated_at = now();
--
-- Unlock (v1 = manual)
-- * "함께 열기" gives the couple one 결제 확인 코드 (UR-XXXXXX), which they paste in the 아임웹 order memo.
-- * Admin checks the order and runs:  select private.set_couple_paid('UR-XXXXXX');
--   (undo: select private.set_couple_paid('UR-XXXXXX', false);)
-- * Later a PortOne / KG이니시스 webhook (server side, service role) calls the same function with p_source / p_ref.
--
-- Security model (same as v10)
-- * New tables in schema private, RLS on, no policies, nothing granted to anon/authenticated.
-- * get_paywall_config / request_pay_code / my_report: authenticated only, SECURITY DEFINER, pinned search_path,
--   couple membership from auth.uid(). set_couple_paid: not executable by anon/authenticated.
-- * The report is built only from public.daily_missions rows the caller can already read (missions the partner
--   accepted from the caller, missions the partner sent to the caller) and returns fixed keys, never mission text.
--   Nothing here reads public.secret_emotions. Before payment only one key (the partner's 다정함 방식) is returned.
-- * No dynamic SQL.

begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists private.paywall_config (
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  price_krw integer check (price_krw is null or price_krw between 100 and 1000000),
  checkout_url text check (checkout_url is null or (checkout_url ~ '^https://[^[:space:]<>"''`\\]+$' and char_length(checkout_url) <= 500)),
  unlock_eta text check (unlock_eta is null or (char_length(btrim(unlock_eta)) between 1 and 40 and unlock_eta !~ '[<>&"''`]')),
  updated_at timestamptz not null default now()
);
insert into private.paywall_config(id) values (true) on conflict (id) do nothing;

create table if not exists private.couple_entitlements (
  couple_code text primary key references public.couples(code) on delete cascade,
  pay_code text not null unique check (pay_code ~ '^UR-[A-HJ-NP-Z2-9]{6}$'),
  report_paid boolean not null default false,
  paid_at timestamptz,
  paid_source text check (paid_source in ('manual', 'portone', 'inicis', 'payapp')),
  payment_ref text check (payment_ref is null or char_length(payment_ref) <= 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table private.paywall_config enable row level security;
alter table private.couple_entitlements enable row level security;
revoke all on private.paywall_config, private.couple_entitlements from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers (private, not executable by API roles)
-- ---------------------------------------------------------------------------
-- the config row when the feature is fully ON, else null
create or replace function private.paywall_on()
returns private.paywall_config language sql stable security definer set search_path = private, pg_temp as $$
  select p from private.paywall_config p
  where p.id and p.enabled and p.price_krw is not null and p.checkout_url is not null and p.unlock_eta is not null;
$$;

-- UR- + 6 chars without 0/O/1/I
create or replace function private.new_pay_code()
returns text language plpgsql volatile security definer set search_path = private, pg_temp as $$
declare a constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea := extensions.gen_random_bytes(6); s text := 'UR-'; i integer;
begin
  for i in 0..5 loop s := s || substr(a, (get_byte(b, i) % 32) + 1, 1); end loop;
  return s;
end $$;

-- admin / future webhook: mark a couple paid (or unpaid) by its 결제 확인 코드
create or replace function private.set_couple_paid(p_pay_code text, p_paid boolean default true,
  p_source text default 'manual', p_ref text default null)
returns jsonb language plpgsql volatile security definer set search_path = private, pg_temp as $$
declare e private.couple_entitlements;
begin
  update private.couple_entitlements set
    report_paid = coalesce(p_paid, false),
    paid_at = case when coalesce(p_paid, false) then coalesce(paid_at, now()) else null end,
    paid_source = case when coalesce(p_paid, false) then coalesce(p_source, 'manual') else null end,
    payment_ref = case when coalesce(p_paid, false) then p_ref else null end,
    updated_at = now()
  where pay_code = upper(btrim(p_pay_code))
  returning * into e;
  if not found then raise exception 'pay_code_not_found' using errcode = 'P0002'; end if;
  return jsonb_build_object('couple_code', e.couple_code, 'pay_code', e.pay_code, 'report_paid', e.report_paid, 'paid_at', e.paid_at);
end $$;

revoke all on function private.paywall_on(), private.new_pay_code(),
  private.set_couple_paid(text, boolean, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- RPCs (authenticated only)
-- ---------------------------------------------------------------------------
-- get_paywall_config(): {"enabled": false} unless fully ON; values only when ON
create or replace function public.get_paywall_config()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare p private.paywall_config;
begin
  if auth.uid() is null then return jsonb_build_object('enabled', false); end if;
  p := private.paywall_on();
  if p.id is null then return jsonb_build_object('enabled', false); end if;
  return jsonb_build_object('enabled', true, 'price_krw', p.price_krw, 'checkout_url', p.checkout_url, 'unlock_eta', p.unlock_eta);
end $$;

-- request_pay_code(): the couple's 결제 확인 코드 (created once, same for both members)
create or replace function public.request_pay_code()
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c public.couples; e private.couple_entitlements; i integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if (private.paywall_on()).id is null then raise exception 'paywall_off' using errcode = 'P0001'; end if;
  select * into c from public.couples where user_a = auth.uid() or user_b = auth.uid() limit 1 for update;
  if not found then raise exception 'not_in_couple' using errcode = 'P0002'; end if;
  if c.user_a is null or c.user_b is null then raise exception 'partner_not_joined' using errcode = 'P0001'; end if;
  select * into e from private.couple_entitlements where couple_code = c.code;
  if not found then
    for i in 1..8 loop
      begin
        insert into private.couple_entitlements(couple_code, pay_code) values (c.code, private.new_pay_code()) returning * into e;
        exit;
      exception when unique_violation then
        select * into e from private.couple_entitlements where couple_code = c.code;
        exit when found;
      end;
    end loop;
    if e.couple_code is null then raise exception 'pay_code_failed' using errcode = 'P0001'; end if;
  end if;
  return jsonb_build_object('pay_code', e.pay_code, 'paid', e.report_paid);
end $$;

-- my_report(): the caller's view of the partner's 마음 날씨.
-- {"enabled": false} when the flag is off. Keys only (client maps them to fixed copy):
--   way_key   : partner's 다정함 방식 from missions the partner accepted (penguin/parrot/squirrel/bear/rabbit; same words as 우리 조합)
--   topics    : TOP 3 서운함 주제 from missions the partner sent to the caller (phone/contact/affection/date/tone) — paid only
--   mission_key: top topic or 'default' (client shows its built-in mission ideas for that key) — paid only
create or replace function public.my_report()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.couples; e private.couple_entitlements; v_me text; v_partner text;
  v_total integer; v_way text; v_topics jsonb; v_ready boolean;
begin
  if auth.uid() is null then return null; end if;
  if (private.paywall_on()).id is null then return jsonb_build_object('enabled', false); end if;
  select * into c from public.couples where user_a = auth.uid() or user_b = auth.uid() limit 1;
  if not found then return null; end if;
  if c.user_a is null or c.user_b is null then
    return jsonb_build_object('enabled', true, 'partner_joined', false);
  end if;
  v_me := case when c.user_a = auth.uid() then 'A' else 'B' end;
  v_partner := case when v_me = 'A' then 'B' else 'A' end;
  select * into e from private.couple_entitlements where couple_code = c.code;

  select count(*) into v_total from public.daily_missions d
    where d.couple_code = c.code and ((d.target_role = v_partner and d.accepted) or d.target_role = v_me);

  select w.k into v_way from (values
      ('penguin', 1, '안아|산책|걷|눈맞|눈 맞|폰|화면|티타임|톤'),
      ('parrot', 2, '말|톡|목소리|인사|한마디|문장|칭찬|안부|통화'),
      ('squirrel', 3, '약속|기념일|계획|코스'),
      ('bear', 4, '같이|함께|데이트|집에서|노래|영상'),
      ('rabbit', 5, '선물|깜짝|스티커|편지|비밀|이벤트')) as w(k, ord, re)
    join public.daily_missions d on d.couple_code = c.code and d.target_role = v_partner and d.accepted
      and (d.title || ' ' || d.message) ~ w.re
    group by w.k, w.ord order by count(*) desc, w.ord limit 1;

  v_ready := v_total >= 3 and v_way is not null;

  if v_ready and coalesce(e.report_paid, false) then
    select coalesce(jsonb_agg(t.k order by t.n desc, t.ord), '[]'::jsonb) into v_topics from (
      select w.k, w.ord, count(*) n from (values
          ('phone', 1, '폰|스마트폰|핸드폰|휴대폰|유튜브|인스타|릴스|게임|화면|만 보|만봐'),
          ('contact', 2, '연락|답장|읽씹|카톡|톡|전화|바빠|바쁘|바쁨|무소식|기다리'),
          ('affection', 3, '표현|사랑|좋아|예쁘|애정|스킨십|안아|고마|관심|무심|외로'),
          ('date', 4, '데이트|코스|계획|약속|주말|식당|카페|매번 나만|맨날 나만'),
          ('tone', 5, '말투|짜증|화내|차가|무뚝뚝|단답|퉁명|상처|예민')) as w(k, ord, re)
        join public.daily_missions d on d.couple_code = c.code and d.target_role = v_me
          and lower(d.title || ' ' || d.message) ~ w.re
        group by w.k, w.ord order by count(*) desc, w.ord limit 3) t;
  end if;

  return jsonb_build_object(
    'enabled', true,
    'partner_joined', true,
    'partner_name', case when v_me = 'A' then c.name_b else c.name_a end,
    'ready', v_ready,
    'pay_code', e.pay_code,
    'paid', coalesce(e.report_paid, false),
    'way_key', case when v_ready then v_way end,
    'report', case when v_ready and coalesce(e.report_paid, false) then jsonb_build_object(
      'topics', v_topics,
      'mission_key', coalesce(v_topics ->> 0, 'default')) end);
end $$;

revoke all on function public.get_paywall_config(), public.request_pay_code(), public.my_report() from public, anon;
grant execute on function public.get_paywall_config(), public.request_pay_code(), public.my_report() to authenticated;

-- ---------------------------------------------------------------------------
-- Funnel counters: v10 log_event + paywall / report events (same signature, same caps)
-- ---------------------------------------------------------------------------
create or replace function public.log_event(p_event text)
returns boolean language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c public.couples; v_n integer;
begin
  if p_event is null or p_event not in ('combo_view', 'combo_share_request', 'combo_shared',
      'quiz_start', 'quiz_finish', 'challenge_sent', 'quiz_kakao_start',
      'report_teaser_view', 'report_teaser_click', 'paywall_view', 'paywall_click', 'paywall_checkout_open',
      'pay_code_copy', 'report_view') then
    return false;
  end if;
  c := private.my_couple_row();
  if c.code is not null then
    select count(*) into v_n from private.funnel_events
      where couple_code = c.code and event = p_event and created_at > now() - interval '1 day';
    if v_n >= 200 then return false; end if;
  end if;
  begin
    perform private.bump_usage('event', 20000);
  exception when others then
    return false;
  end;
  insert into private.funnel_events(event, couple_code) values (p_event, c.code);
  return true;
end $$;
revoke all on function public.log_event(text) from public;
grant execute on function public.log_event(text) to anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- Funnel (as postgres):
--   select event, count(*), count(distinct couple_code) couples from private.funnel_events
--   where (event like 'report%' or event like 'pay%') and created_at > now() - interval '7 days' group by 1 order by 1;
-- Waiting for payment check:
--   select couple_code, pay_code, created_at from private.couple_entitlements where not report_paid order by created_at desc;
