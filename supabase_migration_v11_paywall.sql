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
-- Unlock = 30-day pass (v1 = manual)
-- * "함께 열기" gives the couple one 결제 확인 코드 (UR-XXXXXX), which they paste in the 아임웹 order memo.
-- * Every paid order is one row in private.couple_passes (30 days). paid_until = greatest(now(), paid_until) + 30 days,
--   so buying again stacks. The report is open while now() < paid_until.
-- * Admin checks the order and runs:  select private.set_couple_paid('UR-XXXXXX');            (adds one manual pass)
--   Refund / cancel of one order:      select private.set_couple_paid('UR-XXXXXX', false, '<source>', '<ref>');
--   Lock now (takes back every pass): select private.set_couple_paid('UR-XXXXXX', false);
--   A taken-back pass is kept with revoked_at; paid_until is replayed from the passes that are still active
--   (in paid_at order, same stacking rule), so one refund removes exactly that order's 30 days.
-- * A webhook / poller (server side) calls the same function with p_source / p_ref; the same (source, ref) never adds twice.
--
-- Security model (same as v10)
-- * New tables in schema private, RLS on, no policies, nothing granted to anon/authenticated.
-- * get_paywall_config / request_pay_code / my_report: authenticated only, SECURITY DEFINER, pinned search_path,
--   couple membership from auth.uid(). set_couple_paid: not executable by anon/authenticated.
-- * The report returns fixed keys only, never mission text and never 비밀방 text. Before payment only one key
--   (the partner's 다정함 방식, from missions) is returned.
-- * No dynamic SQL. Nothing here reads public.secret_emotions (the app never writes it; 비밀방 messages go to sai_chat).
--
-- 속마음 리포트 (비밀방 → 주제 키만)
-- * Consent: the 비밀방 안내 카드 [확인했어요] calls public.consent_secret_report(), which stores (user, couple, now())
--   in private.secret_report_consents. Only while the feature is ON; the first timestamp is kept.
-- * Write time: public.sai_chat (same body as v9.1 otherwise) calls private.record_secret_topic(code, last user message).
--   It does nothing unless the feature is ON, the caller is a member, and the caller consented for this couple.
--   It maps the message to ONE fixed key with a keyword list (private.secret_topic: phone/contact/affection/date/tone,
--   else 'default') and stores only (couple, author, key, time) in private.secret_topic_tags. The text is never stored.
--   No Gemini call is added; sai_chat's Gemini request is unchanged except the one gated sentence below.
-- * Read time (my_report, paid only): the PARTNER's tags written at/after the partner's consent. Used only when the
--   partner has >= 3 such entries; a key counts only with >= 2 entries; 'default' never shown. Those counts are added
--   to the mission-based counts and only the TOP 3 keys (no counts) are returned.
--   The first report that uses 비밀방 keys is made as soon as both conditions hold, then frozen for 7 days per viewer
--   (private.report_snapshots), so after that it changes at most once a week.
-- * Pay gate: my_report.posts_ready = the partner has >= 3 such entries. Until then the app shows a line, not a pay button.
-- * Withdraw: public.withdraw_secret_report() turns [확인했어요] off: deletes the caller's consent and topic keys for the
--   couple and the partner's frozen report, so nothing the caller wrote (before or after) is used. [확인했어요] again
--   starts over from that moment.
--
-- 비밀방 daily AI cap (cost only, not a paywall)
-- * public.sai_chat and public.generate_mission (the only 비밀방 Gemini callers) take one unit per call from
--   private.secret_ai_usage (per user per KST day). The limit is private.secret_ai_daily_cap() = 20 (the one constant).
--   Over the cap sai_chat returns {"capped": true} (no Gemini call, no topic key); generate_mission returns null.
--   This is on top of the per-couple 60/day sai_chat cap and the project-wide gemini_json 1000/day cap.
-- * sai_chat system text: when the feature is OFF it is exactly the v9.1 text; when ON it says written sentences are
--   never shown to the partner and that, after [확인했어요], only topics may go into the report.

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
  paid_until timestamptz,          -- report open while now() < paid_until (replayed from private.couple_passes)
  paid_at timestamptz,             -- paid_at / paid_source / payment_ref: the newest active pass (admin view)
  paid_source text check (paid_source in ('manual', 'portone', 'inicis', 'payapp')),
  payment_ref text check (payment_ref is null or char_length(payment_ref) <= 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table private.couple_entitlements add column if not exists paid_until timestamptz;

-- one row per paid order (30 days each). revoked_at set on refund / cancel; never deleted by the app
create table if not exists private.couple_passes (
  id bigint generated always as identity primary key,
  couple_code text not null references public.couples(code) on delete cascade,
  source text not null check (source in ('manual', 'portone', 'inicis', 'payapp')),
  ref text check (ref is null or char_length(ref) between 1 and 200),
  days integer not null default 30 check (days between 1 and 366),
  paid_at timestamptz not null default now(),
  revoked_at timestamptz
);
create unique index if not exists couple_passes_ref_idx on private.couple_passes(source, ref) where ref is not null;
create index if not exists couple_passes_couple_idx on private.couple_passes(couple_code, paid_at);

-- 속마음 리포트 frozen for a week per viewer (keys only)
create table if not exists private.report_snapshots (
  couple_code text not null references public.couples(code) on delete cascade,
  viewer_user uuid not null references auth.users(id) on delete cascade,
  topics jsonb not null,
  made_at timestamptz not null default now(),
  primary key (couple_code, viewer_user)
);

-- 비밀방 AI calls per user per KST day (cost cap)
create table if not exists private.secret_ai_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  call_count integer not null default 0,
  primary key (user_id, day)
);

-- 비밀방 [확인했어요] (per user per couple; first time kept)
create table if not exists private.secret_report_consents (
  user_id uuid not null references auth.users(id) on delete cascade,
  couple_code text not null references public.couples(code) on delete cascade,
  consented_at timestamptz not null default now(),
  primary key (user_id, couple_code)
);

-- one row per consented 비밀방 message while the feature is ON: a fixed key only, never the text
create table if not exists private.secret_topic_tags (
  id bigint generated always as identity primary key,
  couple_code text not null references public.couples(code) on delete cascade,
  author_user uuid not null references auth.users(id) on delete cascade,
  topic text not null check (topic in ('phone', 'contact', 'affection', 'date', 'tone', 'default')),
  created_at timestamptz not null default now()
);
create index if not exists secret_topic_tags_author_idx on private.secret_topic_tags(couple_code, author_user, created_at);

alter table private.paywall_config enable row level security;
alter table private.couple_entitlements enable row level security;
alter table private.secret_report_consents enable row level security;
alter table private.secret_topic_tags enable row level security;
alter table private.couple_passes enable row level security;
alter table private.report_snapshots enable row level security;
alter table private.secret_ai_usage enable row level security;
revoke all on private.paywall_config, private.couple_entitlements,
  private.secret_report_consents, private.secret_topic_tags,
  private.couple_passes, private.report_snapshots, private.secret_ai_usage from public, anon, authenticated;

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

-- paid_until from the couple's active passes, replayed in paid_at order with the purchase rule
-- (each pass: greatest(its paid_at, running paid_until) + its days). Also stores the newest active pass for the admin view.
create or replace function private.recompute_paid_until(p_couple text)
returns timestamptz language plpgsql volatile security definer set search_path = private, pg_temp as $$
declare p private.couple_passes; v_until timestamptz; v_last private.couple_passes;
begin
  for p in select * from private.couple_passes where couple_code = p_couple and revoked_at is null order by paid_at, id loop
    v_until := greatest(p.paid_at, coalesce(v_until, p.paid_at)) + make_interval(days => p.days);
    v_last := p;
  end loop;
  update private.couple_entitlements set paid_until = v_until, paid_at = v_last.paid_at, paid_source = v_last.source,
    payment_ref = v_last.ref, updated_at = now()
  where couple_code = p_couple;
  return v_until;
end $$;

-- admin / webhook / poller, by 결제 확인 코드:
--   p_paid = true  -> add a 30-day pass (same p_source + p_ref twice = no-op; a revoked one comes back)
--   p_paid = false -> with p_ref: take back that order's pass; without p_ref: take back every active pass (lock now)
create or replace function private.set_couple_paid(p_pay_code text, p_paid boolean default true,
  p_source text default 'manual', p_ref text default null)
returns jsonb language plpgsql volatile security definer set search_path = private, pg_temp as $$
declare e private.couple_entitlements; v_src text := coalesce(p_source, 'manual'); v_ref text := nullif(btrim(p_ref), '');
begin
  select * into e from private.couple_entitlements where pay_code = upper(btrim(p_pay_code)) for update;
  if not found then raise exception 'pay_code_not_found' using errcode = 'P0002'; end if;
  if coalesce(p_paid, false) then
    if v_ref is null then
      insert into private.couple_passes(couple_code, source) values (e.couple_code, v_src);
    else
      insert into private.couple_passes(couple_code, source, ref) values (e.couple_code, v_src, v_ref)
      on conflict (source, ref) where ref is not null do update set revoked_at = null
        where couple_passes.couple_code = excluded.couple_code;
    end if;
  elsif v_ref is null then
    update private.couple_passes set revoked_at = now() where couple_code = e.couple_code and revoked_at is null;
  else
    update private.couple_passes set revoked_at = now()
      where couple_code = e.couple_code and source = v_src and ref = v_ref and revoked_at is null;
  end if;
  perform private.recompute_paid_until(e.couple_code);
  select * into e from private.couple_entitlements where couple_code = e.couple_code;
  return jsonb_build_object('couple_code', e.couple_code, 'pay_code', e.pay_code,
    'paid', coalesce(e.paid_until > now(), false), 'paid_until', e.paid_until, 'paid_at', e.paid_at);
end $$;

-- 비밀방 message -> one fixed key (same keyword lists as the mission topics in my_report). Most keyword hits wins,
-- ties go to the list order; no hit -> 'default' (same key as the app's NUDGE_LIBRARY.default).
create or replace function private.secret_topic(p_text text)
returns text language sql immutable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce((
    select w.k from (values
        ('phone', 1, '폰|스마트폰|핸드폰|휴대폰|유튜브|인스타|릴스|게임|화면|만 보|만봐'),
        ('contact', 2, '연락|답장|읽씹|카톡|톡|전화|바빠|바쁘|바쁨|무소식|기다리'),
        ('affection', 3, '표현|사랑|좋아|예쁘|애정|스킨십|안아|고마|관심|무심|외로'),
        ('date', 4, '데이트|코스|계획|약속|주말|식당|카페|매번 나만|맨날 나만'),
        ('tone', 5, '말투|짜증|화내|차가|무뚝뚝|단답|퉁명|상처|예민')) as w(k, ord, re)
    where regexp_count(lower(coalesce(p_text, '')), w.re) > 0
    order by regexp_count(lower(coalesce(p_text, '')), w.re) desc, w.ord
    limit 1), 'default');
$$;

-- called by sai_chat with the caller's newest message. Stores a key only. Never raises.
create or replace function private.record_secret_topic(p_code text, p_text text)
returns void language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_n integer;
begin
  if v_uid is null or p_code is null or p_text is null or length(btrim(p_text)) = 0 then return; end if;
  if (private.paywall_on()).id is null then return; end if;
  if not coalesce(public.is_couple_member(p_code), false) then return; end if;
  if not exists (select 1 from private.secret_report_consents s
                 where s.user_id = v_uid and s.couple_code = p_code and s.consented_at <= now()) then
    return;
  end if;
  select count(*) into v_n from private.secret_topic_tags t
    where t.author_user = v_uid and t.created_at > now() - interval '1 day';
  if v_n >= 60 then return; end if;
  insert into private.secret_topic_tags(couple_code, author_user, topic)
    values (p_code, v_uid, private.secret_topic(p_text));
exception when others then
  return;
end $$;

-- 비밀방 AI cost cap: the one constant (AI-processed 비밀방 posts per user per KST day)
create or replace function private.secret_ai_daily_cap()
returns integer language sql immutable set search_path = pg_catalog, pg_temp as $$ select 20 $$;

-- take one 비밀방 AI call for the caller today (KST). false = over the cap (or no user).
create or replace function private.take_secret_ai_call()
returns boolean language plpgsql volatile security definer set search_path = private, pg_temp as $$
declare v_uid uuid := auth.uid(); v_n integer;
begin
  if v_uid is null then return false; end if;
  insert into private.secret_ai_usage as u(user_id, day, call_count)
  values (v_uid, (timezone('Asia/Seoul', now()))::date, 1)
  on conflict (user_id, day) do update set call_count = u.call_count + 1
  where u.call_count < private.secret_ai_daily_cap()
  returning u.call_count into v_n;
  return v_n is not null;
end $$;

revoke all on function private.paywall_on(), private.new_pay_code(), private.recompute_paid_until(text),
  private.set_couple_paid(text, boolean, text, text), private.secret_topic(text),
  private.record_secret_topic(text, text), private.secret_ai_daily_cap(), private.take_secret_ai_call()
  from public, anon, authenticated;

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
  return jsonb_build_object('enabled', true, 'price_krw', p.price_krw, 'checkout_url', p.checkout_url, 'unlock_eta', p.unlock_eta,
    'report_consent', exists (select 1 from private.secret_report_consents s join public.couples c on c.code = s.couple_code
      where s.user_id = auth.uid() and (c.user_a = auth.uid() or c.user_b = auth.uid())));
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
  return jsonb_build_object('pay_code', e.pay_code, 'paid', coalesce(e.paid_until > now(), false));
end $$;

-- consent_secret_report(): 비밀방 안내 카드 [확인했어요]. Only while the feature is ON. Keeps the first time.
create or replace function public.consent_secret_report()
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c public.couples;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if (private.paywall_on()).id is null then return jsonb_build_object('enabled', false); end if;
  select * into c from public.couples where user_a = auth.uid() or user_b = auth.uid() limit 1;
  if not found or not coalesce(public.is_couple_member(c.code), false) then
    raise exception 'not_in_couple' using errcode = 'P0002';
  end if;
  insert into private.secret_report_consents(user_id, couple_code) values (auth.uid(), c.code)
    on conflict (user_id, couple_code) do nothing;
  return jsonb_build_object('enabled', true, 'consented', true);
end $$;

-- withdraw_secret_report(): turns [확인했어요] off. Works with the flag on or off. Deletes the caller's consent and
-- topic keys for the couple and the partner's frozen report, so nothing the caller wrote is used any more.
create or replace function public.withdraw_secret_report()
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c public.couples;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = auth.uid() or user_b = auth.uid() limit 1;
  if not found then return jsonb_build_object('consented', false); end if;
  delete from private.secret_report_consents where user_id = auth.uid() and couple_code = c.code;
  delete from private.secret_topic_tags where author_user = auth.uid() and couple_code = c.code;
  delete from private.report_snapshots where couple_code = c.code and viewer_user is distinct from auth.uid();
  return jsonb_build_object('consented', false);
end $$;

-- my_report(): the caller's view of the partner's 마음 날씨.
-- {"enabled": false} when the flag is off. Keys only (client maps them to fixed copy):
--   posts_ready: the partner has >= 3 consented 비밀방 entries (pay gate; no count is returned)
--   paid       : now() < paid_until (30-day pass)
--   way_key    : partner's 다정함 방식 from missions the partner accepted (penguin/parrot/squirrel/bear/rabbit; same words as 우리 조합)
--   topics     : TOP 3 서운함 주제 (phone/contact/affection/date/tone), no counts — paid only. Score per key =
--                missions the partner sent to the caller + the partner's consented 비밀방 keys (only when the partner has
--                >= 3 consented entries, and only keys with >= 2 entries; 'default' never counted)
--   mission_key: top topic or 'default' (client shows its built-in mission ideas for that key) — paid only
-- Timing: once the 비밀방 conditions hold (>= 3 entries and a key with >= 2) the topics are frozen for this viewer in
-- private.report_snapshots and recomputed only when the snapshot is 7+ days old. Before that they are computed live
-- (missions only). Volatile because it writes the snapshot.
create or replace function public.my_report()
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c public.couples; e private.couple_entitlements; v_me text; v_partner text; v_paid boolean;
  v_total integer; v_way text; v_topics jsonb; v_ready boolean; v_partner_uid uuid; v_secret_n integer;
  v_secret_hit boolean; snap private.report_snapshots;
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
  v_partner_uid := case when v_me = 'A' then c.user_b else c.user_a end;
  select * into e from private.couple_entitlements where couple_code = c.code;
  v_paid := coalesce(e.paid_until > now(), false);

  -- the partner's 비밀방 entries written at/after the partner's own [확인했어요] for this couple
  select count(*) into v_secret_n from private.secret_topic_tags t
    join private.secret_report_consents s on s.user_id = t.author_user and s.couple_code = t.couple_code
    where t.couple_code = c.code and t.author_user = v_partner_uid and t.created_at >= s.consented_at;

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

  if v_ready and v_paid then
    select * into snap from private.report_snapshots where couple_code = c.code and viewer_user = auth.uid();
    if found and snap.made_at > now() - interval '7 days' then
      v_topics := snap.topics;
    else
      select exists (select 1 from private.secret_topic_tags t
          join private.secret_report_consents s on s.user_id = t.author_user and s.couple_code = t.couple_code
          where coalesce(v_secret_n, 0) >= 3 and t.couple_code = c.code and t.author_user = v_partner_uid
            and t.created_at >= s.consented_at and t.topic <> 'default'
          group by t.topic having count(*) >= 2)
        into v_secret_hit;

      select coalesce(jsonb_agg(t.k order by t.n desc, t.ord), '[]'::jsonb) into v_topics from (
        select x.k, x.ord, sum(x.n) n from (
          select w.k, w.ord, count(*) n from (values
              ('phone', 1, '폰|스마트폰|핸드폰|휴대폰|유튜브|인스타|릴스|게임|화면|만 보|만봐'),
              ('contact', 2, '연락|답장|읽씹|카톡|톡|전화|바빠|바쁘|바쁨|무소식|기다리'),
              ('affection', 3, '표현|사랑|좋아|예쁘|애정|스킨십|안아|고마|관심|무심|외로'),
              ('date', 4, '데이트|코스|계획|약속|주말|식당|카페|매번 나만|맨날 나만'),
              ('tone', 5, '말투|짜증|화내|차가|무뚝뚝|단답|퉁명|상처|예민')) as w(k, ord, re)
            join public.daily_missions d on d.couple_code = c.code and d.target_role = v_me
              and lower(d.title || ' ' || d.message) ~ w.re
            group by w.k, w.ord
          union all
          select t.topic, array_position(array['phone', 'contact', 'affection', 'date', 'tone'], t.topic), count(*)
            from private.secret_topic_tags t
            join private.secret_report_consents s on s.user_id = t.author_user and s.couple_code = t.couple_code
            where coalesce(v_secret_n, 0) >= 3
              and t.couple_code = c.code and t.author_user = v_partner_uid and t.created_at >= s.consented_at
              and t.topic <> 'default'
            group by t.topic
            having count(*) >= 2
        ) x group by x.k, x.ord order by sum(x.n) desc, x.ord limit 3) t;

      if coalesce(v_secret_hit, false) then
        insert into private.report_snapshots(couple_code, viewer_user, topics, made_at)
          values (c.code, auth.uid(), v_topics, now())
        on conflict (couple_code, viewer_user) do update set topics = excluded.topics, made_at = excluded.made_at;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'enabled', true,
    'partner_joined', true,
    'partner_name', case when v_me = 'A' then c.name_b else c.name_a end,
    'ready', v_ready,
    'posts_ready', coalesce(v_secret_n, 0) >= 3,
    'pay_code', e.pay_code,
    'paid', v_paid,
    'way_key', case when v_ready then v_way end,
    'report', case when v_ready and v_paid then jsonb_build_object(
      'topics', v_topics,
      'mission_key', coalesce(v_topics ->> 0, 'default')) end);
end $$;

revoke all on function public.get_paywall_config(), public.request_pay_code(), public.my_report(),
  public.consent_secret_report(), public.withdraw_secret_report() from public, anon;
grant execute on function public.get_paywall_config(), public.request_pay_code(), public.my_report(),
  public.consent_secret_report(), public.withdraw_secret_report() to authenticated;

-- ---------------------------------------------------------------------------
-- public.sai_chat(couple_code, messages) — v11: the v9.1 body + 속마음 리포트 hooks (both gated by the paywall flag)
-- + the per-user daily AI cap (always on; returns {"capped": true} before any Gemini call)
-- messages: [{"role":"user"|"bot","text":"..."}...], oldest first, last one is the user's new message.
-- Returns {"reply": text, "missions": [{"title","message"}, ...0-2]} or null (app then uses presets).
-- ---------------------------------------------------------------------------
create or replace function public.sai_chat(couple_code text, messages jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, vault, extensions
set statement_timeout = '24s'
as $fn$
#variable_conflict use_column
declare
  v_code text;
  v_count integer;
  v_today date := (timezone('Asia/Seoul', now()))::date;
  v_msgs jsonb;
  v_n integer;
  v_last text;
  v_contents jsonb := '[]'::jsonb;
  v_item jsonb;
  v_role text;
  v_text text;
  v_prev_role text := '';
  v_i integer := 0;
  v_sys text;
  v_out jsonb;
  v_reply text;
  v_missions jsonb := '[]'::jsonb;
  v_m jsonb;
  v_report_on boolean := false;
begin
  if couple_code is null or length(btrim(couple_code)) = 0 or length(couple_code) > 32 then
    return null;
  end if;
  v_code := btrim(couple_code);
  if auth.uid() is null or not public.is_couple_member(v_code) then
    return null;
  end if;
  if messages is null or jsonb_typeof(messages) <> 'array' then
    return null;
  end if;

  v_n := jsonb_array_length(messages);
  if v_n = 0 then return null; end if;
  if messages -> (v_n - 1) ->> 'role' is distinct from 'user' then return null; end if;
  v_last := btrim(coalesce(messages -> (v_n - 1) ->> 'text', ''));
  if length(v_last) = 0 or length(v_last) > 500 then return null; end if;

  -- v11: 비밀방 AI cost cap per user per KST day (private.secret_ai_daily_cap). Over it: no Gemini call, no topic key.
  if not private.take_secret_ai_call() then
    return jsonb_build_object('capped', true);
  end if;

  -- keep the last 10 turns
  select coalesce(jsonb_agg(e order by ord), '[]'::jsonb) into v_msgs
  from jsonb_array_elements(messages) with ordinality as t(e, ord)
  where ord > greatest(v_n - 10, 0);

  insert into public.sai_chat_usage as u(couple_code, day, call_count)
  values (v_code, v_today, 1)
  on conflict on constraint sai_chat_usage_pkey
  do update set call_count = u.call_count + 1
  where u.call_count < 60
  returning u.call_count into v_count;
  if v_count is null then
    return null;
  end if;

  -- v11: 속마음 리포트. 기능이 켜져 있고 이 사람이 [확인했어요]를 누른 뒤일 때만, 방금 쓴 문장을
  -- 고정 주제 키 하나로 바꿔 저장한다(문장은 저장하지 않음). 꺼져 있으면 아무것도 하지 않고, 실패해도 대화에 영향 없음.
  perform private.record_secret_topic(v_code, v_last);
  v_report_on := (private.paywall_on()).id is not null;

  -- build Gemini contents: must start with a user turn, roles must alternate
  for v_item in select e from jsonb_array_elements(v_msgs) as t(e) loop
    v_i := v_i + 1;
    v_role := case when v_item->>'role' = 'user' then 'user' else 'model' end;
    v_text := left(btrim(coalesce(v_item->>'text', '')), 500);
    continue when length(v_text) = 0;
    continue when v_prev_role = '' and v_role = 'model';
    if v_i = jsonb_array_length(v_msgs) then
      v_text := private.couple_context(v_code) || E'\n[지금 메시지] ' || v_text;
    end if;
    if v_role = v_prev_role then
      v_contents := jsonb_set(
        v_contents,
        array[(jsonb_array_length(v_contents) - 1)::text, 'parts', '0', 'text'],
        to_jsonb((v_contents -> -1 #>> '{parts,0,text}') || E'\n' || v_text));
    else
      v_contents := v_contents || jsonb_build_array(jsonb_build_object(
        'role', v_role, 'parts', jsonb_build_array(jsonb_build_object('text', v_text))));
    end if;
    v_prev_role := v_role;
  end loop;
  if jsonb_array_length(v_contents) = 0 then return null; end if;

  v_sys :=
    '너는 커플 관계 코칭 앱 ''우리사이''의 AI 친구 ''사이봇''이야. 지금 대화하는 사람은 ''나''이고, ' ||
    -- v11: 속마음 리포트가 켜져 있을 때만 안내가 바뀐다. 꺼져 있으면 v9.1과 글자 하나까지 같다.
    case when v_report_on
      then '여기 쓴 문장은 연인에게 절대 보이지 않아. 다만 비밀방 안내에서 [확인했어요]를 누른 뒤에 쓴 글은 요즘 마음이 어느 쪽에 있는지만 주제(예: 연락 빈도, 말투 서운함)로 정리돼서 두 사람이 함께 여는 리포트에 들어갈 수 있어. 쓴 문장 그대로나 인용은 절대 들어가지 않아. 이 부분을 물어보면 이대로만 설명해.'
      else '이 비밀방 대화는 연인에게 절대 보이지 않아.' end || E'\n' ||
    '역할:' || E'\n' ||
    '- 상대가 방금 한 말에 직접, 구체적으로 반응해. 상대가 쓴 단어와 상황을 짚어서 말해. 뻔한 위로 문구나 템플릿 같은 말 금지.' || E'\n' ||
    '- 친한 언니/형처럼 따뜻하고 자연스러운 한국어. 반말 금지, 항상 부드러운 해요체(~요). 1~3문장, 짧게. 이모지는 가끔 하나 정도.' || E'\n' ||
    '- 인사·잡담·질문이면 그에 맞게 자연스럽게 대답하고, 필요하면 오늘 연인과 있었던 일을 가볍게 물어봐.' || E'\n' ||
    '- 서운함·아쉬움·바람이 드러나면 공감한 뒤, 연인에게 ''오늘의 미션''으로 슬쩍 보낼 다정한 행동 제안을 2개 만들어.' || E'\n' ||
    '- 정보가 부족하면 미션 없이 한 가지만 부드럽게 되물어.' || E'\n' ||
    '- 이전 대화 흐름을 기억하고 같은 말을 반복하지 마.' || E'\n' ||
    '미션 규칙: 미션 message는 앱이 연인에게 보내는 오늘의 추천 문구야. 나의 서운함이 풀리도록 연인이 나에게 해 줄 행동을 제안해.' || E'\n' ||
    '- 연인에게 직접 말하는 형식: "상대방에게 ~해 주세요", "오늘은 상대방과 ~해 보세요". 나를 가리킬 땐 이름이 아니라 ''상대방''이라고 써.' || E'\n' ||
    '- 연인이 불만을 들었다는 사실이나 과거의 잘못(늦음, 폰, 말투 등)을 절대 언급하지 마. ''늦었으니'', ''서운'', ''화나'' 같은 말 금지. 그냥 앱이 추천하는 기분 좋은 미션처럼 보여야 해.' || E'\n' ||
    '- 예: 늦어서 서운했다면 → "오늘은 출발할 때 상대방에게 ''지금 출발!'' 한 줄 먼저 보내 주세요."' || E'\n' ||
    '- 오늘 바로 할 수 있는 구체적인 행동 1개를 1~2문장의 해요체로. 두 미션은 서로 다른 행동이어야 하고 최근 보낸 미션과 겹치지 마.' || E'\n' ||
    '- title은 15자 이내.' || E'\n' ||
    '출력: 반드시 JSON 하나만. {"reply":"나에게 하는 답","missions":[{"title":"...","message":"..."}]} 미션이 필요 없으면 "missions":[].';

  v_out := private.gemini_json(jsonb_build_object(
    'systemInstruction', jsonb_build_object('parts', jsonb_build_array(jsonb_build_object('text', v_sys))),
    'contents', v_contents,
    'generationConfig', jsonb_build_object(
      'temperature', 1.0,
      'topP', 0.95,
      'maxOutputTokens', 800,
      'responseMimeType', 'application/json',
      'thinkingConfig', jsonb_build_object('thinkingLevel', 'minimal')
    )
  ));
  if v_out is null then return null; end if;

  v_reply := btrim(coalesce(v_out->>'reply', ''));
  if length(v_reply) = 0 then return null; end if;

  if jsonb_typeof(v_out->'missions') = 'array' then
    for v_m in select e from jsonb_array_elements(v_out->'missions') as t(e) limit 3 loop
      if jsonb_typeof(v_m) = 'object' and length(btrim(coalesce(v_m->>'message', ''))) > 0 then
        v_missions := v_missions || jsonb_build_array(jsonb_build_object(
          'title', left(coalesce(nullif(btrim(v_m->>'title'), ''), '오늘의 다정함 미션'), 40),
          'message', left(btrim(v_m->>'message'), 300)));
      end if;
    end loop;
  end if;

  return jsonb_build_object('reply', left(v_reply, 600), 'missions', v_missions);
exception when others then
  return null;
end;
$fn$;

comment on function public.sai_chat(text, jsonb) is
  'v9 Saibot chat (v11: after consent, a topic key only, when the report is on; per-user daily AI cap -> {capped:true}). Members only. 60 calls/day per couple. Returns {reply,missions[]} or null. Key from vault.';
revoke all on function public.sai_chat(text, jsonb) from public, anon;
grant execute on function public.sai_chat(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- public.generate_mission — the v9 body + the per-user 비밀방 AI cap (older apps call it from 비밀방). Down restores v9.
-- ---------------------------------------------------------------------------
create or replace function public.generate_mission(feeling text, couple_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, vault, extensions
set statement_timeout = '24s'
as $fn$
#variable_conflict use_column
declare
  v_code text;
  v_count integer;
  v_parsed jsonb;
  v_today date := (timezone('Asia/Seoul', now()))::date;
begin
  if feeling is null or length(btrim(feeling)) = 0 or length(feeling) > 500 then
    return null;
  end if;
  if couple_code is null or length(btrim(couple_code)) = 0 or length(couple_code) > 32 then
    return null;
  end if;
  v_code := btrim(couple_code);
  if auth.uid() is null or not public.is_couple_member(v_code) then
    return null;
  end if;

  -- v11: same per-user 비밀방 AI cap as sai_chat (older app versions call this from 비밀방)
  if not private.take_secret_ai_call() then
    return null;
  end if;

  insert into public.mission_gen_usage as u(couple_code, day, call_count)
  values (v_code, v_today, 1)
  on conflict on constraint mission_gen_usage_pkey
  do update set call_count = u.call_count + 1
  where u.call_count < 30
  returning u.call_count into v_count;
  if v_count is null then
    return null;
  end if;

  v_parsed := private.gemini_json(jsonb_build_object(
    'contents', jsonb_build_array(jsonb_build_object('role', 'user', 'parts', jsonb_build_array(jsonb_build_object('text',
      '당신은 커플 관계 코칭 AI ''사이봇''입니다. 한 사람이 연인에게 서운하거나 아쉬운 마음을 비밀로 털어놓았습니다.' || E'\n' ||
      private.couple_context(v_code) || E'\n' ||
      '털어놓은 말: ' || btrim(feeling) || E'\n' ||
      '반드시 다음 JSON만 출력하세요: {"empathy":"...","title":"...","message":"..."}' || E'\n' ||
      '1) empathy: 털어놓은 사람이 쓴 말과 상황을 구체적으로 짚어 공감하는 1~2문장(본인만 봄). 뻔한 템플릿 금지.' || E'\n' ||
      '2) title: 상대방에게 보낼 데일리 미션 제목(15자 이내).' || E'\n' ||
      '3) message: 앱이 연인에게 보내는 오늘의 추천 미션 1~2문장, 해요체. "상대방에게 ~해 주세요" 형식으로 연인에게 직접 말하고, 털어놓은 사람은 이름 대신 ''상대방''이라고 부르세요. 불만·서운함·과거의 잘못은 절대 언급하지 말고, 마음이 풀리는 방향의 오늘 할 수 있는 구체적인 다정한 행동. 최근 보낸 미션과 겹치지 않게.'
    )))),
    'generationConfig', jsonb_build_object(
      'temperature', 1.0,
      'maxOutputTokens', 600,
      'responseMimeType', 'application/json',
      'thinkingConfig', jsonb_build_object('thinkingLevel', 'minimal')
    )
  ));

  if v_parsed is null or coalesce(v_parsed->>'empathy', '') = '' or coalesce(v_parsed->>'message', '') = '' then
    return null;
  end if;
  return jsonb_build_object(
    'empathy', left(v_parsed->>'empathy', 500),
    'title', left(coalesce(nullif(v_parsed->>'title', ''), '오늘의 다정함 미션'), 40),
    'message', left(v_parsed->>'message', 500)
  );
exception when others then
  return null;
end;
$fn$;

revoke all on function public.generate_mission(text, text) from public, anon;
grant execute on function public.generate_mission(text, text) to authenticated;

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
--   select couple_code, pay_code, paid_until, created_at from private.couple_entitlements where paid_until is null or paid_until <= now() order by created_at desc;
-- Passes: select couple_code, source, ref, paid_at, revoked_at from private.couple_passes order by paid_at desc limit 20;
